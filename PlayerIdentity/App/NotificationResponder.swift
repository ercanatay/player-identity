import AppKit
@preconcurrency import UserNotifications

/// §66.2 answers to notifications: "Copy Unban Message" copies the message; a tap brings the app forward and opens
/// the server details (nothing is copied). Foreground presentation is unchanged (no `willPresent`).
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Registers the action category and becomes the notification center's delegate (live app only).
    @MainActor
    func install() {
        let center = UNUserNotificationCenter.current()
        let copy = UNNotificationAction(identifier: NotificationActions.copyAction, title: L10n.text(.fixCopyAppeal),
                                        options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: NotificationActions.copyCategory, actions: [copy], intentIdentifiers: [],
                                   options: []),
        ])
        center.delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let route = NotificationActions.route(actionIdentifier: response.actionIdentifier,
                                              userInfo: response.notification.request.content.userInfo)
        let model = model
        await MainActor.run {
            if model.handleNotificationRoute(route), case .openServer = route {
                NSApp.activate()
                NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
            }
        }
    }
}
