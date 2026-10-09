import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity

/// Hands the signed-in session from the phone to the watch.
///
/// The watch can't sign in on its own — typing a server address and password on that screen is
/// miserable, and asking for it would be asking twice for the same thing. But the two devices
/// don't share a keychain either: an access group shares between apps on one device, never
/// across a pairing. So the phone has to send it.
///
/// Application context is the right channel for this rather than a message: watchOS keeps the
/// most recent one and delivers it whenever the watch app next runs, even if it was asleep or
/// out of range when the phone signed in. Only the latest value survives, which is exactly
/// right for something that only ever has one current value.
public final class SessionLink: NSObject, WCSessionDelegate, @unchecked Sendable {

    public static let shared = SessionLink()

    /// Called on the watch when the phone sends a session, and when it signs out.
    private var onChange: (@MainActor @Sendable (Credentials?) -> Void)?

    /// Called with a short description whenever the link's situation changes.
    ///
    /// Worth surfacing rather than logging: when the watch shows nothing, the difference
    /// between "your phone hasn't signed in", "the watch app isn't installed on the paired
    /// watch" and "this pairing is unreachable" is the whole diagnosis.
    private var onStatus: (@MainActor @Sendable (String) -> Void)?

    /// Called on the watch with the names the phone resolved from its address book.
    private var onNames: (@MainActor @Sendable ([String: String]) -> Void)?

    /// Called on the watch with names for the people who speak in groups.
    private var onSenderNames: (@MainActor @Sendable ([String: String]) -> Void)?

    /// Called on the watch with the pictures that go with those names.
    ///
    /// Sent as well as the names because the watch can't read an address book at all: the
    /// framework isn't there. Everything it knows about who somebody is comes from here.
    private var onPhotos: (@MainActor @Sendable ([String: Data]) -> Void)?

    /// Called on the watch when a setting changed on the phone.
    ///
    /// Settings live on the phone because that's where there's room to explain them, but the
    /// watch syncs on its own and would otherwise keep showing what the phone has hidden.
    private var onPreferences: (@MainActor @Sendable (Bool) -> Void)?

    /// What the phone last offered, kept so a late activation still gets sent.
    private var pending: Credentials?

    /// Names resolved from the phone's address book, passed on so the watch shows the same
    /// ones. The watch can't read those contacts itself.
    private var pendingNames: [String: String] = SessionLink.remembered("contactNames") {
        didSet { SessionLink.remember(pendingNames, as: "contactNames") }
    }

    /// The same, as small pictures. Kept tiny on purpose; see ``sharePhotos(_:)``.
    private var pendingPhotos: [String: Data] = [:]

    /// Names for the people in groups, keyed by their bridged account.
    private var pendingSenderNames: [String: String] = SessionLink.remembered("senderNames") {
        didSet { SessionLink.remember(pendingSenderNames, as: "senderNames") }
    }

    /// The settings the watch should copy. Sent with everything else, since only the most
    /// recent context survives and a partial one would undo the rest.
    private var pendingHidesStatusUpdates = true

    private override init() { super.init() }

