import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GovernmentClient: Sendable {
    public init() {}
    public func response(_ url: URL) async throws -> SourcePayload {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Otsukaresama/0.4.1 personal-observation-client", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RainError.invalidResponse("HTTP応答ではありません。") }
        guard data.count <= 8_000_000 else { throw RainError.invalidResponse("応答が8 MBを超えました。") }
        let headers = Dictionary(http.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }, uniquingKeysWith: { _, new in new })
        return SourcePayload(requestURL: url, responseURL: http.url, statusCode: http.statusCode, headers: headers, body: data)
    }
    public func get(_ url: URL) async throws -> Data {
        let payload = try await response(url)
        try payload.validate()
        return payload.body
    }
    public func fukuokaSnapshot() async throws -> SourceSnapshot {
        .fukuoka(try await response(URL(string: "https://bousai.city.fukuoka.lg.jp/")!))
    }
    public func maebaruSnapshot() async throws -> SourceSnapshot {
        var responses: [SourcePayload] = []
        do {
            let clock = try await response(URL(string: "https://www.jma.go.jp/bosai/amedas/data/latest_time.txt")!)
            responses.append(clock)
            try clock.validate()
            guard let raw = clock.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let stamp = ISO8601DateFormatter().date(from: raw) else {
                throw RainError.invalidData("AMeDASの最新時刻を解析できません。")
            }
            // AMeDAS map filenames use JST; radar filenames use UTC.
            let map = try await response(URL(string: "https://www.jma.go.jp/bosai/amedas/data/map/\(RainClock.compact(stamp)).json")!)
            responses.append(map)
            return .amedas(responses, timestamp: stamp)
        } catch {
            if responses.isEmpty { throw error }
            return SourceSnapshot(provider: .jma, responses: responses, parseIssue: error.localizedDescription)
        }
    }
    // Compatibility helpers used by the command-line probe.
    public func fukuoka() async throws -> [RainObservation] {
        let snapshot = try await fukuokaSnapshot()
        if let issue = snapshot.parseIssue { throw RainError.invalidData(issue) }
        return snapshot.observations
    }
    public func maebaru() async throws -> RainObservation {
        let snapshot = try await maebaruSnapshot()
        guard let observation = snapshot.observations.first, snapshot.parseIssue == nil else {
            throw RainError.invalidData(snapshot.parseIssue ?? "観測値がありません。")
        }
        return observation
    }
    public func radar() async throws -> [RadarFrame] {
        let data = try await get(URL(string: "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N1.json")!)
        return try JMAParser.radar(data)
    }
}
