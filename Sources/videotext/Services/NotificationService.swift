import Foundation
import AppKit
import UserNotifications

struct NotificationPayload: Equatable {
    var title: String
    var body: String
    var projectPath: String

    static func success(mediaName: String, elapsed: TimeInterval, projectURL: URL) -> NotificationPayload {
        NotificationPayload(
            title: "videotext: обработка завершена",
            body: "\(mediaName) готово за \(TimeTextFormatter.string(elapsed)).",
            projectPath: projectURL.path
        )
    }

    static func failure(message: String, projectURL: URL?) -> NotificationPayload {
        NotificationPayload(
            title: "videotext: ошибка обработки",
            body: message,
            projectPath: projectURL?.path ?? ""
        )
    }
}

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    @discardableResult
    func notifySuccess(mediaName: String, elapsed: TimeInterval, projectURL: URL) async -> Bool {
        await deliver(.success(mediaName: mediaName, elapsed: elapsed, projectURL: projectURL))
    }

    @discardableResult
    func notifyFailure(message: String, projectURL: URL?) async -> Bool {
        await deliver(.failure(message: message, projectURL: projectURL))
    }

    func authorizationStatusText() async -> String {
        let status = await notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private func deliver(_ payload: NotificationPayload) async -> Bool {
        let settings = await notificationSettings()
        var authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if settings.authorizationStatus == .notDetermined {
            authorized = await requestAuthorization()
        }
        guard authorized else {
            await MainActor.run { NSSound.beep() }
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.userInfo = ["projectPath": payload.projectPath]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            await MainActor.run { NSSound.beep() }
            return false
        }
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let projectPath = response.notification.request.content.userInfo["projectPath"] as? String
        DispatchQueue.main.async {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            if let projectPath, !projectPath.isEmpty {
                NSWorkspace.shared.open(URL(fileURLWithPath: projectPath, isDirectory: true))
            }
            completionHandler()
        }
    }
}
