import Foundation

// Deliberately small, fail-closed HTML adapter, not a general-purpose HTML parser.
// Numeric cells must match completely. Missing/unknown text never becomes zero.
public struct ParsedFukuokaRow: Sendable {
    public let observation: RainObservation
    public let html: String
}

public enum FukuokaParser {
    static func matches(_ pattern: String, _ input: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
    }
    static func capture(_ m: NSTextCheckingResult, _ group: Int, _ text: String) -> String {
        guard let range = Range(m.range(at: group), in: text) else { return "" }
        return String(text[range])
    }
    public static func plainText(_ input: String) -> String {
        var s = input.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&#160;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&#65306;": ":", "　": " ", " ": " "]
        for (entity, value) in entities { s = s.replacingOccurrences(of: entity, with: value) }
        // Numeric character references occur in some HTML exporters.
        for m in matches("&#(x[0-9a-f]+|[0-9]+);", s).reversed() {
            let code = capture(m, 1, s)
            let n = code.lowercased().hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            if let n, let scalar = UnicodeScalar(n), let r = Range(m.range, in: s) { s.replaceSubrange(r, with: String(scalar)) }
        }
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func rainValue(_ text: String) -> Double? {
        let s = plainText(text).replacingOccurrences(of: " ", with: "")
        guard let m = matches("^([0-9]+(?:\\.[0-9]+)?)(?:mm)?$", s).first,
              let value = Double(capture(m, 1, s)), value.isFinite, value >= 0 else { return nil }
        return value
    }
    static func snapshotDate(_ prefix: String) -> Date? {
        let text = plainText(prefix)
        let pattern = "雨量\\s*観測時刻\\s*[:：]?\\s*([0-9]{4})\\s*年\\s*([0-9]{1,2})\\s*月\\s*([0-9]{1,2})\\s*日\\s*([0-9]{1,2})\\s*[:時]\\s*([0-9]{1,2})"
        guard let m = matches(pattern, text).last else { return nil }
        let parts = (1...5).compactMap { Int(capture(m, $0, text)) }
        guard parts.count == 5 else { return nil }
        let value = String(format: "%04d%02d%02d%02d%02d00", parts[0], parts[1], parts[2], parts[3], parts[4])
        return RainClock.parseCompact(value)
    }
    public static func parse(html: String, fetchedAt: Date = Date()) throws -> [RainObservation] {
        try parseRows(html: html, fetchedAt: fetchedAt).map(\.observation)
    }
    public static func parseRows(html: String, fetchedAt: Date = Date()) throws -> [ParsedFukuokaRow] {
        // Make sure this is still the rain table, with its original field meanings.
        let text = plainText(html).replacingOccurrences(of: " ", with: "")
        guard text.contains("前10分"), text.contains("前1時間"),
              text.contains("前3時間"), text.contains("前24時間") else {
            throw RainError.invalidData("福岡市の雨量表の見出しが想定と異なります。値の推測は行いません。")
        }
        var readings: [String: ParsedFukuokaRow] = [:]
        let expectedHeaders = ["前10分", "前1時間", "前3時間", "前24時間"]
        var headerOrderIsValid = false
        for row in matches("<tr\\b[^>]*>(.*?)</tr\\s*>", html) {
            let raw = capture(row, 1, html)
            let cells = matches("<t[dh]\\b[^>]*>(.*?)</t[dh]\\s*>", raw).map { capture($0, 1, raw) }
            let labels = cells.map { plainText($0).replacingOccurrences(of: " ", with: "") }
            if labels.contains(where: { expectedHeaders.contains($0) }) {
                headerOrderIsValid = labels.count >= 5 && Array(labels.suffix(4)) == expectedHeaders
                continue
            }
            guard headerOrderIsValid,
                  let station = Stations.city.first(where: { raw.contains($0.pageFile!) }) else { continue }
            guard let index = cells.firstIndex(where: { $0.contains(station.pageFile!) }), cells.count >= index + 5,
                  let range = Range(row.range, in: html),
                  let date = snapshotDate(String(html[..<range.lowerBound])) else {
                continue
            }
            let values = (1...4).map { rainValue(cells[index + $0]) }
            let observation = RainObservation(stationID: station.id, timestamp: date, fetchedAt: fetchedAt,
                tenMinutes: values[0], oneHour: values[1], threeHours: values[2], twentyFourHours: values[3], timestampKind: .pageSnapshot)
            readings[station.id] = ParsedFukuokaRow(observation: observation, html: String(html[range]))
        }
        guard !readings.isEmpty else { throw RainError.invalidData("福岡市のHTMLから観測所や時刻を読み取れませんでした。受信原文を確認してください。") }
        return Stations.city.compactMap { readings[$0.id] }
    }
}

public enum JMAParser {
    // Reject null, sentinel and non-normal quality values instead of manufacturing dry weather.
    public static func normalValue(_ value: Any?) -> Double? {
        guard let pair = value as? [Any], pair.count >= 2,
              let number = pair[0] as? NSNumber, let quality = pair[1] as? NSNumber,
              quality.doubleValue == 0, number.doubleValue >= 0, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    public static func map(_ data: Data, timestamp: Date, fetchedAt: Date = Date()) throws -> RainObservation {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = root[Stations.maebaru.id] as? [String: Any] else {
            throw RainError.invalidData("アメダスの応答に前原（82171）がありません。")
        }
        guard s.keys.contains("precipitation10m") else {
            throw RainError.invalidData("アメダスの応答に precipitation10m がありません。")
        }
        return RainObservation(stationID: Stations.maebaru.id, timestamp: timestamp, fetchedAt: fetchedAt,
            tenMinutes: normalValue(s["precipitation10m"]), oneHour: normalValue(s["precipitation1h"]),
            threeHours: normalValue(s["precipitation3h"]), twentyFourHours: normalValue(s["precipitation24h"]))
    }
    public static func radar(_ data: Data) throws -> [RadarFrame] {
        let decoded = try JSONDecoder().decode([RadarFrame].self, from: data)
        let frames = decoded.filter { $0.isAnalysis && $0.date != nil }.sorted { $0.validtime < $1.validtime }
        guard !frames.isEmpty else { throw RainError.invalidData("実況の降水解析がありません。予報データは表示対象外です。") }
        // Last 90 minutes (19 frames), no future frames and no invented timestamps.
        return Array(frames.suffix(19))
    }
}
