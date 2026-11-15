/*
MIT License

Copyright (c) 2026 Ito Rain contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

This license applies only to this project's original source code and
synthetic test fixtures. Third-party map tiles, observations, and government
content remain subject to their original terms. No source weather dataset
or government map imagery is included in this distribution.
*/

import SwiftUI
import AppKit
import UserNotifications
#if SWIFT_PACKAGE
import RainCore
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
@MainActor
struct OtsukaresamaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = RainStore()
    var body: some Scene {
        Window("おつかれさま", id: "dashboard") {
            DashboardView().environmentObject(store).environment(\.locale, Locale(identifier: "ja_JP"))
        }
        .defaultSize(width: 1190, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("観測データを更新") { Task { await store.refresh(force: true) } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        MenuBarExtra {
            MenuPanel().environmentObject(store).environment(\.locale, Locale(identifier: "ja_JP"))
        } label: {
            Label(store.menuTitle, systemImage: store.assessment.symbol)
        }
        .menuBarExtraStyle(.window)
        Settings {
            RainSettingsView().environmentObject(store).environment(\.locale, Locale(identifier: "ja_JP"))
        }
    }
}
