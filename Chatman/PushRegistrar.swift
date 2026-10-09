import SwiftUI
import UserNotifications
import ChatmanKit

/// Notifications, as far as they can be taken here.
///
/// The whole chain is built: ask the person, ask Apple for a token, hand that token to your
/// own homeserver, and let the server wake the app when something arrives. Two links of it
/// aren't ours to supply — a push certificate, which needs a paid Apple developer account,
/// and a gateway on your server to hand messages to Apple.
///
/// So this runs the chain and reports honestly where it stops. On a free account Apple
/// refuses at the token step with a plain message, which lands in Settings as "Not available
/// in this build" instead of a switch that silently does nothing. The day the certificate
/// exists, nothing here needs changing.
final class PushRegistrar: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by the app so the delegate can reach the session.
    @MainActor static var session: ChatSession?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Asks for permission and, if given, for a token.
    @MainActor
    static func enable() async {
        guard let session else { return }

        let centre = UNUserNotificationCenter.current()

        let granted = (try? await centre.requestAuthorization(options: [.alert, .sound, .badge]))
            ?? false

        guard granted else {
            session.notePushRefused()
            return
        }

        session.notePushRegistering()
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken token: Data
    ) {
        Task { @MainActor in
            await Self.session?.registerForPush(
                token: token,
                appID: (Bundle.main.bundleIdentifier ?? "com.example.Chatman") + ".ios",
                deviceName: UIDevice.current.name
            )
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        // What a free developer account gets: "no valid aps-environment entitlement". Said
        // in the app's own words rather than left as silence.
        Task { @MainActor in
            Self.session?.notePushFailure(
                "Apple wouldn't issue a token: \(error.localizedDescription) A push certificate needs a paid developer account."
            )
        }
    }

    /// Notifications that arrive while you're looking at the app.
    ///
    /// Shown as a banner only when you're somewhere else in the app — a notification for the
    /// conversation already on screen is telling you what you can see.
    func userNotificationCenter(
        _ centre: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
