import Foundation

/// The original response body returned by URLSession, before parsing or formatting.
/// HTTP transfer decompression may already have been performed by URLSession.
public struct SourcePayload: Identifiable, Sendable {
    public let id: UUID
    public let requestURL: URL
    public let responseURL: URL
    public let receivedAt: Date
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
    public init(requestURL: URL, responseURL: URL? = nil, receivedAt: Date = Date(),
                statusCode: Int = 200, headers: [String: String] = [:], body: Data) {
        id = UUID(); self.requestURL = requestURL; self.responseURL = responseURL ?? requestURL
        self.receivedAt = receivedAt; self.statusCode = statusCode; self.headers = headers; self.body = body
    }
    public var contentType: String { headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/octet-stream" }
    public var text: String? {
        let type = contentType.lowercased()
        if type.contains("shift_jis") || type.contains("shift-jis") {
            return String(data: body, encoding: .shiftJIS)
        }
        if type.contains("euc-jp") { return String(data: body, encoding: .japaneseEUC) }
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .shiftJIS)
            ?? String(data: body, encoding: .japaneseEUC)
    }
    public var fileExtension: String {
        if contentType.contains("json") || requestURL.pathExtension == "json" { return "json" }
        if contentType.contains("html") || requestURL.pathExtension == "html" { return "html" }
        return text == nil ? "bin" : "txt"
    }
    public var suggestedFilename: String {
        "Otsukaresama-\(RainClock.compact(receivedAt))-\(id.uuidString.prefix(8)).\(fileExtension)"
    }
    public func validate() throws {
        guard (200...299).contains(statusCode) else {
            throw RainError.invalidResponse("HTTP \(statusCode): \(requestURL.host ?? "")\(requestURL.path)")
        }
        guard !body.isEmpty, body.count <= 8_000_000 else {
            throw RainError.invalidData("応答が空、またはサイズ上限を超えています。")
        }
    }
}

public struct RawRainField: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let sourceValue: String
    public let parsedValue: Double?
}

