import Foundation

public enum Provider: String, Codable, Sendable {
    case fukuoka, jma, waterloo, wyoming
    public var label: String {
        switch self {
        case .fukuoka: return "福岡市・県 雨量計"
        case .jma: return "気象庁 アメダス"
        case .waterloo: return "Waterloo大学 Soulis観測所"
        case .wyoming: return "Wyoming Mesonet / WRDS"
        }
    }
}

public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude; self.longitude = longitude
    }
}

public struct Station: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let localName: String
    public let provider: Provider
    public let pageFile: String?
    public let address: String
    // No guessed instrument coordinates. Only the JMA station has verified coordinates.
    public let instrumentLocation: GeoPoint?
    public var sourceURL: URL {
        if provider == .waterloo { return InternationalURLs.waterloo }
        if provider == .wyoming { return InternationalURLs.wyoming }
        if let file = pageFile { return URL(string: "https://bousai.city.fukuoka.lg.jp/\(file)")! }
        return URL(string: "https://www.jma.go.jp/bosai/amedas/#amdno=82171&area_type=offices&area_code=400000")!
    }
}

public enum Stations {
    public static let motooka = Station(id: "motooka", name: "元岡", localName: "元岡", provider: .fukuoka, pageFile: "puryo0820018.html", address: "福岡市西区太郎丸1丁目", instrumentLocation: nil)
    public static let imajuku = Station(id: "imajuku", name: "今宿", localName: "今宿", provider: .fukuoka, pageFile: "puryo0000111.html", address: "福岡市西区今宿青木", instrumentLocation: nil)
    public static let ikeda = Station(id: "ikeda", name: "糸島池田", localName: "糸島池田", provider: .fukuoka, pageFile: "puryo0000154.html", address: "糸島市池田", instrumentLocation: nil)
    public static let zuibaiji = Station(id: "zuibaiji", name: "瑞梅寺", localName: "瑞梅寺", provider: .fukuoka, pageFile: "puryo0000155.html", address: "糸島市瑞梅寺", instrumentLocation: nil)
    public static let maebaru = Station(id: "82171", name: "前原", localName: "前原", provider: .jma, pageFile: nil, address: "糸島市前原西", instrumentLocation: GeoPoint(33.56, 130.19))
    public static let city: [Station] = [motooka, imajuku, ikeda, zuibaiji]
    public static let ito: [Station] = city + [maebaru]
    public static let all: [Station] = ito + [soulis, greenhouse]
    public static func find(_ id: String) -> Station? { all.first { $0.id == id } }
}

public enum Destination: String, CaseIterable, Codable, Identifiable, Sendable {
    case takada, gakken, maebaru
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .takada: return "高田"
        case .gakken: return "九大学研都市"
        case .maebaru: return "前原"
        }
    }
    public var referenceStations: [Station] {
        switch self {
        case .takada: return [Stations.motooka, Stations.ikeda]
        case .gakken: return [Stations.motooka, Stations.imajuku]
        case .maebaru: return [Stations.motooka, Stations.ikeda, Stations.maebaru]
        }
    }
}

public enum TimestampKind: String, Codable, Sendable { case pageSnapshot, observation }

public struct RainObservation: Codable, Identifiable, Equatable, Sendable {
    public let stationID: String
    public let timestamp: Date
    public let fetchedAt: Date
    public let tenMinutes: Double?
    public let fifteenMinutes: Double?
    public let reportedPrecipitation: Double?
    public let sourceTimestampText: String?
    public let sourceTimeZoneNote: String?
    public let oneHour: Double?
    public let threeHours: Double?
    public let twentyFourHours: Double?
    public let timestampKind: TimestampKind
    public var id: String { "\(stationID)-\(timestamp.timeIntervalSince1970)" }
    public init(stationID: String, timestamp: Date, fetchedAt: Date,
                tenMinutes: Double?, oneHour: Double? = nil,
                threeHours: Double? = nil, twentyFourHours: Double? = nil,
                timestampKind: TimestampKind = .observation, fifteenMinutes: Double? = nil,
                reportedPrecipitation: Double? = nil, sourceTimestampText: String? = nil,
                sourceTimeZoneNote: String? = nil) {
        self.stationID = stationID; self.timestamp = timestamp; self.fetchedAt = fetchedAt
        self.tenMinutes = tenMinutes; self.oneHour = oneHour; self.threeHours = threeHours
        self.twentyFourHours = twentyFourHours; self.timestampKind = timestampKind
        self.fifteenMinutes = fifteenMinutes; self.reportedPrecipitation = reportedPrecipitation
        self.sourceTimestampText = sourceTimestampText; self.sourceTimeZoneNote = sourceTimeZoneNote
    }
    public func isFresh(at now: Date, maxAge: TimeInterval = 20 * 60) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= -60 && age <= maxAge
    }
}

public struct RadarFrame: Codable, Identifiable, Equatable, Sendable {
    public let basetime: String
    public let validtime: String
    public let elements: [String]
    public var id: String { "\(basetime)-\(validtime)" }
    public var date: Date? { RainClock.parseCompact(validtime, utc: true) }
    public var isAnalysis: Bool { basetime == validtime && elements.contains("hrpns") }
    public init(basetime: String, validtime: String, elements: [String]) {
        self.basetime = basetime; self.validtime = validtime; self.elements = elements
    }
    public var tileTemplate: String {
        "https://www.jma.go.jp/bosai/jmatile/data/nowc/\(basetime)/none/\(validtime)/surf/hrpns/{z}/{x}/{y}.png"
    }
}

public enum RainClock {
    public static let japan = TimeZone(secondsFromGMT: 9 * 3600)!
    public static func formatter(_ format: String, utc: Bool = false) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = utc ? TimeZone(secondsFromGMT: 0)! : japan
        f.dateFormat = format
        f.isLenient = false
        return f
    }
    public static func parseCompact(_ value: String, utc: Bool = false) -> Date? {
        guard value.count == 14, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return formatter("yyyyMMddHHmmss", utc: utc).date(from: value)
    }
    public static func compact(_ date: Date, utc: Bool = false) -> String {
        formatter("yyyyMMddHHmmss", utc: utc).string(from: date)
    }
    public static func time(_ date: Date) -> String { formatter("HH:mm").string(from: date) }
    public static func full(_ date: Date) -> String { formatter("MM/dd HH:mm").string(from: date) + " JST" }
}

public enum RainError: LocalizedError {
    case invalidResponse(String)
    case invalidData(String)
    public var errorDescription: String? {
        switch self { case .invalidResponse(let s), .invalidData(let s): return s }
    }
}
