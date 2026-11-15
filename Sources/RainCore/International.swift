import Foundation

public enum InternationalURLs {
    public static let waterloo = URL(string: "https://www.civil.uwaterloo.ca/weatherstation/")!
    public static let waterlooInfo = URL(string: "https://www.civil.uwaterloo.ca/weatherstation/station-information/")!
    public static let wyoming = URL(string: "https://www.wrds.uwyo.edu/Mesonet/Greenhouse.html")!
}

public enum Campus: String, CaseIterable, Codable, Identifiable, Sendable {
    case ito, waterloo, wyoming
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .ito: return "九州大学 伊都"
        case .waterloo: return "Waterloo大学"
        case .wyoming: return "ワイオミング大学"
        }
    }
    public var shortLabel: String {
        switch self { case .ito: return "伊都"; case .waterloo: return "Waterloo"; case .wyoming: return "Wyoming" }
    }
    public var timeZone: TimeZone {
        switch self {
        case .ito: return TimeZone(identifier: "Asia/Tokyo")!
        case .waterloo: return TimeZone(identifier: "America/Toronto")!
        case .wyoming: return TimeZone(identifier: "America/Denver")!
        }
    }
    // Approximate campus landmarks, NOT instrument locations or the user's laboratory.
    public var center: GeoPoint {
        switch self {
        case .ito: return GeoPoint(33.583, 130.232)
        case .waterloo: return GeoPoint(43.4730, -80.5500)
        case .wyoming: return GeoPoint(41.3145, -105.5810)
        }
    }
    public var defaultLab: GeoPoint { self == .ito ? GeoPoint(33.5978, 130.2177) : center }
    public func contains(_ point: GeoPoint) -> Bool {
        guard point.latitude.isFinite, point.longitude.isFinite else { return false }
        return abs(point.latitude - center.latitude) <= 0.2 && abs(point.longitude - center.longitude) <= 0.3
    }
    public var stations: [Station] {
        switch self { case .ito: return Stations.ito; case .waterloo: return [Stations.soulis]; case .wyoming: return [Stations.greenhouse] }
    }
    public var providers: [Provider] {
        switch self { case .ito: return [.fukuoka, .jma]; case .waterloo: return [.waterloo]; case .wyoming: return [.wyoming] }
    }
    public var supportsRadar: Bool { true }
    public var supportsQuietWatch: Bool { self != .wyoming }
    public var watchDescription: String {
        switch self {
        case .ito: return "降雨後、10分雨量が3回連続で0 mm"
        case .waterloo: return "15分降水量が公開される時のみ。3回連続で0 mm"
        case .wyoming: return "集計期間が未確認のため通知対象外"
        }
    }
    public var dataNotice: String {
        switch self {
        case .ito: return "伊都・高田・学研都市・前原"
        case .waterloo: return "北キャンパスの実測。冬季は15分値がない場合があります。"
        case .wyoming: return "Greenhouseの公開観測表。毎時の行を読み取ります。"
        }
    }
    public var sourceURL: URL {
        switch self { case .ito: return URL(string: "https://bousai.city.fukuoka.lg.jp/")!; case .waterloo: return InternationalURLs.waterloo; case .wyoming: return InternationalURLs.wyoming }
    }
    public var mapAttribution: String {
        switch self { case .ito: return "国土地理院"; case .waterloo: return "Canada Base Map / Natural Resources Canada"; case .wyoming: return "USGS The National Map" }
    }
    public var mapSourceURL: URL {
        switch self {
        case .ito: return URL(string: "https://maps.gsi.go.jp/development/ichiran.html")!
        case .waterloo: return URL(string: "https://open.canada.ca/data/en/dataset/296de17c-001c-4435-8f9a-f5acab632e85")!
        case .wyoming: return URL(string: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer")!
        }
    }
    public var overseasBaseTemplate: String? {
        switch self {
        case .ito: return nil
        case .waterloo: return "https://maps-cartes.services.geo.ca/server2_serveur2/rest/services/BaseMaps/CBMT_CBCT_GEOM_3857/MapServer/tile/{z}/{y}/{x}"
        case .wyoming: return "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}"
        }
    }
    public var labelsTemplate: String? {
        self == .waterloo ? "https://maps-cartes.services.geo.ca/server2_serveur2/rest/services/BaseMaps/CBMT_TXT_3857/MapServer/tile/{z}/{y}/{x}" : nil
    }
}

