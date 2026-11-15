import Foundation
import RainCore

@main
struct RainProbe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") {
            print("RainProbe [--campus ito|waterloo|wyoming|all] [--output directory]")
            return
        }
        func option(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let choice = option("--campus") ?? "ito"
        guard choice == "all" || Campus(rawValue: choice) != nil else {
            print("未対応のキャンパス: \(choice)"); exit(2)
        }
        let campuses = choice == "all" ? Campus.allCases : [Campus(rawValue: choice)!]
        let output = option("--output").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output {
            do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            catch { print(error.localizedDescription); exit(2) }
        }
        let client = GovernmentClient()
        var failures = 0
        print("おつかれさま / 実データ取得の診断（模擬データなし）")
        for campus in campuses {
            print("\n=== \(campus.label) / \(RainClock.local(Date(), campus: campus)) ===")
            for provider in campus.providers {
                do {
                    let snapshot = try await client.campusSnapshot(provider)
                    for response in snapshot.responses {
                        print("HTTP \(response.statusCode) / \(response.body.count) bytes / \(response.responseURL)")
                        if let output {
                            let filename = response.suggestedFilename
                            try response.body.write(to: output.appendingPathComponent(filename), options: .atomic)
                            let metadata: [String: Any] = ["requestURL": response.requestURL.absoluteString,
                                "responseURL": response.responseURL.absoluteString, "status": response.statusCode,
                                "receivedAt": ISO8601DateFormatter().string(from: response.receivedAt),
                                "headers": response.headers]
                            let bytes = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                            try bytes.write(to: output.appendingPathComponent(filename + ".metadata.json"), options: .atomic)
                        }
                    }
                    if let issue = snapshot.parseIssue { throw RainError.invalidData(issue) }
                    for station in campus.stations where station.provider == provider {
                        guard let record = snapshot.observations.filter({ $0.stationID == station.id }).max(by: { $0.timestamp < $1.timestamp }) else {
                            failures += 1; print("\(station.localName): 観測がありません"); continue
                        }
                        let fresh = record.isFresh(at: Date(), maxAge: station.freshnessLimit)
                        let value = record.displayValue.map { String(format: "%.2f", $0) } ?? "欠測"
                        print("\(station.localName): \(value) mm / \(record.intervalLabel) / \(RainClock.local(record.timestamp, campus: campus)) / fresh=\(fresh)")
                        print("座標: \(station.publishedPosition?.coordinateText ?? "未確認")")
                        if !fresh || record.displayValue == nil { failures += 1 }
                    }
                } catch { failures += 1; print("\(provider.label): \(error.localizedDescription)") }
            }
            // One representative basemap tile per layer, never a bulk download.
            let templates = campus.overseasBaseTemplate.map { [$0] + [campus.labelsTemplate].compactMap { $0 } }
                ?? ["https://cyberjapandata.gsi.go.jp/xyz/pale/{z}/{x}/{y}.png"]
            for template in templates {
                do {
                    let z = 12, scale = pow(2.0, Double(z))
                    let lat = campus.center.latitude * .pi / 180
                    let x = Int(floor((campus.center.longitude + 180) / 360 * scale))
                    let y = Int(floor((1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * scale))
                    let url = URL(string: template.replacingOccurrences(of: "{z}", with: String(z)).replacingOccurrences(of: "{x}", with: String(x)).replacingOccurrences(of: "{y}", with: String(y)))!
                    let data = try await client.get(url)
                    let png = data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
                    let jpeg = data.starts(with: [255, 216, 255])
                    guard png || jpeg else { throw RainError.invalidData("地図タイルがPNG/JPEGではありません") }
                    print("地図タイル: \(data.count) bytes / \(url.host ?? "")")
                } catch { failures += 1; print("地図: \(error.localizedDescription)") }
            }
            if campus.supportsRadar {
                do {
                    let frames = try await client.radar()
                    guard let latest = frames.last else { throw RainError.invalidData("雨雲の時刻がありません") }
                    let tile = latest.tileTemplate.replacingOccurrences(of: "{z}", with: "10").replacingOccurrences(of: "{x}", with: "882").replacingOccurrences(of: "{y}", with: "410")
                    let data = try await client.get(URL(string: tile)!)
                    guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw RainError.invalidData("雨雲がPNGではありません") }
                    print("JMA: \(frames.count) frames / \(latest.validtime) UTC / \(data.count) bytes")
                } catch { failures += 1; print("JMA: \(error.localizedDescription)") }
            }
        }
        print("\n取得・解析・新鮮さの問題: \(failures)")
        if failures > 0 { exit(1) }
    }
}
