import SwiftUI
#if SWIFT_PACKAGE
import RainCore
#endif

@MainActor
struct RainSettingsView: View {
    @EnvironmentObject var store: RainStore
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var coordinateMessage = ""
    var body: some View {
        Form {
            Section("キャンパス") { CampusPicker() }
            Section("研究室の位置") {
                Text("初期位置は選択した大学の目安です。建物の緯度・経度を入力すると研究室の位置を変更できます。位置情報の権限は要求しません。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("緯度", text: $latitude)
                TextField("経度", text: $longitude)
                HStack {
                    Button("研究室の位置を保存") {
                        guard let lat = Double(latitude), let lon = Double(longitude), store.setLab(latitude: lat, longitude: lon) else {
                            coordinateMessage = "選択した大学周辺の有効な緯度・経度を入力してください。"
                            return
                        }
                        coordinateMessage = "このMacに保存しました。"
                    }
                    Text(coordinateMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("データと表示") {
                if store.campus == .ito {
                Picker("国土地理院の地図", selection: $store.baseMapStyle) {
                    ForEach(BaseMapStyle.allCases) { style in Text(style.label).tag(style) }
                }
                Toggle("福岡市の雨量観測データを取得", isOn: $store.cityEnabled)
                Text("福岡市の公開HTMLから観測値を読み取ります。正式な開発者向けAPIではありません。再配布や一般公開の前に利用条件を確認してください。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("福岡市の利用条件", destination: URL(string: "https://bousai.city.fukuoka.lg.jp/site.html")!)
                Link("気象庁の利用条件", destination: URL(string: "https://www.jma.go.jp/jma/kishou/info/coment.html")!)
                Link("地理院タイルの一覧と出典表記", destination: URL(string: "https://maps.gsi.go.jp/development/ichiran.html")!)
                } else {
                    Text(store.campus.dataNotice).font(.caption)
                    Link("観測データの公式サイト", destination: store.campus.sourceURL)
                    Link(store.campus.mapAttribution, destination: store.campus.mapSourceURL)
                    Text("公開HTMLの読み取りです。機器への直接接続や互換性が保証されたAPIではありません。").font(.caption)
                }
            }
            Section("観測データの見方と制限") {
                Text("取得間隔: 伊都10分、Waterloo 15分、Wyoming 30分。手動更新は30秒以上。観測時刻が伊都20分、Waterloo 35分、Wyoming 90分を過ぎると古いデータとして表示します。配信元の更新頻度を保証するものではありません。")
                Text("0 mmは雨が止んだことの証明ではありません。雨雲レイヤーは降水解析で、雲の写真や地上の直接観測ではありません。雨の到着時刻や止む時刻は予測しません。")
                Text(store.campus.watchDescription + "。地域切替時は通知を解除します。Macのスリープ中やアプリ終了後は監視できません。")
                Text("観測履歴と設定はこのMacに保存します。配信元にはIPアドレスを含む通常の通信情報が届きます。MapKitはAppleと通信する場合があります。アクセス解析SDKは使用しません。")
            }.font(.caption)
            Section("診断") {
                Button("診断情報をコピー") { store.copyDiagnostics() }
                Text("通信先を検査するには、プロジェクトのフォルダで `swift run RainProbe` を実行してください。取得・解析に失敗しても架空の雨量で補いません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 720)
        .onChange(of: store.campus) { _, _ in
            latitude = String(format: "%.5f", store.lab.latitude)
            longitude = String(format: "%.5f", store.lab.longitude)
            coordinateMessage = ""
        }
        .onAppear {
            latitude = String(format: "%.5f", store.lab.latitude)
            longitude = String(format: "%.5f", store.lab.longitude)
        }
    }
}