    /// What was last handed to the watch, kept between launches of the phone app.
    ///
    /// The names are worked out from the address book a moment after launch, and the session
    /// goes to the watch before that. Without these, that first delivery carried no names at
    /// all and wiped the watch's — which is how "bdbkyra" came back after the watch app was
    /// installed again: the phone told it the session, and nobody's names.
    private static func remembered(_ key: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "chatman.link." + key) as? [String: String] ?? [:]
    }

    private static func remember(_ names: [String: String], as key: String) {
        UserDefaults.standard.set(names, forKey: "chatman.link." + key)
    }

    /// Starts listening. Safe to call more than once.
    ///
    /// - Parameter onChange: Only used on the watch; the phone never receives a session.
    public func start(
        onChange: (@MainActor @Sendable (Credentials?) -> Void)? = nil,
        onStatus: (@MainActor @Sendable (String) -> Void)? = nil,
        onNames: (@MainActor @Sendable ([String: String]) -> Void)? = nil,
        onPreferences: (@MainActor @Sendable (Bool) -> Void)? = nil,
        onPhotos: (@MainActor @Sendable ([String: Data]) -> Void)? = nil,
        onSenderNames: (@MainActor @Sendable ([String: String]) -> Void)? = nil
    ) {
        if let onChange { self.onChange = onChange }
        if let onStatus { self.onStatus = onStatus }
        if let onNames { self.onNames = onNames }
        if let onPreferences { self.onPreferences = onPreferences }
        if let onPhotos { self.onPhotos = onPhotos }
        if let onSenderNames { self.onSenderNames = onSenderNames }

        guard WCSession.isSupported() else {
            report(String(localized: "This device can't talk to a watch.", bundle: .module))
            return
        }

        let session = WCSession.default
        guard session.delegate !== self || session.activationState != .activated else { return }

        session.delegate = self
        session.activate()
    }

    /// Offers the current session to the watch. Called on the phone.
    ///
    /// Passing `nil` tells the watch the account is gone, so it stops syncing against a token
    /// that no longer works rather than retrying a dead session on a battery.
    public func share(_ credentials: Credentials?) {
        pending = credentials

        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        guard session.activationState == .activated else {
            start()
            return
        }

        send(credentials, over: session)
    }

    private func send(_ credentials: Credentials?, over session: WCSession) {
        #if os(iOS)
        guard session.isPaired else {
            report(String(localized: "No watch is paired with this iPhone.", bundle: .module))
            return
        }
        guard session.isWatchAppInstalled else {
            report(String(localized: "Chatman isn't installed on the watch yet.", bundle: .module))
            return
        }
        #endif

        do {
            try session.updateApplicationContext(payload(for: credentials))
            report(credentials == nil ? "Told the watch you signed out." : "Session sent to the watch.")
        } catch {
            // Whatever went wrong, the session itself has to get through: without it the
            // watch has no account at all. Try again with nothing but the essentials.
            pendingPhotos = [:]

            do {
                try session.updateApplicationContext(payload(for: credentials))
                report(String(localized: "Session sent to the watch, without contact pictures.", bundle: .module))
            } catch {
                report(error.localizedDescription)
            }
        }
    }

    private func report(_ message: String) {
        let handler = onStatus
        Task { @MainActor in handler?(message) }
    }

    // MARK: - Encoding

    private func payload(for credentials: Credentials?) -> [String: Any] {
        guard let credentials else { return ["signedIn": false] }

        return [
            "signedIn": true,
            "userID": credentials.userID,
            "deviceID": credentials.deviceID,
            "accessToken": credentials.accessToken,
            "homeserver": credentials.homeserver.url.absoluteString,
            "contactNames": pendingNames,
            "contactPhotos": pendingPhotos,
            "senderNames": pendingSenderNames,
            "hidesStatusUpdates": pendingHidesStatusUpdates,
            // Different every time, so every send is delivered. WatchConnectivity passes on
            // an application context only when it differs from the last one — and a watch
            // app that was deleted and installed again never saw that last one.
            "sentAt": Date.now.timeIntervalSince1970
        ]
    }

    /// Passes the names of the people who speak in groups.
    public func shareSenderNames(_ names: [String: String]) {
        guard pendingSenderNames != names else { return }
        pendingSenderNames = names
        share(pending)
    }

    /// Passes the pictures from the phone's address book to the watch.
    ///
    /// An application context is capped at a few hundred kilobytes for *everything* it
    /// carries, and going over doesn't drop the pictures — it throws the whole payload away,
    /// access token and all, and the watch quietly stops working. So this keeps a budget and
    /// sends what fits: faces are a nicety, the session is not.
    public func sharePhotos(_ photos: [String: Data]) {
        var budget = 120_000
        var fitting: [String: Data] = [:]

        // Smallest first, so a couple of large ones can't crowd out a dozen small ones.
        for (room, data) in photos.sorted(by: { $0.value.count < $1.value.count }) {
            guard data.count <= budget else { break }
            fitting[room] = data
            budget -= data.count
        }

        guard pendingPhotos != fitting else { return }
        pendingPhotos = fitting
        share(pending)
    }

    /// Passes a setting the watch should follow too.
    public func sharePreferences(hidesStatusUpdates: Bool) {
        guard pendingHidesStatusUpdates != hidesStatusUpdates else { return }
        pendingHidesStatusUpdates = hidesStatusUpdates
        share(pending)
    }

    /// Passes the phone's address-book names to the watch.
    public func shareContactNames(_ names: [String: String]) {
        guard pendingNames != names else { return }
        pendingNames = names
        share(pending)
    }

    private static func credentials(from context: [String: Any]) -> Credentials? {
        guard context["signedIn"] as? Bool == true,
              let userID = context["userID"] as? String,
              let deviceID = context["deviceID"] as? String,
              let accessToken = context["accessToken"] as? String,
              let address = context["homeserver"] as? String,
              let homeserver = Homeserver(string: address)
        else { return nil }

        return Credentials(
            userID: userID, deviceID: deviceID,
            accessToken: accessToken, homeserver: homeserver
        )
    }

    private func deliver(_ context: [String: Any]) {
        let credentials = Self.credentials(from: context)
        let names = context["contactNames"] as? [String: String] ?? [:]
        let photos = context["contactPhotos"] as? [String: Data] ?? [:]
        let senders = context["senderNames"] as? [String: String] ?? [:]
        let handler = onChange
        let namesHandler = onNames
        let photosHandler = onPhotos
        let sendersHandler = onSenderNames
        let preferencesHandler = onPreferences

        Task { @MainActor in namesHandler?(names) }
        Task { @MainActor in photosHandler?(photos) }
        Task { @MainActor in sendersHandler?(senders) }

        // Absent means the phone hasn't been updated yet, and the safe reading of that is the
        // default everyone starts with rather than a feed suddenly reappearing.
        let hides = context["hidesStatusUpdates"] as? Bool ?? true
        Task { @MainActor in preferencesHandler?(hides) }

        Task { @MainActor in
            handler?(credentials)
        }
    }

    // MARK: - WCSessionDelegate

    public func session(
        _ session: WCSession,
        activationDidCompleteWith state: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard state == .activated else { return }

        // On the main thread, where everything this class keeps is written. WatchConnectivity
        // calls this on a queue of its own, and from there it read the names, pictures and
        // session the phone was busy updating — and on a retry even emptied the pictures.
        // Two threads in one dictionary at once is a crash waiting for the right moment:
        // a contacts refresh at launch landing just as the link came up.
        //
        // The shared session is asked for again over there rather than carried across: it is
        // the same one, and it is not something to hand between threads.
        DispatchQueue.main.async { [self] in
            let session = WCSession.default

            // The phone may have signed in before the link was up.
            if let pending {
                send(pending, over: session)
            }

            // And the watch may have missed the moment it arrived.
            let received = session.receivedApplicationContext
            if !received.isEmpty {
                deliver(received)
            }
        }
    }

    public func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        // Read back on the main thread instead of carried there: the session keeps the latest
        // context it received, which is this one or something newer.
        DispatchQueue.main.async { [self] in
            deliver(WCSession.default.receivedApplicationContext)
        }
    }

    #if os(iOS)
    /// The watch was paired, or Chatman arrived on it.
    ///
    /// Signing in before either had happened was answered with "not installed yet" — and
    /// then never tried again, because nothing asked. The watch sat waiting for a session
    /// until the phone app happened to be restarted.
    public func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [self] in
            let session = WCSession.default
            guard session.isPaired, session.isWatchAppInstalled, let pending else { return }
            send(pending, over: session)
        }
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate so a newly paired watch is reachable without restarting the app.
        session.activate()
    }
    #endif
}
#endif
