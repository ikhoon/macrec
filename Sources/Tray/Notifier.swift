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
    /// filePath rides in userInfo; clicking the notification opens it (AppController is the delegate).
    static func push(title: String, body: String, filePath: String? = nil, openURL: URL? = nil) {
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
