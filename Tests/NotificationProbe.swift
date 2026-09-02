import Foundation
import Darwin

@main
struct NotificationProbe {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("Использование: notification-probe <папка-проекта>\n", stderr)
            exit(2)
        }

        let service = NotificationService()
        let before = await service.authorizationStatusText()
        let granted = await service.requestAuthorization()
        let projectURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let success = await service.notifySuccess(mediaName: "Контрольное видео.mp4", elapsed: 5, projectURL: projectURL)
        let failure = await service.notifyFailure(message: "Контрольная ошибка уведомления", projectURL: projectURL)
        let after = await service.authorizationStatusText()
        print("NOTIFICATION_STATUS_BEFORE=\(before)")
        print("NOTIFICATION_GRANTED=\(granted)")
        print("NOTIFICATION_SUCCESS_SCHEDULED=\(success)")
        print("NOTIFICATION_FAILURE_SCHEDULED=\(failure)")
        print("NOTIFICATION_STATUS_AFTER=\(after)")
        exit(success && failure ? 0 : 3)
    }
}
