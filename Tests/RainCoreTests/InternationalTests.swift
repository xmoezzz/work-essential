import XCTest
@testable import RainCore

final class InternationalTests: XCTestCase {
    func utc(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
    let november = "November 14, 2026"
    func uw(date: String = "November 14, 2026", time: String = "4:30 PM",
            labels: String = "15 mins/1 hr/24 hrs", values: String = "0.2/1.2/5.6") -> String {
        "<h1>Current Readings</h1><div>Date: \(date)&nbsp; Time: \(time)</div><p>Precipitation (Last \(labels)): \(values) mm</p>"
    }
    func parseUW(_ html: String) throws -> ParsedInternational {
        try UniversityParser.waterloo(html, fetchedAt: utc("2026-11-15T00:00:00Z"))
    }
    func wyRow(_ date: String, rain: String) -> String {
        "<tr><td>\(date)</td><td>31.1</td><td>\(rain)</td><td>0.1</td></tr>"
    }
    func wy(_ rows: String) -> String {
        "<h2>Laramie (Greenhouse)</h2><table><tr><th></th><th>Temp</th><th>Precip</th><th>Speed</th></tr><tr><th>Date Time (MST)</th><th>(F)</th><th>(in)</th><th>(mph)</th></tr>\(rows)</table>"
    }
    func payload(_ html: String, provider: Provider, status: Int = 200) -> SourcePayload {
        SourcePayload(requestURL: provider == .waterloo ? InternationalURLs.waterloo : InternationalURLs.wyoming,
                      receivedAt: utc("2026-11-15T00:00:00Z"), statusCode: status,
                      headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }
    func testWaterlooHas15MinuteNot10MinuteObservation() throws {
        let parsed = try parseUW(uw())
        let r = try XCTUnwrap(parsed.observations.first)
        XCTAssertEqual(r.fifteenMinutes, 0.2)
        XCTAssertNil(r.tenMinutes)
        XCTAssertEqual(r.oneHour, 1.2)
        XCTAssertEqual(r.twentyFourHours, 5.6)
        XCTAssertEqual(r.timestamp, utc("2026-11-14T21:30:00Z"))
        XCTAssertEqual(r.intervalLabel, "15分")
        XCTAssertEqual(parsed.fields[0].sourceValue, "0.2 mm")
    }
    func testWaterlooWinterValuesAreNotFabricatedInto15Minutes() throws {
        let r = try XCTUnwrap(parseUW(uw(labels: "1 hr/24 hrs", values: "0.4/8.2")).observations.first)
        XCTAssertNil(r.tenMinutes)
        XCTAssertNil(r.fifteenMinutes)
        XCTAssertEqual(r.oneHour, 0.4)
        XCTAssertEqual(r.displayValue, 0.4)
    }
    func testWaterlooMissingTokenRetainsOriginalNAText() throws {
        let p = try parseUW(uw(values: "N/A/1.2/5.6"))
        XCTAssertNil(p.observations.first?.fifteenMinutes)
        XCTAssertEqual(p.fields[0].sourceValue, "N/A mm")
        XCTAssertNotEqual(p.fields[0].parsedValue, 0)
    }
    func testWaterlooRejectsWrongPeriodsWithSameNumbers() {
        XCTAssertThrowsError(try parseUW(uw(labels: "15 hrs/1 min/24 mins")))
        XCTAssertThrowsError(try parseUW(uw(labels: "1 hr/15 mins/24 hrs")))
        XCTAssertThrowsError(try parseUW(uw(values: "1/2")))
    }
    func testWaterlooRejectsInvalidRainNotConvertsToZero() throws {
        for bad in ["NaN", "-1", "999999", "trace", "error"] {
            XCTAssertNil(try parseUW(uw(values: "\(bad)/1/2")).observations.first?.fifteenMinutes)
        }
    }
    func testWaterlooHonorsDaylightTime() throws {
        let p = try parseUW(uw(date: "July 14, 2026"))
        XCTAssertEqual(p.observations.first?.timestamp, utc("2026-07-14T20:30:00Z"))
    }
    func testWaterlooRejectsAmbiguousAutumnClock() {
        XCTAssertThrowsError(try parseUW(uw(date: "November 1, 2026", time: "1:30 AM")))
    }
    func testWaterlooRejectsFutureAndMissingClock() {
        XCTAssertThrowsError(try parseUW(uw(date: "November 20, 2026")))
        XCTAssertThrowsError(try parseUW("Precipitation (Last 15 mins/1 hr/24 hrs): 0/0/0 mm"))
    }
    func testWaterlooDoesNotReadJavaScriptAsObservations() throws {
        let html = "<script>" + uw(values: "99/99/99") + "</script>" + uw(values: "0/0/0")
        XCTAssertEqual(try parseUW(html).observations.first?.fifteenMinutes, 0)
    }
    func testWyomingInchesConversionAndUnknownWindow() throws {
        let html = wy(wyRow("2026-11-14 16:00:00", rain: "0.10"))
        let p = try UniversityParser.wyoming(html, fetchedAt: utc("2026-11-15T00:00:00Z"))
        let r = try XCTUnwrap(p.observations.first)
        XCTAssertEqual(try XCTUnwrap(r.reportedPrecipitation), 2.54, accuracy: 0.00001)
        XCTAssertNil(r.oneHour)
        XCTAssertNil(r.tenMinutes)
        XCTAssertEqual(r.timestamp, utc("2026-11-14T23:00:00Z"))
        XCTAssertEqual(p.fields[0].sourceValue, "0.10 in")
        XCTAssertTrue(html.contains(p.excerpt))
    }
    func testWyomingUsesFixedMSTEvenInSummer() throws {
        let p = try UniversityParser.wyoming(wy(wyRow("2026-07-14 16:00:00", rain: "0")), fetchedAt: utc("2026-11-15T00:00:00Z"))
        XCTAssertEqual(p.observations.first?.timestamp, utc("2026-07-14T23:00:00Z"))
    }
    func testWyomingSortsByObservationTimeNotTableOrder() throws {
        let p = try UniversityParser.wyoming(wy(wyRow("2026-11-14 16:00:00", rain: "0.10") + wyRow("2026-11-14 15:00:00", rain: "0.05")), fetchedAt: utc("2026-11-15T00:00:00Z"))
        XCTAssertEqual(p.observations.count, 2)
        XCTAssertEqual(p.fields[0].sourceValue, "0.10 in")
    }
    func testWyomingIgnoresOtherTables() throws {
        let other = "<table>" + wyRow("2026-11-14 17:00:00", rain: "99") + "</table>"
        let p = try UniversityParser.wyoming(wy(wyRow("2026-11-14 16:00:00", rain: "0.1")) + other, fetchedAt: utc("2026-11-15T01:00:00Z"))
        XCTAssertEqual(p.observations.count, 1)
    }
    func testWyomingMissingRainIsNotZero() throws {
        let p = try UniversityParser.wyoming(wy(wyRow("2026-11-14 16:00:00", rain: "--")), fetchedAt: utc("2026-11-15T00:00:00Z"))
        XCTAssertNil(p.observations.first?.reportedPrecipitation)
    }
    func testWyomingRejectsUnverifiedClockUnitAndStation() {
        let good = wy(wyRow("2026-11-14 16:00:00", rain: "0"))
        for bad in [good.replacingOccurrences(of: "MST", with: "Local"), good.replacingOccurrences(of: "(in)", with: "(cm)"), good.replacingOccurrences(of: "Greenhouse", with: "Other")] {
            XCTAssertThrowsError(try UniversityParser.wyoming(bad, fetchedAt: utc("2026-11-15T00:00:00Z")))
        }
    }
    func testUniversitySnapshotPreservesRawFailureBytes() {
        let body = "<html>maintenance &amp; service unavailable</html>\r\n"
        let p = payload(body, provider: .waterloo, status: 503)
        let s = SourceSnapshot.university(p, provider: .waterloo)
        XCTAssertNotNil(s.parseIssue)
        XCTAssertTrue(s.observations.isEmpty)
        XCTAssertEqual(s.responses.first?.body, Data(body.utf8))
    }
    func testUniversitySnapshotFieldsAndExcerpt() throws {
        let p = payload(uw(), provider: .waterloo)
        let s = SourceSnapshot.university(p, provider: .waterloo)
        XCTAssertNil(s.parseIssue)
        XCTAssertEqual(s.observationResponse?.id, p.id)
        XCTAssertEqual(s.fields(for: Stations.soulis).count, 3)
        XCTAssertTrue(try XCTUnwrap(s.excerpt(for: Stations.soulis)).contains("Precipitation"))
    }
    func testCoordinatesHaveExplicitProvenance() throws {
        let p = try XCTUnwrap(Stations.soulis.publishedPosition)
        XCTAssertEqual(p.point.latitude, 43.4737777778, accuracy: 0.0000001)
        XCTAssertEqual(p.point.longitude, -80.5576388889, accuracy: 0.0000001)
        XCTAssertEqual(p.provenance, .officialCatalog)
        XCTAssertNil(Stations.greenhouse.publishedPosition)
    }
    func testCampusStationSetsAreDisjoint() {
        XCTAssertEqual(Set(Campus.allCases.flatMap { $0.stations }.map(\.id)).count, Stations.all.count)
        XCTAssertEqual(Stations.all.count, 7)
        XCTAssertFalse(Campus.waterloo.contains(Campus.ito.center))
        XCTAssertTrue(Campus.waterloo.contains(Stations.soulis.instrumentLocation!))
        XCTAssertFalse(Campus.wyoming.supportsQuietWatch)
        XCTAssertFalse(Campus.waterloo.supportsRadar)
    }
    func testOverseasManualCoordinateValidation() {
        XCTAssertNotNil(StationPosition.user(latitude: 41.32, longitude: -105.56, note: "manual"))
        XCTAssertNotNil(StationPosition.user(latitude: 43.47, longitude: -80.56, note: "manual"))
        XCTAssertNil(StationPosition.user(latitude: 0, longitude: 0, note: "manual"))
    }
    func testOldObservationCacheDecodesWithNewOptionalFields() throws {
        let r = RainObservation(stationID: "motooka", timestamp: Date(), fetchedAt: Date(), tenMinutes: 0)
        let json = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(RainObservation.self, from: json)
        XCTAssertNil(decoded.fifteenMinutes)
        XCTAssertNil(decoded.reportedPrecipitation)
        XCTAssertEqual(decoded.tenMinutes, 0)
    }
    func testRegionLocalTimeUsesDifferentDays() {
        let d = utc("2026-11-14T22:00:00Z")
        XCTAssertTrue(RainClock.local(d, campus: .ito).contains("11/15"))
        XCTAssertTrue(RainClock.local(d, campus: .waterloo).contains("11/14"))
        XCTAssertTrue(RainClock.local(d, campus: .wyoming).contains("11/14"))
    }
    func readings(interval: Double = 900, value: Double? = 0) -> [RainObservation] {
        let now = utc("2026-11-15T00:00:00Z")
        return (0..<3).map { RainObservation(stationID: Stations.soulis.id, timestamp: now.addingTimeInterval(-Double($0) * interval), fetchedAt: now, tenMinutes: nil, oneHour: 0, fifteenMinutes: value) }
    }
    func assess(_ r: [RainObservation], failed: Set<Provider> = [], now: Date? = nil) -> RainAssessment {
        RainAssessmentEngine.evaluate(history: r, campus: .waterloo, now: now ?? utc("2026-11-15T00:00:00Z"), failedProviders: failed)
    }
    func testWaterlooQuietRequiresThreeAdjacent15MinuteReports() {
        XCTAssertEqual(assess(readings()).condition, .quiet)
        XCTAssertEqual(assess(Array(readings().prefix(2))).condition, .zeroSample)
        XCTAssertEqual(assess(readings(interval: 600)).condition, .zeroSample)
        XCTAssertEqual(assess(readings(interval: 1800)).condition, .zeroSample)
    }
    func testWaterlooDuplicatePollingDoesNotCreateQuietInterval() {
        let r = readings()[0]
        XCTAssertEqual(assess([r, r, r]).condition, .zeroSample)
    }
    func testWaterlooWinterHourlyZeroDoesNotTriggerQuiet() {
        XCTAssertEqual(assess(readings(value: nil)).condition, .unavailable)
    }
    func testWaterlooStaleOrFailedReportsDoNotTriggerQuiet() {
        XCTAssertEqual(assess(readings(), failed: [.waterloo]).condition, .unavailable)
        XCTAssertEqual(assess(readings(), now: utc("2026-11-15T01:00:00Z")).condition, .unavailable)
    }
    func testWaterlooWetAndNotificationGate() {
        var gate = NotificationGate()
        XCTAssertFalse(gate.update(assess(readings(value: 0.2)).condition))
        XCTAssertTrue(gate.update(assess(readings()).condition))
        XCTAssertFalse(gate.update(assess(readings()).condition))
    }
    func testOtherRegionFailureDoesNotContaminateWaterloo() {
        XCTAssertEqual(assess(readings(), failed: [.fukuoka, .wyoming]).condition, .quiet)
    }
    func testWyomingUnknownWindowNeverSendsQuietNotification() {
        let now = utc("2026-11-15T00:00:00Z")
        let r = RainObservation(stationID: Stations.greenhouse.id, timestamp: now, fetchedAt: now, tenMinutes: nil, reportedPrecipitation: 0)
        let result = RainAssessmentEngine.evaluate(history: [r], campus: .wyoming, now: now)
        XCTAssertEqual(result.condition, .unavailable)
        XCTAssertFalse(result.canNotify)
    }
}