extension Stations {
    public static let soulis = Station(id: "waterloo-soulis", name: "Soulis", localName: "Soulis（北キャンパス）", provider: .waterloo, pageFile: nil,
        address: "University of Waterloo / Columbia Lake", instrumentLocation: GeoPoint(43 + 28.0/60 + 25.6/3600, -(80 + 33.0/60 + 27.5/3600)))
    public static let greenhouse = Station(id: "wyoming-greenhouse", name: "Greenhouse", localName: "Laramie Greenhouse", provider: .wyoming, pageFile: nil,
        address: "University of Wyoming / LREC Greenhouse, Laramie", instrumentLocation: nil)
}

extension Provider {
    public var key: String {
        switch self { case .fukuoka: return "city"; case .jma: return "amedas"; case .waterloo: return "waterloo"; case .wyoming: return "wyoming" }
    }
    public var pollInterval: TimeInterval { self == .waterloo ? 900 : (self == .wyoming ? 1800 : 600) }
}

extension Station {
    public var campus: Campus {
        switch provider { case .fukuoka, .jma: return .ito; case .waterloo: return .waterloo; case .wyoming: return .wyoming }
    }
    public var freshnessLimit: TimeInterval { provider == .wyoming ? 90 * 60 : (provider == .waterloo ? 35 * 60 : 20 * 60) }
    public var intervalNote: String {
        switch provider {
        case .fukuoka, .jma: return "10分・1時間・3時間・24時間の積算雨量。"
        case .waterloo: return "15分値は換算せず表示。冬季の降水量は雪の水当量を含みます。雨と雪を判別しません。"
        case .wyoming: return "公開表のPrecip列（in）をmmに換算。行は毎時ですが積算期間は未確認。1時間雨量とは扱いません。"
        }
    }
}

extension RainObservation {
    public var displayValue: Double? {
        switch Stations.find(stationID)?.provider {
        case .waterloo: return fifteenMinutes ?? oneHour
        case .wyoming: return reportedPrecipitation
        default: return tenMinutes
        }
    }
    public var intervalLabel: String {
        switch Stations.find(stationID)?.provider {
        case .waterloo: return fifteenMinutes != nil ? "15分" : "1時間"
        case .wyoming: return "集計期間未確認"
        default: return "10分"
        }
    }
    public var shortWindowValue: Double? {
        Stations.find(stationID)?.provider == .waterloo ? fifteenMinutes : tenMinutes
    }
}

extension RainClock {
    public static func local(_ date: Date, campus: Campus, short: Bool = false) -> String {
        let f = formatter(short ? "HH:mm" : "MM/dd HH:mm zzz")
        f.timeZone = campus.timeZone
        return f.string(from: date)
    }
}

/// Only published measurement fields are parsed. No synthetic or forecast fallback.
public struct ParsedInternational: Sendable {
    public let observations: [RainObservation]
    public let fields: [RawRainField]
    public let excerpt: String
}

