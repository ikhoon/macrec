import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// User-notification helpers (permission + posting) for transcript / summary outcomes.
enum Notifier {
    static func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            elog("notify: authorization granted=\(granted)\(err.map { " error=\($0)" } ?? "")")
        }
    }
    /// QA seam: when set, `push` routes here instead of UNUserNotificationCenter — both the notification
    /// COUNTER for scenarios (the digest once pushed 453 failure notifications in one afternoon) and a
    /// crash guard: outside a bundled .app, UNUserNotificationCenter.current() has no bundle proxy and raises.
    nonisolated(unsafe) static var sinkForTest: ((String, String) -> Void)?

    /// filePath rides in userInfo; clicking the notification opens it (AppController is the delegate).
    static func push(title: String, body: String, filePath: String? = nil, openURL: URL? = nil) {
        if let sink = sinkForTest { sink(title, body); return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        var info: [String: String] = [:]
        if let filePath { info["file"] = filePath }               // a local path — opened as a file on click
        if let openURL { info["url"] = openURL.absoluteString }   // a web link — kept DISTINCT so a URL is never opened as a path
        if !info.isEmpty { c.userInfo = info }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        ) { err in if let err { elog("notify: add failed: \(err)") } }
    }
}