public struct SourceSnapshot: Sendable {
    public let provider: Provider
    public let responses: [SourcePayload]
    public let observations: [RainObservation]
    public let parseIssue: String?
    public init(provider: Provider, responses: [SourcePayload], observations: [RainObservation] = [], parseIssue: String? = nil) {
        self.provider = provider; self.responses = responses; self.observations = observations; self.parseIssue = parseIssue
    }
    public var observationResponse: SourcePayload? {
        responses.last { provider != .jma || $0.requestURL.path.contains("/data/map/") }
    }
    public static func fukuoka(_ response: SourcePayload) -> SourceSnapshot {
        do {
            try response.validate()
            guard let html = response.text else { throw RainError.invalidData("HTMLの文字コードを判別できません。") }
            return SourceSnapshot(provider: .fukuoka, responses: [response],
                observations: try FukuokaParser.parse(html: html, fetchedAt: response.receivedAt))
        } catch { return SourceSnapshot(provider: .fukuoka, responses: [response], parseIssue: error.localizedDescription) }
    }
    public static func amedas(_ responses: [SourcePayload], timestamp: Date) -> SourceSnapshot {
        do {
            guard let response = responses.last else { throw RainError.invalidData("応答がありません。") }
            try response.validate()
            return SourceSnapshot(provider: .jma, responses: responses,
                observations: [try JMAParser.map(response.body, timestamp: timestamp, fetchedAt: response.receivedAt)])
        } catch { return SourceSnapshot(provider: .jma, responses: responses, parseIssue: error.localizedDescription) }
    }
    public func exactHTMLRow(for station: Station) -> String? {
        guard provider == .fukuoka, let html = observationResponse?.text, let file = station.pageFile else { return nil }
        // Use precisely the same accepted table, timestamp and row as the parser.
        // An unrecognized layout must not pair an old parsed value with a different row.
        guard let rows = try? FukuokaParser.parseRows(html: html, fetchedAt: observationResponse?.receivedAt ?? Date()) else { return nil }
        return rows.first { $0.observation.stationID == station.id && $0.html.contains(file) }?.html
    }
    public func excerpt(for station: Station) -> String? {
        if provider == .waterloo || provider == .wyoming { return internationalParsed()?.excerpt }
        if provider == .fukuoka { return exactHTMLRow(for: station) }
        guard let data = observationResponse?.body,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[station.id],
              let pretty = try? JSONSerialization.data(withJSONObject: [station.id: entry], options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
    public func fields(for station: Station) -> [RawRainField] {
        if provider == .waterloo || provider == .wyoming { return internationalParsed()?.fields ?? [] }
        let labels = ["10分雨量", "1時間雨量", "3時間雨量", "24時間雨量"]
        let observation = observations.first { $0.stationID == station.id }
        let parsed = [observation?.tenMinutes, observation?.oneHour, observation?.threeHours, observation?.twentyFourHours]
        if provider == .fukuoka {
            guard let row = exactHTMLRow(for: station), let file = station.pageFile else { return [] }
            let cells = FukuokaParser.matches("<t[dh]\\b[^>]*>(.*?)</t[dh]\\s*>", row).map { FukuokaParser.capture($0, 1, row) }
            guard let index = cells.firstIndex(where: { $0.contains(file) }), cells.count >= index + 5 else { return [] }
            return (0..<4).map { i in RawRainField(id: String(i), label: labels[i],
                sourceValue: FukuokaParser.plainText(cells[index + i + 1]), parsedValue: parsed[i]) }
        }
        let keys = ["precipitation10m", "precipitation1h", "precipitation3h", "precipitation24h"]
        guard let data = observationResponse?.body,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[station.id] as? [String: Any] else { return [] }
        return (0..<4).map { i in
            let raw: String
            if let value = entry[keys[i]], let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) {
                raw = String(decoding: data, as: UTF8.self)
            } else { raw = "フィールドなし" }
            return RawRainField(id: keys[i], label: labels[i], sourceValue: raw, parsedValue: parsed[i])
        }
    }
}

public enum PositionProvenance: String, Codable, Sendable {
    case officialCatalog, userEntered
    public var label: String {
        self == .officialCatalog ? "公式公開座標" : "ユーザー入力（未検証）"
    }
}
public struct StationPosition: Codable, Hashable, Sendable {
    public let point: GeoPoint
    public let provenance: PositionProvenance
    public let source: String
    public let note: String
    public init(point: GeoPoint, provenance: PositionProvenance, source: String, note: String) {
        self.point = point; self.provenance = provenance; self.source = source; self.note = note
    }
    public static func user(latitude: Double, longitude: Double, note: String) -> StationPosition? {
        guard latitude.isFinite, longitude.isFinite, Campus.allCases.contains(where: { $0.contains(GeoPoint(latitude, longitude)) }),
              !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return StationPosition(point: GeoPoint(latitude, longitude), provenance: .userEntered,
                               source: "このMacで入力", note: note)
    }
    public var coordinateText: String { String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), point.latitude, point.longitude) }
    public var gsiURL: URL {
        if Campus.ito.contains(point) { return URL(string: "https://maps.gsi.go.jp/#17/\(point.latitude)/\(point.longitude)/&base=pale&ls=pale&disp=1")! }
        return URL(string: "https://maps.apple.com/?ll=\(point.latitude),\(point.longitude)&z=16")!
    }
}
extension Station {
    public var publishedPosition: StationPosition? {
        guard let point = instrumentLocation else { return nil }
        if provider == .waterloo {
            return StationPosition(point: point, provenance: .officialCatalog,
                source: InternationalURLs.waterlooInfo.absoluteString,
                note: "43d 28m 25.6s N, 80d 33m 27.5s W. 公開の度分秒を小数度に換算。測位精度は増しません。")
        }
        return StationPosition(point: point, provenance: .officialCatalog,
            source: "https://www.jma.go.jp/bosai/amedas/const/amedastable.json",
            note: "気象庁公開値は北緯33度33.6分、東経130度11.4分。小数度に換算しても測位精度は増しません。")
    }
    public var positionMapURL: URL? {
        // Only filenames verified from official station pages are listed.
        let paths = ["motooka": "map_rain_820018.png", "ikeda": "map_rain_0154.png",
                     "imajuku": "map_rain_0111.png", "zuibaiji": "map_rain_0155.png"]
        guard let path = paths[id] else { return nil }
        return URL(string: "https://bousai.city.fukuoka.lg.jp/map/rain/\(path)")
    }
}