public enum UniversityParser {
    static func first(_ pattern: String, in text: String) -> [String]? {
        guard let m = FukuokaParser.matches(pattern, text).first else { return nil }
        return (0..<m.numberOfRanges).map { FukuokaParser.capture(m, $0, text) }
    }
    static func text(_ html: String) -> String {
        let clean = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        return FukuokaParser.plainText(clean)
    }
    static func number(_ raw: String, max: Double) -> Double? {
        guard let n = FukuokaParser.rainValue(raw), n <= max else { return nil }
        return n
    }
    public static func waterloo(_ html: String, fetchedAt: Date) throws -> ParsedInternational {
        let t = text(html)
        guard let stamp = first("Date:\\s*([A-Za-z]+\\s+[0-9]{1,2},\\s*[0-9]{4})\\s*Time:\\s*([0-9]{1,2}:[0-9]{2}\\s*[AP]M)", in: t) else {
            throw RainError.invalidData("Waterlooの観測時刻を解析できません。公式ページと受信原文を確認してください。")
        }
        let f = RainClock.formatter("MMMM d, yyyy h:mm a")
        f.timeZone = Campus.waterloo.timeZone
        let rawTime = stamp[1] + " " + stamp[2].uppercased()
        guard let date = f.date(from: rawTime), date <= fetchedAt.addingTimeInterval(60) else {
            throw RainError.invalidData("Waterlooの時刻が不正、または未来の時刻です。")
        }
        // During a fall-back hour the page's clock has no offset and is ambiguous.
        // Do not guess which occurrence belongs to the observation.
        let displayedTime = f.string(from: date)
        if [-3600.0, 3600.0].contains(where: { f.string(from: date.addingTimeInterval($0)) == displayedTime }) {
            throw RainError.invalidData("Waterlooの時刻が夏時間終了時の重複時刻です。時差が確定するまで判定しません。")
        }
        guard let rain = first("Precipitation\\s*\\(([^)]*)\\)\\s*:\\s*(.*?)\\s*mm\\b", in: t) else {
            throw RainError.invalidData("Waterlooの降水量列が見つかりません。")
        }
        let labels = rain[1].lowercased().replacingOccurrences(of: "last", with: "").split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        // Splitting on slash would split N/A. Replace that token before splitting.
        let tokens = rain[2].replacingOccurrences(of: "N/A", with: "MISSING", options: .caseInsensitive).components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        let expected: [[String]] = [["15", "1", "24"], ["1", "24"]]
        let numbers = labels.map { first("^([0-9]+)\\s*(?:mins?|minutes?|h|hrs?|hours?)$", in: $0)?[1] ?? "" }
        let unitPatterns = labels.count == 3 ? ["^15\\s*(?:mins?|minutes?)$", "^1\\s*(?:h|hrs?|hours?)$", "^24\\s*(?:h|hrs?|hours?)$"] : ["^1\\s*(?:h|hrs?|hours?)$", "^24\\s*(?:h|hrs?|hours?)$"]
        let unitsMatch = labels.count == unitPatterns.count && zip(labels, unitPatterns).allSatisfy { first($0.1, in: $0.0) != nil }
        guard expected.contains(numbers), unitsMatch, labels.count == tokens.count else {
            throw RainError.invalidData("Waterlooの統計時間の並びが変わりました。値の推測は行いません。")
        }
        let has15 = numbers.count == 3
        let p15 = has15 ? number(tokens[0], max: 300) : nil
        let p1 = number(tokens[has15 ? 1 : 0], max: 1500)
        let p24 = number(tokens[has15 ? 2 : 1], max: 4000)
        let record = RainObservation(stationID: Stations.soulis.id, timestamp: date, fetchedAt: fetchedAt,
            tenMinutes: nil, oneHour: p1, twentyFourHours: p24, fifteenMinutes: p15,
            sourceTimestampText: rawTime, sourceTimeZoneNote: "America/Toronto（現地時間として解釈、夏時間対応）")
        let parsed = has15 ? [p15, p1, p24] : [p1, p24]
        let names = has15 ? ["15分降水量", "1時間降水量", "24時間降水量"] : ["1時間降水量", "24時間降水量"]
        let fields = tokens.indices.map { RawRainField(id: "uw-\($0)", label: names[$0], sourceValue: tokens[$0].replacingOccurrences(of: "MISSING", with: "N/A") + " mm", parsedValue: parsed[$0]) }
        return ParsedInternational(observations: [record], fields: fields, excerpt: stamp[0] + "\n" + rain[0])
    }
    public static func wyoming(_ html: String, fetchedAt: Date) throws -> ParsedInternational {
        let plain = text(html)
        guard plain.contains("Laramie"), plain.contains("Greenhouse"),
              first("Date\\s*Time\\s*\\(MST\\)", in: plain) != nil else {
            throw RainError.invalidData("Greenhouseの観測所名、またはMST時刻表記が確認できません。")
        }
        // Require the known column order and inches. An hourly row does NOT establish an hourly accumulation.
        guard first("Temp\\s+Precip\\s+Speed", in: plain) != nil,
              first("\\(F\\)\\s*\\(in\\)", in: plain) != nil else {
            throw RainError.invalidData("Greenhouseの列順または単位が想定と異なります。")
        }
        let f = RainClock.formatter("yyyy-MM-dd HH:mm:ss")
        f.timeZone = TimeZone(secondsFromGMT: -7 * 3600)! // Explicit MST, never America/Denver daylight time.
        var records: [(RainObservation, String, String)] = []
        let tables = FukuokaParser.matches("<table\\b[^>]*>(.*?)</table\\s*>", html).map { FukuokaParser.capture($0, 0, html) }
        let knownTables = tables.filter {
            let t = text($0)
            return first("Temp\\s+Precip\\s+Speed", in: t) != nil && first("Date\\s*Time\\s*\\(MST\\)", in: t) != nil && first("\\(F\\)\\s*\\(in\\)", in: t) != nil
        }
        for table in knownTables {
            for row in FukuokaParser.matches("<tr\\b[^>]*>(.*?)</tr\\s*>", table) {
                let raw = FukuokaParser.capture(row, 0, table)
                let cells = FukuokaParser.matches("<t[dh]\\b[^>]*>(.*?)</t[dh]\\s*>", raw).map { text(FukuokaParser.capture($0, 1, raw)) }
                guard cells.count >= 4, let date = f.date(from: cells[0]), date <= fetchedAt.addingTimeInterval(60) else { continue }
                let inches = number(cells[2], max: 160)
                let record = RainObservation(stationID: Stations.greenhouse.id, timestamp: date, fetchedAt: fetchedAt,
                    tenMinutes: nil, reportedPrecipitation: inches.map { $0 * 25.4 },
                    sourceTimestampText: cells[0] + " MST", sourceTimeZoneNote: "配信元はMST（UTC-07:00固定）。画面は現地時間に変換。")
                records.append((record, raw, cells[2]))
            }
        }
        records.sort { $0.0.timestamp < $1.0.timestamp }
        guard let latest = records.last else { throw RainError.invalidData("Greenhouseの観測行を解析できません。") }
        return ParsedInternational(observations: records.map(\.0),
            fields: [RawRainField(id: "precip", label: "公表降水量（期間未確認）", sourceValue: latest.2 + " in", parsedValue: latest.0.reportedPrecipitation)], excerpt: latest.1)
    }
}

