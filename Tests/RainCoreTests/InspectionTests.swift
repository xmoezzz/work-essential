
import XCTest
@testable import RainCore

final class InspectionTests: XCTestCase {
    let now = RainClock.parseCompact("20261115060000")!
    let cityURL = URL(string: "https://bousai.city.fukuoka.lg.jp/")!
    let mapURL = URL(string: "https://www.jma.go.jp/bosai/amedas/data/map/20261115060000.json")!
    var html: String {
        """
        <h3>雨量観測時刻：2026年11月15日 05:40</h3>
        <table><tr><th>地点</th><th>前10分</th><th>前1時間</th><th>前3時間</th><th>前24時間</th></tr>
        <tr><td><a href="puryo0820018.html">元岡</a><br>太郎丸</td><td><b>2.5mm</b></td><td>10.0mm</td><td>11.5mm</td><td>28.0mm</td></tr>
        <tr><td><a href="puryo0000154.html">糸島池田</a></td><td>0.0mm</td><td>7.0mm</td><td>9.0mm</td><td>22.0mm</td></tr></table>
        """
    }
    func payload(_ text: String, url: URL? = nil, status: Int = 200) -> SourcePayload {
        SourcePayload(requestURL: url ?? cityURL, receivedAt: now, statusCode: status,
                      headers: ["Content-Type": url == nil ? "text/html; charset=utf-8" : "application/json"], body: Data(text.utf8))
    }
    func testResponsePreservesBodyAndReceiptMetadata() throws {
        let body = "  <p>元岡 &nbsp; 0.0mm</p>\r\n"
        let p = payload(body)
        XCTAssertEqual(p.body, Data(body.utf8))
        XCTAssertEqual(p.text, body)
        XCTAssertEqual(p.receivedAt, now)
        XCTAssertEqual(p.statusCode, 200)
        XCTAssertEqual(p.requestURL, cityURL)
        XCTAssertEqual(p.fileExtension, "html")
    }
    func testHTTPFailureStillHasOriginalBody() {
        let p = payload("<h1>503 unavailable</h1>", status: 503)
        let s = SourceSnapshot.fukuoka(p)
        XCTAssertTrue(s.observations.isEmpty)
        XCTAssertNotNil(s.parseIssue)
        XCTAssertEqual(s.responses.first?.body, p.body)
        XCTAssertEqual(s.responses.first?.statusCode, 503)
    }
    func testParseFailureDoesNotDiscardSource() {
        let p = payload("<html>New layout / unknown</html>")
        let s = SourceSnapshot.fukuoka(p)
        XCTAssertNotNil(s.parseIssue)
        XCTAssertTrue(s.observations.isEmpty)
        XCTAssertEqual(s.responses.first?.text, p.text)
        XCTAssertNil(s.excerpt(for: Stations.motooka))
    }
    func testExactHTMLExcerptRetainsMarkup() {
        let s = SourceSnapshot.fukuoka(payload(html))
        let raw = s.exactHTMLRow(for: Stations.motooka)
        XCTAssertNotNil(raw)
        XCTAssertTrue(raw!.contains("<b>2.5mm</b>"))
        XCTAssertTrue(html.contains(raw!))
        XCTAssertEqual(s.fields(for: Stations.motooka).first?.sourceValue, "2.5mm")
        XCTAssertEqual(s.fields(for: Stations.motooka).first?.parsedValue, 2.5)
    }
    func testUnknownHeaderDoesNotPairWrongHTMLWithKnownValue() {
        let ignored = """
        <table><tr><th>地点</th><th>前1時間</th><th>前10分</th><th>前3時間</th><th>前24時間</th></tr>
        <tr><td><a href="puryo0820018.html">元岡</a></td><td>99.0mm</td><td>88.0mm</td><td>77.0mm</td><td>66.0mm</td></tr></table>
        """
        let s = SourceSnapshot.fukuoka(payload(html + ignored))
        XCTAssertEqual(s.observations.first?.tenMinutes, 2.5)
        XCTAssertFalse(s.exactHTMLRow(for: Stations.motooka)!.contains("99.0"))
    }
    func testMissingHTMLValueRetainedAndNotZero() {
        let raw = html.replacingOccurrences(of: "<b>2.5mm</b>", with: "<b>欠測</b>")
        let s = SourceSnapshot.fukuoka(payload(raw))
        XCTAssertEqual(s.fields(for: Stations.motooka).first?.sourceValue, "欠測")
        XCTAssertNil(s.fields(for: Stations.motooka).first?.parsedValue)
        XCTAssertNil(s.observations.first?.tenMinutes)
    }
    func testJSONQualityAndNullSurviveExcerpt() throws {
        let raw = #"{ "82171": {"precipitation10m":[0.5,0],"precipitation1h":[12,1],"precipitation3h":[null,8],"precipitation24h":[-999,0]} }"#
        let p = payload(raw, url: mapURL)
        let s = SourceSnapshot.amedas([p], timestamp: now)
        let fields = s.fields(for: Stations.maebaru)
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[0].parsedValue, 0.5)
        XCTAssertNil(fields[1].parsedValue)
        XCTAssertEqual(fields[1].sourceValue, "[12,1]")
        XCTAssertEqual(fields[2].sourceValue, "[null,8]")
        XCTAssertNil(fields[3].parsedValue)
        XCTAssertTrue(s.excerpt(for: Stations.maebaru)!.contains("null"))
        XCTAssertEqual(s.responses.first?.body, Data(raw.utf8))
    }
    func testMissingJMAStationHasFullResponseButNoInventedExcerpt() {
        let p = payload(#"{"11111":{"precipitation10m":[2,0]}}"#, url: mapURL)
        let s = SourceSnapshot.amedas([p], timestamp: now)
        XCTAssertNotNil(s.parseIssue)
        XCTAssertNil(s.excerpt(for: Stations.maebaru))
        XCTAssertTrue(s.fields(for: Stations.maebaru).isEmpty)
        XCTAssertEqual(s.responses.first?.body, p.body)
    }
    func testClockResponseIsNotRainResponse() {
        let p = payload("2026-11-15T06:00:00+09:00", url: URL(string: "https://www.jma.go.jp/bosai/amedas/data/latest_time.txt")!)
        let s = SourceSnapshot(provider: .jma, responses: [p], parseIssue: "map request failed")
        XCTAssertNil(s.observationResponse)
        XCTAssertNil(s.excerpt(for: Stations.maebaru))
    }
    func testCityCoordinatesAreNotFabricated() {
        for station in Stations.city { XCTAssertNil(station.publishedPosition) }
        XCTAssertEqual(Stations.maebaru.publishedPosition?.point, GeoPoint(33.56, 130.19))
        XCTAssertEqual(Stations.maebaru.publishedPosition?.provenance, .officialCatalog)
    }
    func testManualPositionAlwaysHasUnverifiedProvenance() throws {
        let p = try XCTUnwrap(StationPosition.user(latitude: 33.56, longitude: 130.23, note: "User checked map"))
        XCTAssertEqual(p.provenance, .userEntered)
        XCTAssertTrue(p.gsiURL.absoluteString.contains("/33.56/130.23/"))
        let decoded = try JSONDecoder().decode(StationPosition.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
    }
    func testInvalidOrUndocumentedPositionIsRejected() {
        XCTAssertNil(StationPosition.user(latitude: .nan, longitude: 130.23, note: "x"))
        XCTAssertNil(StationPosition.user(latitude: 33.56, longitude: .infinity, note: "x"))
        XCTAssertNil(StationPosition.user(latitude: 35.6, longitude: 139.6, note: "x"))
        XCTAssertNil(StationPosition.user(latitude: 33.56, longitude: 130.23, note: "  "))
    }
    func testAllCityStationsHaveVerifiedSourceMapLinks() {
        XCTAssertTrue(Stations.city.allSatisfy { $0.positionMapURL?.host == "bousai.city.fukuoka.lg.jp" })
        XCTAssertNil(Stations.maebaru.positionMapURL)
    }
    func testJapanesePresentationLabels() {
        XCTAssertEqual(Destination.gakken.label, "九大学研都市")
        XCTAssertEqual(Provider.jma.label, "気象庁 アメダス")
        XCTAssertEqual(Stations.motooka.address, "福岡市西区太郎丸1丁目")
        XCTAssertEqual(RainAssessmentEngine.evaluate(history: [], destination: .takada, now: now).title, "新しい観測値が足りません")
    }
}
