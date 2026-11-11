import Foundation
import TicketPilotCore
import UserNotifications

/// What a click on a notification asks the app to do.
enum NotificationAction: Sendable {
    case startTicket(key: String)
    case openInJira(key: String)
    case openSession(runID: String)
}

/// Posts the app's notifications: one per new ticket, one per run that needs the user.
/// Only usable from a `.app` bundle: `UNUserNotificationCenter` fails without one.
struct Notifier {
    private enum ID {
        static let ticketCategory = "ticket"
        static let runCategory = "run"
        static let start = "start"
        static let openInJira = "open-in-jira"
        static let openSession = "open-session"
        static let key = "key"
        static let runID = "runID"
    }

    private let center = UNUserNotificationCenter.current()
    private let delegate: Delegate

    init(onAction: @escaping @MainActor @Sendable (NotificationAction) -> Void) {
        delegate = Delegate(onAction: onAction)
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: ID.ticketCategory,
                actions: [
                    UNNotificationAction(identifier: ID.start, title: "Start", options: [.foreground]),
                    UNNotificationAction(identifier: ID.openInJira, title: "Open in Jira", options: [.foreground]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: ID.runCategory,
                actions: [
                    UNNotificationAction(identifier: ID.openSession, title: "Open session", options: [.foreground]),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyNewTicket(_ issue: JiraIssue) {
        let content = UNMutableNotificationContent()
        content.title = "\(issue.key) assigned to you"
        content.body = issue.summary
        content.categoryIdentifier = ID.ticketCategory
        content.userInfo = [ID.key: issue.key]
        post(content, identifier: issue.key)
    }

    /// `identifier` is `NeedsYouEvent.notificationID(in:)`: one notification per wait.
    func notify(_ event: NeedsYouEvent, identifier: String) {
        let text = NotificationText.make(event)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.categoryIdentifier = ID.runCategory
        content.userInfo = [ID.runID: event.runID]
        post(content, identifier: identifier)
    }

    private func post(_ content: UNNotificationContent, identifier: String) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
        private let onAction: @MainActor @Sendable (NotificationAction) -> Void

        init(onAction: @escaping @MainActor @Sendable (NotificationAction) -> Void) {
            self.onAction = onAction
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let info = response.notification.request.content.userInfo
            let identifier = response.actionIdentifier
            let clicked = identifier == UNNotificationDefaultActionIdentifier
            var action: NotificationAction?
            if let key = info[ID.key] as? String {
                // A click on the notification itself starts the ticket, like the Start action.
                if identifier == ID.start || clicked {
                    action = .startTicket(key: key)
                } else if identifier == ID.openInJira {
                    action = .openInJira(key: key)
                }
            } else if let runID = info[ID.runID] as? String, identifier == ID.openSession || clicked {
                action = .openSession(runID: runID)
            }
            if let action {
                let onAction = onAction
                Task { @MainActor in onAction(action) }
            }
            completionHandler()
        }
    }
}