extension SourceSnapshot {
    public static func university(_ payload: SourcePayload, provider: Provider, preceding: [SourcePayload] = []) -> SourceSnapshot {
        do {
            try payload.validate()
            guard let html = payload.text else { throw RainError.invalidData("HTMLの文字コードを判別できません。") }
            let parsed: ParsedInternational
            switch provider {
            case .waterloo: parsed = try UniversityParser.waterloo(html, fetchedAt: payload.receivedAt)
            case .wyoming: parsed = try UniversityParser.wyoming(html, fetchedAt: payload.receivedAt)
            default: throw RainError.invalidData("大学観測アダプターの対象外です。")
            }
            return SourceSnapshot(provider: provider, responses: preceding + [payload], observations: parsed.observations)
        } catch { return SourceSnapshot(provider: provider, responses: preceding + [payload], parseIssue: error.localizedDescription) }
    }
    func internationalParsed() -> ParsedInternational? {
        guard let response = observationResponse, let html = response.text else { return nil }
        if provider == .waterloo { return try? UniversityParser.waterloo(html, fetchedAt: response.receivedAt) }
        if provider == .wyoming { return try? UniversityParser.wyoming(html, fetchedAt: response.receivedAt) }
        return nil
    }
}

extension GovernmentClient {
    public func campusSnapshot(_ provider: Provider) async throws -> SourceSnapshot {
        switch provider {
        case .fukuoka: return try await fukuokaSnapshot()
        case .jma: return try await maebaruSnapshot()
        case .wyoming: return .university(try await response(InternationalURLs.wyoming), provider: .wyoming)
        case .waterloo:
            let page = try await response(InternationalURLs.waterloo)
            let direct = SourceSnapshot.university(page, provider: .waterloo)
            if direct.parseIssue == nil { return direct }
            // Some deployments embed the readings. Follow only HTTPS, university-owned iframes,
            // at most two, with no recursion and without executing JavaScript.
            let html = page.text ?? ""
            var payloads = [page]
            let links = FukuokaParser.matches("<iframe\\b[^>]*\\bsrc=[\"']([^\"']+)[\"']", html)
            for match in links.prefix(2) {
                let raw = FukuokaParser.capture(match, 1, html).replacingOccurrences(of: "&amp;", with: "&")
                guard let url = URL(string: raw, relativeTo: page.responseURL)?.absoluteURL,
                      url.scheme == "https", ["weather.uwaterloo.ca", "www.weather.uwaterloo.ca", "www.civil.uwaterloo.ca"].contains(url.host ?? "") else { continue }
                do {
                    let payload = try await response(url)
                    let parsed = SourceSnapshot.university(payload, provider: .waterloo, preceding: payloads)
                    payloads.append(payload)
                    if parsed.parseIssue == nil { return parsed }
                } catch { continue }
            }
            return SourceSnapshot(provider: .waterloo, responses: payloads, parseIssue: direct.parseIssue)
        }
    }
}
