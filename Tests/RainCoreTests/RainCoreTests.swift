import XCTest
@testable import RainCore

final class RainCoreTests: XCTestCase {
    let now = RainClock.parseCompact("20261115060000")!
    func reading(_ station: Station = Stations.motooka, minutesAgo: Double = 0, rain: Double? = 0) -> RainObservation {
        RainObservation(stationID: station.id, timestamp: now.addingTimeInterval(-minutesAgo * 60), fetchedAt: now, tenMinutes: rain)
    }
    func dryHistory() -> [RainObservation] {
        [Stations.motooka, Stations.ikeda].flatMap { s in [0.0, 10, 20].map { reading(s, minutesAgo: $0) } }
    }
    // Synthetic fixture, intentionally not represented as a downloaded source page.
    func fixture(_ firstValue: String = "2.5mm", timestamp: String = "2026\u{5e74}11\u{6708}15\u{65e5} 05:40") -> String {
        """
        <h3>\u{96e8}\u{91cf}\u{89b3}\u{6e2c}\u{6642}\u{523b}\u{ff1a}\(timestamp)</h3>
        <table><tr><th>\u{5730}\u{70b9}</th><th>\u{524d}10\u{5206}</th><th>\u{524d}1\u{6642}\u{9593}</th><th>\u{524d}3\u{6642}\u{9593}</th><th>\u{524d}24\u{6642}\u{9593}</th></tr>
        <tr><td><a href="puryo0820018.html">Motooka</a><br>Taromaru</td><td><b>\(firstValue)</b></td><td>10.0mm</td><td>11.5mm</td><td>28.0mm</td></tr>
        <tr><td><a href='puryo0000154.html'>Ikeda</a></td><td>0.0mm</td><td>7.0mm</td><td>9.0mm</td><td>22.0mm</td></tr></table>
        """
    }
    func testHTMLParsesRainAndTimestamp() throws {
        let observations = try FukuokaParser.parse(html: fixture(), fetchedAt: now)
        XCTAssertEqual(observations.count, 2)
        XCTAssertEqual(observations[0].stationID, "motooka")
        XCTAssertEqual(observations[0].tenMinutes, 2.5)
        XCTAssertEqual(observations[0].timestamp, RainClock.parseCompact("20261115054000"))
        XCTAssertEqual(observations[0].timestampKind, .pageSnapshot)
    }
    func testMissingIsNotDry() throws {
        for value in ["\u{6b20}\u{6e2c}", "--", "\u{ff0d}", "", "0.0*", "<span>error</span>"] {
            XCTAssertNil(try FukuokaParser.parse(html: fixture(value), fetchedAt: now).first?.tenMinutes)
        }
    }
    func testChangedHTMLFailsClosed() {
        XCTAssertThrowsError(try FukuokaParser.parse(html: "<p>No data</p>"))
        XCTAssertThrowsError(try FukuokaParser.parse(html: fixture(timestamp: "unknown")))
    }
    func testPerTableTimestamps() throws {
        let html = fixture(timestamp: "2026\u{5e74}11\u{6708}15\u{65e5} 04:40") + fixture(timestamp: "2026\u{5e74}11\u{6708}15\u{65e5} 05:40")
        XCTAssertEqual(try FukuokaParser.parse(html: html).first?.timestamp, RainClock.parseCompact("20261115054000"))
    }
    func testReorderedHeadersFailClosed() {
        let original = fixture()
        let swapped = original.replacingOccurrences(of: "\u{524d}10\u{5206}", with: "TEMP_HEADER")
            .replacingOccurrences(of: "\u{524d}1\u{6642}\u{9593}", with: "\u{524d}10\u{5206}")
            .replacingOccurrences(of: "TEMP_HEADER", with: "\u{524d}1\u{6642}\u{9593}")
        XCTAssertThrowsError(try FukuokaParser.parse(html: swapped))
    }
    func testNumericEntities() {
        XCTAssertEqual(FukuokaParser.plainText("A&nbsp;B &#x5143;&#23713;"), "A B \u{5143}\u{5ca1}")
        XCTAssertNil(FukuokaParser.rainValue("-999mm"))
        XCTAssertEqual(FukuokaParser.rainValue("<span>0.5</span>&nbsp;mm"), 0.5)
    }
    func testAMeDASQualityFlags() throws {
        let data = Data(#"{"82171":{"precipitation10m":[0.5,0],"precipitation1h":[4,0],"precipitation3h":[2,1],"precipitation24h":[null,8]}}"#.utf8)
        let o = try JMAParser.map(data, timestamp: now)
        XCTAssertEqual(o.tenMinutes, 0.5)
        XCTAssertEqual(o.oneHour, 4)
        XCTAssertNil(o.threeHours)
        XCTAssertNil(o.twentyFourHours)
        XCTAssertNil(JMAParser.normalValue([-999, 0]))
    }
    func testAMeDASAbsentStationFails() {
        XCTAssertThrowsError(try JMAParser.map(Data("{}".utf8), timestamp: now))
    }
    func testJSTVersusUTCTimestamps() {
        XCTAssertEqual(RainClock.compact(now), "20261115060000")
        XCTAssertEqual(RainClock.compact(now, utc: true), "20261114210000")
        XCTAssertEqual(RainClock.parseCompact("20261114210000", utc: true), now)
    }
    func testRadarExcludesForecastAndMalformedTime() throws {
        let frames = [
            RadarFrame(basetime: "20261114200000", validtime: "20261114200500", elements: ["hrpns"]),
            RadarFrame(basetime: "20261114200000", validtime: "20261114200000", elements: ["hrpns"]),
            RadarFrame(basetime: "not-a-date", validtime: "not-a-date", elements: ["hrpns"])
        ]
        let parsed = try JMAParser.radar(JSONEncoder().encode(frames))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(parsed[0].isAnalysis)
        XCTAssertTrue(parsed[0].tileTemplate.contains("/none/20261114200000/surf/hrpns/"))
    }
    func testRepeatedPollDoesNotBecomeThreeSamples() {
        let repeated = (0..<4).flatMap { _ in [reading(), reading(Stations.ikeda)] }
        let merged = RainAssessmentEngine.merge([], repeated, now: now)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: merged, destination: .takada, now: now).condition, .zeroSample)
    }
    func testThreeConsecutiveZeroSamples() {
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: dryHistory(), destination: .takada, now: now).condition, .quiet)
    }
    func testMissingIntervalDoesNotCountAsQuiet() {
        let gaps = [Stations.motooka, Stations.ikeda].flatMap { s in [0.0, 20, 30].map { reading(s, minutesAgo: $0) } }
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: gaps, destination: .takada, now: now).condition, .zeroSample)
    }
    func testStaleDataNeverMeansDry() {
        let old = [reading(minutesAgo: 31), reading(Stations.ikeda, minutesAgo: 31)]
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: old, destination: .takada, now: now).condition, .unavailable)
    }
    func testFutureDataRejected() {
        XCTAssertFalse(reading(minutesAgo: -5).isFresh(at: now))
        XCTAssertTrue(RainAssessmentEngine.merge([], [reading(minutesAgo: -5)], now: now).isEmpty)
    }
    func testMissingOrFailedProviderNeverMeansDry() {
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: dryHistory(), destination: .takada, now: now, failedProviders: [.fukuoka]).condition, .unavailable)
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: [reading(rain: nil), reading(Stations.ikeda)], destination: .takada, now: now).condition, .unavailable)
    }
    func testRainWinsWhenPresent() {
        let h = [reading(rain: 0.5), reading(Stations.ikeda)]
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: h, destination: .takada, now: now).condition, .rainRecorded)
    }
    func testDestinationRequiresDifferentStations() {
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: dryHistory(), destination: .gakken, now: now).condition, .unavailable)
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: dryHistory(), destination: .maebaru, now: now).condition, .unavailable)
    }
    func testNotificationOnlyAfterObservedRainAndOnlyOnce() {
        var gate = NotificationGate()
        XCTAssertFalse(gate.update(.quiet))
        XCTAssertFalse(gate.update(.rainRecorded))
        XCTAssertFalse(gate.update(.zeroSample))
        XCTAssertTrue(gate.update(.quiet))
        XCTAssertFalse(gate.update(.quiet))
        _ = gate.update(.rainRecorded)
        _ = gate.update(.unavailable)
        XCTAssertFalse(gate.update(.quiet))
    }
    func testOverzoomParentAndCrop() {
        let address = TileAddress.parent(x: 14115, y: 6563, z: 14, maximumNativeZoom: 10)
        XCTAssertEqual(address.x, 882)
        XCTAssertEqual(address.y, 410)
        XCTAssertEqual(address.z, 10)
        XCTAssertEqual(address.subdivisions, 16)
        XCTAssertEqual(address.column, 3)
        XCTAssertEqual(address.row, 3)
    }
    func testJSONHistoryRoundTrip() throws {
        let h = dryHistory()
        XCTAssertEqual(try JSONDecoder().decode([RainObservation].self, from: JSONEncoder().encode(h)), h)
    }
}
