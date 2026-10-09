import Foundation
import SwiftData
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// The signed-in session: what the interface binds to, and the only thing that talks to the
/// homeserver.
///
/// One instance per app. It owns the sync loop, applies what comes back to the store, and
/// exposes the handful of actions the interface needs.
@MainActor
@Observable
public final class ChatSession {

    public enum State: Equatable {
        case signedOut
        case signingIn
        /// The first sync is running. There's nothing to show yet.
        case firstSync
        /// The first sync failed. Distinct from ``offline`` because there's no cached content
        /// to fall back on, so the interface has to say so instead of showing an empty list.
        case firstSyncFailed(reason: String)
        case ready
        /// Something went wrong and we're retrying. The app stays usable on cached data.
        case offline(reason: String)
    }

    public private(set) var state: State = .signedOut
    public internal(set) var credentials: Credentials?

    /// Where notifications stand. See ``PushState``.
    public internal(set) var pushState: PushState = .off

    /// Whether notifications were asked for. Kept between launches so the app can register
    /// again after an update without asking twice.
    public var wantsNotifications: Bool {
        didSet { defaults.set(wantsNotifications, forKey: Keys.wantsNotifications) }
    }

    /// The address of the push gateway on your own server.
    ///
    /// Empty by default and empty for most people: without one there is nothing for Apple to
    /// deliver to. Set it and notifications can be turned on. See ``PushState``.
    public var pushGateway: String {
        didSet { defaults.set(pushGateway, forKey: Keys.pushGateway) }
    }

    /// Tells your homeserver to stop sending notifications to this device.
    ///
    /// Switching notifications off used to do nothing but remember the choice: the server
    /// kept its pusher for this phone and went on sending, so the switch in Settings was a
    /// switch in name only.
    public func unregisterForPush() async {
        pushState = .off
        guard let api,
              let token = defaults.string(forKey: "chatman.pushToken"),
              let appID = defaults.string(forKey: "chatman.pushAppID")
        else { return }

        do {
            try await api.removePusher(deviceToken: token, appID: appID)
            defaults.removeObject(forKey: "chatman.pushToken")
            defaults.removeObject(forKey: "chatman.pushAppID")
        } catch {
            // Kept, so the next time it's switched off it can be tried again.
            pushState = .failed("Couldn't switch notifications off on the server: \(error.localizedDescription)")
        }
    }

    /// Tells your homeserver where to send notifications for this device.
    ///
    /// The token comes from Apple and only exists on a build signed with a push entitlement,
    /// which a free developer account doesn't get. Everything up to that point runs anyway,
    /// so the day the certificate exists this needs no new code.
    public func registerForPush(token: Data, appID: String, deviceName: String) async {
        guard let api else { return }

        let gateway = pushGateway.trimmingCharacters(in: .whitespaces)
        guard !gateway.isEmpty else {
            pushState = .noGateway
            return
        }

        let hex = token.map { String(format: "%02x", $0) }.joined()

        do {
            try await api.registerPusher(
                deviceToken: hex,
                appID: appID,
                deviceDisplayName: deviceName,
                gatewayURL: gateway
            )
            // Remembered, because taking it away again needs exactly these two.
            defaults.set(hex, forKey: "chatman.pushToken")
            defaults.set(appID, forKey: "chatman.pushAppID")
            pushState = .on
        } catch {
            pushState = .failed(error.localizedDescription)
        }
    }

    /// Records why registration never got as far as a token.
    public func notePushFailure(_ reason: String) {
        pushState = .unavailable(reason)
    }

    /// Records that the device said no.
    public func notePushRefused() {
        pushState = .refused
    }

    /// Records that the app is waiting on Apple.
    public func notePushRegistering() {
        pushState = .registering
    }

    /// How much detail notifications show. Purely local; see ``NotificationDetail``.
    public var notificationDetail: NotificationDetail {
        didSet { defaults.set(notificationDetail.rawValue, forKey: Keys.notificationDetail) }
    }

    /// How much a photo you take is squeezed before it's sent.
    ///
    /// Only applies to the camera. A picture from your library is sent exactly as it is
    /// stored — it has already been compressed once, and encoding it again would make it
    /// bigger and worse at the same time.
    public var photoQuality: PhotoQuality {
        didSet { defaults.set(photoQuality.rawValue, forKey: Keys.photoQuality) }
    }

    /// Whether WhatsApp's status feed is kept out of the way. On unless you say otherwise.
    ///
    /// Hidden means hidden: it leaves both lists, stops counting towards the number on the
    /// watch face, and is muted on the server so notifications about it never reach any
    /// device — including ones this app hasn't been taught about yet. See ``StatusBroadcast``.
    public var hidesStatusUpdates: Bool {
        didSet {
            guard hidesStatusUpdates != oldValue else { return }
            defaults.set(hidesStatusUpdates, forKey: Keys.hidesStatusUpdates)

            Task { await applyStatusBroadcastRule(force: true) }

            #if canImport(WatchConnectivity) && os(iOS)
            SessionLink.shared.sharePreferences(hidesStatusUpdates: hidesStatusUpdates)
            #endif

            publishUnreadCount()
        }
    }

    /// Set once per launch, so the server isn't told the same thing on every sync.
    private var didApplyStatusBroadcastRule = false

    let profile: DeviceProfile
    let container: ModelContainer

    /// Which bridges are actually running on this server, learned by asking.
    ///
    /// Chatman offers every network mautrix has a bridge for, and no server runs all of them.
    /// Knowing which are there is what lets the connect screen say so instead of leaving
    /// someone tapping a network that will never answer.
    public internal(set) var installedNetworks: Set<ChatNetwork> = []

    /// The ones that answered with "no such thing", so they aren't asked again this run.
    var missingNetworks: Set<ChatNetwork> = []

    /// Bridges that didn't answer the last time they were asked. See `bridgeProblems`.
    var unansweredNetworks: Set<ChatNetwork> = []

    /// What each bridge said the last time it was asked. See `BridgeAnswer`.
    public internal(set) var bridgeAnswers: [ChatNetwork: BridgeAnswer] = [:]

    /// Bridges asked and not answered yet, and since when. See `BridgeDiagnosis`.
    public internal(set) var bridgeQuestions: [ChatNetwork: Date] = [:]

    /// The latest look at the bridges. See `BridgeRound`.
    public internal(set) var bridgeRound: BridgeRound?

    /// Whether a quick second look at the bridges is already on its way. See
    /// `recheckSoonIfUnanswered`.
    @ObservationIgnored var isRecheckScheduled = false
    @ObservationIgnored var lastQuickRecheck: Date = .distantPast

    /// Address-book names, keyed by the bridged account they belong to.
    ///
    /// The per-conversation list answers "what is this chat called". This one answers "who
    /// said that", which is a different question with a different key: in a group there is
    /// one room and a dozen people in it, and every one of them arrives under whatever handle
    /// their network gave them.
    public internal(set) var contactNamesByAccount: [String: String] = [:]

    /// Names chosen by hand, keyed the same way and kept between launches.
    ///
    /// Set once, from the private chat with somebody, and it follows them into every group
    /// they speak in — which is where a handle like "bdbkyra" is hardest to place.
    public internal(set) var customAccountNames: [String: String] = [:] {
        didSet { defaults.set(customAccountNames, forKey: Keys.customAccountNames) }
    }

    /// Private chats whose name could not be found in the address book.
    ///
    /// Kept so the app can say which ones, rather than only how many. "Two didn't match" is
    /// a shrug; "these two didn't match" is something you can go and look at.
    public internal(set) var unmatchedConversations: [String] = []

    /// Who is typing, per room.
    ///
    /// The oldest trick in messaging and still the most reassuring one: it says the other
    /// person is there, which is the actual question you have while waiting.
    public internal(set) var typingByRoom: [String: [String]] = [:]

    /// Rooms that exist but shouldn't be shown.
    ///
    /// Bridges keep a room to talk to you in. It's plumbing, and every other Matrix client
    /// leaves it sitting between your friends under a name like "signalbot".
    public internal(set) var hiddenRoomIDs: Set<String> = []

    /// True for a moment after catching up: on opening the app, and when the connection
    /// comes back.
    ///
    /// A sync that stops failing says nothing on its own: the line that was there disappears
    /// and you're left guessing whether it worked or whether the app gave up. This is the
    /// answer to that, and it goes away by itself because a permanent "connected" is furniture.
    public private(set) var justReconnected = false

    private var reconnectedTask: Task<Void, Never>?

    /// Says so, briefly.
    private func noteReconnected() {
        reconnectedTask?.cancel()
        justReconnected = true

        reconnectedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.justReconnected = false
        }
    }

    /// Whether the app is catching up: just opened, or syncing is failing but hasn't been away
    /// long enough to call it offline.
    ///
    /// Shown as quiet progress rather than a warning: the difference between "catching up"
    /// and "you are disconnected" is what makes the second one worth reading.
    public internal(set) var isReconnecting = false

    /// When the last sync came back with an answer.
    private var lastSyncSuccess: Date?

    /// A conversation something outside the app asked to see: a tap on a notification, or a
    /// `chatman://` link. The interface opens it and sets this back to `nil`.
    public var requestedConversationID: String?

    /// Asks the interface to open a conversation, from wherever that was asked.
    public func open(conversationID: String) {
        requestedConversationID = conversationID
    }

    /// When the server last answered a sync, in any of the three places one is made.
    ///
    /// Separate from `lastSyncSuccess`, which starts its clock at launch on purpose so a
    /// phone woken in a lift doesn't look broken. This one is only ever a real answer, and is
    /// what the watch face and the status screen report as "updated".
    public internal(set) var lastHeardFromServer: Date?

    /// What the phone-to-watch link is doing, in words.
    ///
    /// Shown on the watch while it waits. A watch that says nothing looks broken even when
    /// it's merely waiting for a phone that hasn't signed in yet.
    public private(set) var linkStatus: String?

    /// Which typeface the words are set in.
    ///
    /// Phone only. On a watch you read from an arm's length, often outdoors and often in a
    /// hurry, and that is the wrong place to start swapping letterforms.
    public var typeface: Typeface {
        didSet { defaults.set(typeface.rawValue, forKey: Keys.typeface) }
    }

    /// How far up the backdrop's light is turned, from nothing to full: the filaments, the
    /// stars or the lines of the ribbon, whichever is chosen. See `Backdrop` in the app.
    public var backdropPresence: Double {
        didSet { defaults.set(backdropPresence, forKey: Keys.backdropPresence) }
    }

    /// How much of the backdrop's coloured field is there, from none to all of it.
    ///
    /// Separate from ``backdropPresence``: that one is what is drawn, this one is the wash it
    /// lies on — and, for the ribbon, the light where it turns. See `Backdrop` in the app.
    public var backdropGlow: Double {
        didSet { defaults.set(backdropGlow, forKey: Keys.backdropGlow) }
    }

    /// How much a photo used as the backdrop is veiled — darkened in the dark, lightened in
    /// the light — so what is written over it stays readable.
    public var backdropVeil: Double {
        didSet { defaults.set(backdropVeil, forKey: Keys.backdropVeil) }
    }

    /// How soft a photo used as the backdrop is, from sharp to a haze of its colours.
    public var backdropBlur: Double {
        didSet { defaults.set(backdropBlur, forKey: Keys.backdropBlur) }
    }

    /// What colour the backdrop's light is, whichever backdrop it is.
    public var backdropColour: BackdropColour {
        didSet { defaults.set(backdropColour.rawValue, forKey: Keys.backdropColour) }
    }

    #if canImport(UIKit)
    /// Address-book pictures already turned into images, against the size they came from.
    ///
    /// Not observed, for the same reason as the previews below: it is a memo of something
    /// already on screen. See `contactPicture(for:)`.
    @ObservationIgnored
    var decodedPhotos: [String: (count: Int, image: UIImage)] = [:]
    #endif

    /// The last preview line worked out for each group, and when it was.
    ///
    /// Not observed: this is a memo of something already on screen, and making it observable
    /// would redraw the list every time the list asked it a question. See `preview(for:)`.
    @ObservationIgnored
    var groupPreviews: [String: (at: Date, source: String, line: String)] = [:]

    /// The lead for each board, and what it was worked out from. See `headline(for:)`.
    @ObservationIgnored
    var headlines: [String: (key: String, headline: Headline)] = [:]

    /// A message to go to when a conversation opens, instead of its end.
    ///
    /// Set by whatever opened it for a reason — the board whose lead was a particular
    /// message — and taken by the conversation as it appears.
    public var requestedFocus: (conversationID: String, messageID: String)?

    /// Whether the app stays dark no matter what the phone is set to.
    ///
    /// Phone only. A watch is dark and has no other setting to disagree with.
    public var forcesDarkMode: Bool {
        didSet { defaults.set(forcesDarkMode, forKey: Keys.forcesDarkMode) }
    }

    /// What the whole app is drawn on: the list and every conversation. See `BackdropStyle`.
    ///
    /// Phone only. The stars by default: it is the sort of thing you are supposed to notice
    /// only after a week, and a background nobody switches on is a background nobody sees.
    public var backdrop: BackdropStyle {
        didSet { defaults.set(backdrop.rawValue, forKey: Keys.backdrop) }
    }

    /// Invitations from people, waiting for an answer.
    ///
    /// Only the ones a bridge didn't send. A bridge's invitation is a chat being handed over
    /// and is taken without asking; a person's is a question, and a question needs somewhere
    /// to be asked.
    public private(set) var invitations: [Invitation] = []

    /// Somebody asking you into a room.
    public struct Invitation: Identifiable, Codable, Sendable, Hashable {
        public let roomID: String

        /// Who asked. Empty when the invitation arrived without saying.
        public let inviter: String

        /// What the room calls itself, when it has a name.
        public let name: String?

        public var id: String { roomID }

        public init(roomID: String, inviter: String, name: String?) {
            self.roomID = roomID
            self.inviter = inviter
            self.name = name
        }
    }

    /// The bridged accounts and how they're doing, keyed by network.
    public internal(set) var bridgeAccounts: [ChatNetwork: BridgeAccount] = [:]

    /// Names from this device's address book, keyed by conversation.
    ///
    /// Kept beside the stored conversation rather than written into it: the address book can
    /// change or access can be withdrawn, and the name the network gave should still be there
    /// underneath when that happens.
    public internal(set) var contactNames: [String: String] = [:]

    /// Pictures from the address book, only for conversations where the network had none.
    public internal(set) var contactPhotos: [String: Data] = [:]

    /// Why a bridge's contact list couldn't be fetched, per network.
    ///
    /// Kept so the screen can say what went wrong instead of showing an empty list, which
    /// looks identical to having no contacts at all.
    var contactLookupFailure: [ChatNetwork: String] = [:]

    /// What the last address-book matching run managed, for the settings screen.
    public internal(set) var matchStats = MatchStats()

    /// The bridged accounts that represent you on the networks you're connected to.
    var selfAccounts: Set<String> = []

    /// What each participant is called, gathered from the room's membership.
    ///
    /// A group conversation is unreadable without this: every line looks the same until you
    /// can see who said it.
    public internal(set) var memberNames: [String: String] = [:]

    /// The picture each participant uses, from the same membership events as their name.
    ///
    /// In a group this is what makes a line recognisable before it's read, the way Messages
    /// puts a face beside every message that isn't yours. An empty string means asked and
    /// there is none, which is what stops the same fruitless request every launch.
    public internal(set) var memberAvatars: [String: String] = [:]

    /// Set when a name or picture changed, so the next save is the only one that costs anything.
    var memberDetailsChanged = false

    /// What the last quick check of the server found, when one has been run.
    ///
    /// A stuck sync says only that nothing is arriving. This says whether the device has a
    /// network at all, whether the name resolves, and whether the server answers — which is
    /// the difference between "wait" and "something is actually wrong".
    public internal(set) var reachability: MatrixAPI.Reachability?

    /// True while that check is running.
    public internal(set) var isCheckingReachability = false

    /// Invitations currently being accepted, so a slow join isn't started twice.
    private var joiningRooms: Set<String> = []

    /// When the rooms still waiting to be joined were last tried. See `retryPendingJoins`.
    @ObservationIgnored private var lastJoinRetry: Date = .distantPast

    /// Messages in line or on their way to the server, so none is ever sent twice at once.
    @ObservationIgnored var sending: Set<String> = []

    /// The last message put in line for each chat. See `enqueue`.
    @ObservationIgnored var lanes: [String: Task<Delivery, Never>] = [:]

    /// Attachments being put on the server right now, outside the line. See `enqueue`.
    @ObservationIgnored var uploading: Set<String> = []

    /// Whether this launch has looked at what was left waiting from the last one.
    @ObservationIgnored private var didCheckOutbox = false

    /// When the bridges and the rest of the housekeeping last ran. See `tidyUpIfDue`.
    @ObservationIgnored var lastBridgeCheck: Date = .distantPast
    @ObservationIgnored var lastTidyUp: Date = .distantPast

    /// Whether a sync has brought rooms whose members nobody has counted yet. True at launch,
    /// so the first sync also picks up whatever an earlier run left uncounted. See
    /// `countNewRoomsIfNeeded`.
    @ObservationIgnored var hasUncountedRooms = true
    @ObservationIgnored var isCountingRooms = false

    /// True while the bridges are being asked again because a bot spoke.
    @ObservationIgnored var isRecheckingBridges = false
    let defaults: UserDefaults

    var api: MatrixAPI?
    private var syncTask: Task<Void, Never>?

    private var context: ModelContext { container.mainContext }

    private enum Keys {
        static let nextBatch = "chatman.nextBatch"
        static let pendingInvites = "chatman.pendingInvites"
        static let syncGeneration = "chatman.syncGeneration"
        static let memberGeneration = "chatman.memberGeneration"
        static let memberDetails = "chatman.memberDetails"
        static let notificationDetail = "chatman.notificationDetail"
        static let hidesStatusUpdates = "chatman.hidesStatusUpdates"
        static let photoQuality = "chatman.photoQuality"
        static let customAccountNames = "chatman.customAccountNames"
        static let wantsNotifications = "chatman.wantsNotifications"
        static let pushGateway = "chatman.pushGateway"
        static let invitations = "chatman.invitations"
        static let typeface = "chatman.typeface"
        static let backdrop = "chatman.backdrop"
        static let backdropVeil = "chatman.backdropVeil"
        static let backdropBlur = "chatman.backdropBlur"
        static let forcesDarkMode = "chatman.forcesDarkMode"
        static let backdropColour = "chatman.backdropColour"
        static let backdropPresence = "chatman.backdropPresence"
        static let backdropGlow = "chatman.backdropGlow"
    }

    public init(
        profile: DeviceProfile,
        container: ModelContainer,
        defaults: UserDefaults = .standard
    ) {
        self.profile = profile
        self.container = container
        self.defaults = defaults
        self.notificationDetail = defaults.string(forKey: Keys.notificationDetail)
            .flatMap(NotificationDetail.init(rawValue:)) ?? .senderAndMessage
        // Absent means on: nobody asked for a feed of other people's coffee, so it starts
        // hidden and stays hidden until somebody goes looking for it.
        self.hidesStatusUpdates = defaults.object(forKey: Keys.hidesStatusUpdates) as? Bool ?? true
        self.photoQuality = defaults.string(forKey: Keys.photoQuality)
            .flatMap(PhotoQuality.init(rawValue:)) ?? .balanced
        self.customAccountNames =
            defaults.dictionary(forKey: Keys.customAccountNames) as? [String: String] ?? [:]
        self.wantsNotifications = defaults.bool(forKey: Keys.wantsNotifications)
        self.pushGateway = defaults.string(forKey: Keys.pushGateway) ?? ""
        self.typeface = Typeface(stored: defaults.string(forKey: Keys.typeface))
        // Absent means on.
        self.backdrop = defaults.string(forKey: Keys.backdrop).flatMap(BackdropStyle.init(rawValue:))
            ?? .stars
        self.backdropVeil = defaults.object(forKey: Keys.backdropVeil) as? Double ?? 0.35
        self.backdropBlur = defaults.object(forKey: Keys.backdropBlur) as? Double ?? 0.2
        // The switch this replaced, which only ever meant the filaments under conversations.
        defaults.removeObject(forKey: "chatman.movingBackdrop")
        // Absent means off: following the phone is what everything else does, and an app
        // that decides for itself on first launch is an app that looks broken.
        self.forcesDarkMode = defaults.bool(forKey: Keys.forcesDarkMode)
        self.backdropColour = defaults.string(forKey: Keys.backdropColour)
            .flatMap(BackdropColour.init(rawValue:)) ?? .blue
        // Forty and thirty: found with the sliders, on a real conversation, rather than
        // guessed against an empty screen. The sliders stay — this is taste, and taste is not
        // the sort of thing one person settles for everybody.
        self.backdropPresence = defaults.object(forKey: Keys.backdropPresence) as? Double ?? 0.40
        self.backdropGlow = defaults.object(forKey: Keys.backdropGlow) as? Double ?? 0.30

        restoreMemberDetails()
        restoreReceivedNames()
        loadInvitations()
        restoreSession()
    }

    // MARK: - Session

    /// Picks up a session saved by a previous launch.
    private func restoreSession() {
        guard let credentials = CredentialStore.load() else { return }

        self.credentials = credentials
        self.api = MatrixAPI(homeserver: credentials.homeserver, accessToken: credentials.accessToken)
        self.state = hasSyncedBefore ? .ready : .firstSync
    }

    /// Connects phone and watch, so signing in on one is enough.
    ///
    /// Called by both apps at launch. On the phone it offers whatever session is stored; on
    /// the watch it waits for one to arrive.
    public func startDeviceLink() {
        #if canImport(WatchConnectivity)
        switch profile {
        case .phone:
            SessionLink.shared.start(onStatus: { [weak self] status in
                self?.linkStatus = status
            })
            SessionLink.shared.sharePreferences(hidesStatusUpdates: hidesStatusUpdates)
            SessionLink.shared.share(credentials)

        case .watch:
            SessionLink.shared.start(
                onChange: { [weak self] credentials in
                    self?.adopt(credentials)
                },
                onStatus: { [weak self] status in
                    self?.linkStatus = status
                },
                onNames: { [weak self] names in
                    self?.receiveNames(names)
                },
                onPreferences: { [weak self] hidesStatusUpdates in
                    guard let self, self.hidesStatusUpdates != hidesStatusUpdates else { return }
                    self.hidesStatusUpdates = hidesStatusUpdates
                },
                onPhotos: { [weak self] photos in
                    self?.receivePhotos(photos)
                },
                onSenderNames: { [weak self] names in
                    self?.receiveSenderNames(names)
                }
            )
        }
        #endif
    }

    /// Takes on a session handed over by the phone.
    ///
    /// Both devices end up using the same access token. That's deliberate: a second token
    /// would need the password again, which is the thing this exists to avoid. It does mean
    /// signing out anywhere signs out everywhere, which is what people expect anyway.
    public func adopt(_ handedOver: Credentials?) {
        guard let handedOver else {
            clearLocalSession()
            return
        }

        guard handedOver != credentials else { return }

        // The sync already running holds the old token, and it has to go first. Left
        // running, its long poll came back with "unknown token" after the new session was
        // in place — and that sign-out erased the session just handed over. The watch
        // ended up signed out while the phone was fine. It happens when the phone signs out
        // and in again while the watch app isn't running: the watch only ever hears about
        // the new session, never the sign-out in between.
        stopSyncing()

        CredentialStore.save(handedOver)
        credentials = handedOver
        api = MatrixAPI(homeserver: handedOver.homeserver, accessToken: handedOver.accessToken)

        // A handed-over session starts from nothing: whatever this device synced before
        // belonged to a different account, or to a token that no longer works.
        defaults.removeObject(forKey: Keys.nextBatch)
        defaults.removeObject(forKey: Keys.pendingInvites)
        // Invitations belong to the account too. They were left behind, so a card asking you
        // into a room of the previous account sat in the list of the next one.
        defaults.removeObject(forKey: Keys.invitations)
        defaults.removeObject(forKey: "chatman.connectedNetworks")
        defaults.removeObject(forKey: "chatman.forgottenNetworks")
        defaults.removeObject(forKey: "chatman.reconnectingSince")
        invitations = []
        try? context.delete(model: Message.self)
        try? context.delete(model: Conversation.self)
        try? context.save()

        state = .firstSync
        startSyncing()
    }

    /// Forgets the session without telling the server.
    ///
    /// Used on the watch when the phone signs out: the token is already being revoked over
    /// there, and calling it a second time would only fail.
    private func clearLocalSession() {
        stopSyncing()

        CredentialStore.clear()
        defaults.removeObject(forKey: Keys.nextBatch)
        defaults.removeObject(forKey: Keys.pendingInvites)
        // Invitations belong to the account too. They were left behind, so a card asking you
        // into a room of the previous account sat in the list of the next one.
        defaults.removeObject(forKey: Keys.invitations)
        defaults.removeObject(forKey: "chatman.connectedNetworks")
        defaults.removeObject(forKey: "chatman.forgottenNetworks")
        defaults.removeObject(forKey: "chatman.reconnectingSince")
        invitations = []

        try? context.delete(model: Message.self)
        try? context.delete(model: Conversation.self)
        try? context.save()

        credentials = nil
        api = nil
        state = .signedOut
    }

    var hasSyncedBefore: Bool {
        defaults.string(forKey: Keys.nextBatch) != nil
    }

    /// Signs in and starts syncing.
    ///
    /// - Parameter address: A homeserver address, or a Matrix ID like `@you:example.com` —
    ///   in which case the server is discovered from the domain.
    public func signIn(address: String, username: String, password: String) async throws {
        state = .signingIn

        let homeserver: Homeserver
        if username.contains(":"), address.isEmpty {
            let domain = String(username.split(separator: ":").last ?? "")
            guard let discovered = await MatrixAPI.discoverHomeserver(forDomain: domain) else {
                state = .signedOut
                throw MatrixError.invalidHomeserver
            }
            homeserver = discovered
        } else {
            guard let entered = Homeserver(string: address) else {
                state = .signedOut
                throw MatrixError.invalidHomeserver
            }
            homeserver = entered
        }

        let client = MatrixAPI(homeserver: homeserver)

        do {
            let response = try await client.logIn(
                username: username, password: password, deviceName: deviceName
            )

            let credentials = Credentials(
                userID: response.userID,
                deviceID: response.deviceID,
                accessToken: response.accessToken,
                homeserver: homeserver
            )

            CredentialStore.save(credentials)
            self.credentials = credentials
            self.api = client.authenticated(with: response.accessToken)
            self.state = .firstSync

            #if canImport(WatchConnectivity)
            SessionLink.shared.share(credentials)
            #endif

            startSyncing()
        } catch {
            state = .signedOut
            throw error
        }
    }

    private var deviceName: String {
        switch profile {
        case .phone: "Chatman on iPhone"
        case .watch: "Chatman on Apple Watch"
        }
    }

    /// Signs out and removes everything stored locally.
    public func signOut() async {
        stopSyncing()

        // Tell the watch first: after the token is revoked it would otherwise keep retrying
        // a session that can never work again.
        #if canImport(WatchConnectivity)
        SessionLink.shared.share(nil)
        #endif

        // Best effort: if the server can't be reached, the local session still has to go.
        try? await api?.logOut()

        CredentialStore.clear()
        defaults.removeObject(forKey: Keys.nextBatch)
        defaults.removeObject(forKey: Keys.pendingInvites)
        // Invitations belong to the account too. They were left behind, so a card asking you
        // into a room of the previous account sat in the list of the next one.
        defaults.removeObject(forKey: Keys.invitations)
        defaults.removeObject(forKey: "chatman.connectedNetworks")
        defaults.removeObject(forKey: "chatman.forgottenNetworks")
        defaults.removeObject(forKey: "chatman.reconnectingSince")
        invitations = []

        try? context.delete(model: Message.self)
        try? context.delete(model: Conversation.self)
        try? context.save()

        credentials = nil
        api = nil
        state = .signedOut
    }

    // MARK: - Syncing

    /// Starts the sync loop. Safe to call repeatedly.
    public func startSyncing() {
        guard api != nil, syncTask == nil else { return }

        // Whatever was on its way when the app last closed: sent now if it is still worth
        // sending, marked otherwise. Once a launch.
        if !didCheckOutbox {
            didCheckOutbox = true
            sweepOutbox()
            flushOutbox()
        }

        syncTask = Task { [weak self] in
            await self?.syncLoop()
        }
    }

    /// Starts over after a failed first sync.
    public func retryFirstSync() {
        stopSyncing()
        state = .firstSync
        startSyncing()
    }

    /// Stops syncing. Called when the app goes to the background — on the watch, that's every
    /// time the wrist drops, so this happens constantly and has to be cheap.
    public func stopSyncing() {
        syncTask?.cancel()
        syncTask = nil
        // Not catching up any more, whatever the loop was doing when it was stopped. Left on,
        // a reachability check still out from an earlier failure could come back, find it,
        // and call the app offline while nothing is failing.
        isReconnecting = false
    }

    /// Bumped whenever a change means the stored sync position can't be trusted.
    ///
    /// The server sends each change exactly once. If a version of this app failed to act on
    /// something — an invitation it couldn't accept, say — that event is gone for good, and no
    /// amount of waiting brings it back. Starting from scratch once is the only repair, and
    /// this is what makes that happen exactly once instead of on every launch.
    ///
    /// Bumped to 5 for read receipts. The markers that already exist are only ever sent with
    /// a first sync, and the filter used to throw them away — so every conversation read
    /// before this version still says "Sent". One fresh start asks for them all again.
    private static let syncGeneration = 5

    private func startFreshIfNeeded() {
        if defaults.integer(forKey: Keys.syncGeneration) != Self.syncGeneration {
            defaults.removeObject(forKey: Keys.nextBatch)
            defaults.set(Self.syncGeneration, forKey: Keys.syncGeneration)
        }

        recountMembersIfNeeded()
        reclassifyFilesIfNeeded()
    }

    /// Gives films and photos that were stored as files their proper kind, once.
    ///
    /// New ones are recognised as they arrive (see `MatrixEvent`); this is for what is
    /// already here, which would otherwise go on showing a paper icon for good.
    private func reclassifyFilesIfNeeded() {
        let key = "chatman.filesReclassified"
        guard !defaults.bool(forKey: key) else { return }

        let file = Message.Kind.file.rawValue
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.kindID == file && $0.mediaMimeType != nil }
        )
        for message in (try? context.fetch(descriptor)) ?? [] {
            switch MatrixEvent.Media.nature(of: message.mediaMimeType) {
            case .video: message.kind = .video
            case .image: message.kind = .image
            case .other: break
            }
        }

        try? context.save()
        defaults.set(true, forKey: key)
    }

    /// Bumped when the rule for counting a room's members changes.
    ///
    /// The count is asked of the server once and then kept, so a change to how it's worked out
    /// would otherwise only affect conversations created afterwards — and every existing one
    /// would keep an answer arrived at by the old, wrong rule.
    private static let memberGeneration = 3

    private func recountMembersIfNeeded() {
        guard defaults.integer(forKey: Keys.memberGeneration) != Self.memberGeneration else {
            return
        }

        for conversation in (try? context.fetch(FetchDescriptor<Conversation>())) ?? [] {
            conversation.otherMemberCount = 0
        }

        try? context.save()
        defaults.set(Self.memberGeneration, forKey: Keys.memberGeneration)
    }

    /// Fetches once, now, because somebody asked.
    ///
    /// The app already syncs continuously, so this changes nothing about what arrives — it
    /// exists because pulling a list down and having nothing happen feels like a broken app,
    /// even when the truth is that there was nothing to fetch.
    public func refreshNow() async {
        guard let api, let since = defaults.string(forKey: Keys.nextBatch) else { return }

        guard let response = try? await api.sync(
            since: since, timeout: .seconds(0), filter: profile.syncFilter
        ) else { return }

        lastHeardFromServer = .now
        apply(response)
        defaults.set(response.nextBatch, forKey: Keys.nextBatch)
        flushOutbox()

        // Said, the same way as on opening. A pull that turns for a moment and then shows
        // nothing leaves you guessing whether it found nothing or never got through.
        noteReconnected()
    }

    /// One sync, for a watch that isn't running.
    ///
    /// Called from a background wake-up, where there are a few seconds and no second chance:
    /// the poll returns immediately rather than waiting for something to happen, and whatever
    /// came back is applied and published. If nothing did, that's an answer too — the number
    /// on the face is then known to be right rather than merely old.
    ///
    /// Never a first sync. Building the whole conversation list is minutes of work on a
    /// watch's radio, and a wake-up is not the place for it.
    public func refreshInBackground() async {
        guard let api, let since = defaults.string(forKey: Keys.nextBatch) else { return }

        guard let response = try? await api.sync(
            since: since, timeout: .seconds(0), filter: profile.syncFilter
        ) else { return }

        lastHeardFromServer = .now
        apply(response)
        defaults.set(response.nextBatch, forKey: Keys.nextBatch)
        flushOutbox()

        #if os(watchOS)
        // The one moment the watch hears anything while the app is shut: tell the wrist.
        await WristTap.tap(for: self, defaults: defaults)
        #endif
    }

    private func syncLoop() async {
        var consecutiveFailures = 0

        startFreshIfNeeded()

        // The clock starts at launch, not at the first answer: a phone woken in a lift should
        // spend its first cycle looking like it's catching up, not like it's broken.
        lastSyncSuccess = .now

        // Opening the app is catching up, and it says so: turning until the server has
        // answered once, then the green dot. That dot is the only way to see, at a glance,
        // that what's on screen is current — and it used to appear only after a failure,
        // so on an ordinary open there was nothing at all.
        //
        // Only after being away, though: longer than one long poll and a little, which is
        // the most the screen can have fallen behind while it was open. A look at Control
        // Centre or a call banner isn't being away, and on the watch a wrist raised again
        // straight after it dropped shouldn't cost a second request and a dot.
        let away = lastHeardFromServer.map {
            Date.now.timeIntervalSince($0) > Double(profile.syncTimeout.components.seconds) + 15
        } ?? true
        var isCatchingUp = hasSyncedBefore && away
        if isCatchingUp {
            justReconnected = false
            isReconnecting = true
        }

        while !Task.isCancelled {
            guard let api else { return }

            do {
                let since = defaults.string(forKey: Keys.nextBatch)
                let filter = since == nil ? SyncFilter.initial : profile.syncFilter

                // The first question after opening doesn't wait. With nothing new the server
                // holds a long poll open for half a minute, and that's half a minute of
                // turning before "up to date" — for news there wasn't.
                let response = try await api.sync(
                    since: since,
                    timeout: isCatchingUp ? .seconds(0) : profile.syncTimeout,
                    filter: filter
                )
                isCatchingUp = false

                guard !Task.isCancelled else { return }

                lastHeardFromServer = .now
                apply(response)
                defaults.set(response.nextBatch, forKey: Keys.nextBatch)

                // An answer from the server is proof there is a connection, which is exactly
                // what a message waiting in the outbox has been waiting for.
                flushOutbox()

                // Rooms that just arrived are counted now, not at the next tidy-up.
                countNewRoomsIfNeeded()

                // Worth announcing after catching up or recovering, not on every long poll.
                if isReconnecting || consecutiveFailures > 0 {
                    noteReconnected()
                }

                consecutiveFailures = 0
                lastSyncSuccess = .now
                isReconnecting = false
                reachability = nil
                state = .ready

            } catch let error as MatrixError {
                // Stopped, not failed. Cancelling a request comes back as a network error,
                // and without this every stop — on the watch, every time the wrist drops —
                // was counted as a failed sync: "reconnecting" switched on, a reachability
                // check started from an app on its way to the background, and a "reconnected"
                // flash on the next look. First, too, because a stopped loop must not sign
                // anyone out on the strength of an answer meant for the token it was using.
                guard !Task.isCancelled else { return }

                // An invalid token can't be retried: the session is over.
                if error.requiresSignIn {
                    await signOut()
                    return
                }

                consecutiveFailures += 1
                reportFailure(error.localizedDescription, attempts: consecutiveFailures)

                await backOff(afterFailures: consecutiveFailures, suggested: error.retryAfter)

            } catch {
                guard !Task.isCancelled else { return }
                consecutiveFailures += 1
                reportFailure(error.localizedDescription, attempts: consecutiveFailures)
                await backOff(afterFailures: consecutiveFailures, suggested: nil)
            }
        }
    }

    /// Starts a fresh attempt straight away instead of waiting out the backoff.
    ///
    /// The retry delay grows with each failure, which is right for a battery and wrong for
    /// someone standing there who just walked back into range.
    public func reconnect() {
        stopSyncing()

        // Leaving the state on `.offline` meant the screen didn't change when you tapped, so
        // the button looked broken while it was in fact working.
        if hasSyncedBefore { state = .ready }

        isReconnecting = true
        lastSyncSuccess = .now
        startSyncing()

        Task { await checkReachability() }
    }

    /// Asks the server one small question, quickly, and remembers the answer.
    public func checkReachability() async {
        guard let api, !isCheckingReachability else { return }

        isCheckingReachability = true
        defer { isCheckingReachability = false }

        let found = await api.reachability()
        reachability = found

        // A probe that failed is proof, where a sync that hasn't answered yet is only a
        // suspicion. No reason to keep saying "Updating…" for another minute once the server
        // has been asked a direct question and didn't answer it.
        if found != .reachable, hasSyncedBefore, isReconnecting {
            isReconnecting = false
            state = .offline(reason: found.summary)
        }
    }

    /// Reports a sync failure in whichever way the interface can act on.
    ///
    /// The distinction matters more than it looks. With cached conversations on screen, a
    /// failure is a banner and the app stays usable. With nothing cached, silently retrying
    /// behind a spinner leaves someone staring at an endless loading screen with no way out —
    /// a trap other Matrix clients are still stuck in.
    private func reportFailure(_ reason: String, attempts: Int) {
        guard !hasSyncedBefore else {
            // A sync request is held open for half a minute at a time, so one that comes back
            // empty-handed is ordinary — a lift, a tunnel, a wifi handover. Warning about it
            // immediately teaches people to ignore the warning, which is worse than not
            // showing one. Until a whole refresh cycle has gone by without success, this is
            // reported as still working rather than as broken.
            if let last = lastSyncSuccess, Date.now.timeIntervalSince(last) < offlineGrace {
                isReconnecting = true

                // Ask the server a direct question straight away rather than at the end of
                // the grace period. Waiting out a minute of "Updating…" before finding out
                // there is no connection at all is a minute spent saying nothing.
                if reachability == nil {
                    Task { await checkReachability() }
                }
                return
            }

            isReconnecting = false
            // The probe's own words when it has them: "No internet on this device" says what
            // to do about it, where "The request timed out" only says what happened.
            state = .offline(reason: reachability?.summary ?? reason)
            return
        }

        // Allow a couple of quick retries first: a single dropped request during sign-in is
        // common and resolves itself.
        state = attempts >= 3 ? .firstSyncFailed(reason: reason) : .firstSync
    }

    /// How long a conversation can go without a successful sync before it's called offline.
    ///
    /// Two full cycles plus a little: enough that one missed round trip passes unremarked,
    /// short enough that a genuine outage is visible before someone sends into the void.
    private var offlineGrace: TimeInterval {
        let seconds = Double(profile.syncTimeout.components.seconds)
        return seconds * 2 + 10
    }

    /// Waits before trying again, backing off further each time.
    ///
    /// Without this a watch that has lost signal retries in a tight loop and empties its
    /// battery achieving nothing. Cancelling the task cancels the sleep, so quitting is
    /// immediate.
    private func backOff(afterFailures failures: Int, suggested: Duration?) async {
        let exponential = Duration.seconds(min(pow(2.0, Double(failures)), 60))
        let delay = suggested ?? min(exponential, profile.maximumRetryDelay)

        try? await Task.sleep(for: delay)
    }

    // MARK: - Applying sync results

    func apply(_ response: MatrixAPI.SyncResponse) {
        let directPartners = invertDirectRooms(response.directRooms)

        for (roomID, room) in response.rooms?.join ?? [:] {
            apply(room, to: roomID, directPartner: directPartners[roomID])
        }

        // `m.direct` covers every room, and arrives only when it changes — not when the rooms
        // it names happen to change. Applied only to the rooms in the same batch, a bridge that
        // filled it in after making a room left that room unmarked for good: no partner, so no
        // match in the address book and no network badge from it.
        //
        // Additions only. A room dropping out of the list is not taken as proof it stopped
        // being a private chat, because the member count says so too and the two would fight.
        let inBatch = Set(response.rooms?.join?.keys ?? [:].keys)
        for (roomID, partner) in directPartners where !inBatch.contains(roomID) {
            guard let conversation = conversation(id: roomID) else { continue }
            conversation.isDirect = true
            conversation.directPartnerID = partner
            conversation.network = BridgeIdentity.network(of: partner)
        }

        if let chosen = response.chosenNames {
            applyChosenNames(chosen)
        }

        // Which rooms are silenced, whenever the rules came along. Every stored room is set
        // either way: a room that was unmuted somewhere else simply isn't in the list any more.
        if let muted = response.mutedRooms {
            for conversation in (try? context.fetch(FetchDescriptor<Conversation>())) ?? [] {
                let silenced = muted.contains(conversation.id)
                if conversation.isMuted != silenced { conversation.isMuted = silenced }
            }
        }

        for roomID in response.rooms?.leave?.keys ?? [:].keys {
            if let conversation = conversation(id: roomID) {
                context.delete(conversation)
            }
            // An invitation that was withdrawn arrives here as well, and nothing took its
            // card away: it stayed in the list, and accepting it tried to join a room that
            // was no longer on offer, again and again.
            forgetInvitation(to: roomID)
        }

        try? context.save()
        saveMemberDetails()
        publishUnreadCount()
        retryPendingJoins()

        sort(invitations: response.rooms?.invite ?? [:])
    }

    /// Whether a room exists but shouldn't be shown anywhere.
    ///
    /// One rule, asked by both apps and by the count on the watch face, because a chat that
    /// is hidden in the list and still counted on the face is worse than not hiding it: you
    /// go looking for a message that isn't there.
    public func isHidden(_ conversation: Conversation) -> Bool {
        if hiddenRoomIDs.contains(conversation.id) { return true }
        if hidesStatusUpdates, conversation.isStatusBroadcast { return true }

        guard let partner = conversation.directPartnerID else { return false }
        return BridgeIdentity.isBridgeBot(partner)
    }

    /// Tells the server whether to notify about the status feed.
    ///
    /// Only worth doing once a launch, and only once the room is actually known — which is
    /// after the first sync, not at startup.
    func applyStatusBroadcastRule(force: Bool = false) async {
        guard let api else { return }
        guard force || !didApplyStatusBroadcastRule else { return }

        let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let feeds = all.filter(\.isStatusBroadcast)
        guard !feeds.isEmpty else { return }

        didApplyStatusBroadcastRule = true

        for feed in feeds {
            if hidesStatusUpdates {
                try? await api.muteRoom(feed.id)
            } else {
                try? await api.unmuteRoom(feed.id)
            }
        }
    }

    /// Decides which invitations to take and which to ask about.
    ///
    /// A bridge doesn't put your chats in front of you: it creates a room per conversation
    /// and invites you to each one. Until the invitation is accepted the room stays
    /// invisible, so a client that ignores invitations shows an empty list no matter how
    /// well everything else works. Those have to be taken without asking, or the app would
    /// open on a screen full of questions about chats you already have.
    ///
    /// Everything else is a question. This used to accept anything at all, which was safe on
    /// the server it was written for — registration closed, federation off, so the only
    /// account that could invite you was your own bridge. On a server that talks to the rest
    /// of Matrix that assumption is simply wrong: a stranger's invitation would land in your
    /// list as an ordinary chat, and there would be no way to say no.
    func sort(invitations rooms: [String: MatrixAPI.SyncResponse.InvitedRoom]) {
        guard !rooms.isEmpty else { return }

        var fromBridges: [String] = []
        var asked: [Invitation] = []

        for (roomID, room) in rooms {
            let events = room.inviteState?.events ?? []

            // Whoever set your membership to "invited" is the one who asked.
            let inviter = events.first { event in
                guard case .membership = event.content else { return false }
                return event.stateKey == credentials?.userID
            }?.sender

            let name = events.compactMap { event -> String? in
                guard case .roomName(let given) = event.content else { return nil }
                return given
            }.first

            // A bridge bot or one of its ghosts: this is a chat being handed over, not
            // somebody knocking.
            //
            // And only on your own server. The name alone decided this before, and a name is
            // anyone's to pick: on a server that federates, a stranger registered elsewhere
            // as `@whatsapp_x` or `@signalbot` was joined without being asked. Your bridges
            // put their accounts on your homeserver, so that is where they must come from.
            if let inviter, BridgeIdentity.network(of: inviter) != .matrix, isOnOwnServer(inviter) {
                fromBridges.append(roomID)
            } else {
                asked.append(
                    Invitation(roomID: roomID, inviter: inviter ?? "", name: name)
                )
            }
        }

        accept(fromBridges)
        remember(asked)
    }

    /// Keeps invitations that need an answer, without losing the ones already waiting.
    private func remember(_ asked: [Invitation]) {
        guard !asked.isEmpty else { return }

        var waiting = invitations
        for invitation in asked where !waiting.contains(where: { $0.id == invitation.id }) {
            waiting.append(invitation)
        }

        invitations = waiting
        saveInvitations()
    }

    /// Takes an invitation, and puts the chat in the list.
    public func accept(_ invitation: Invitation) {
        invitations.removeAll { $0.id == invitation.id }
        saveInvitations()
        accept([invitation.roomID])
    }

    /// Turns one down. The room is left, so it doesn't come back on the next sync.
    public func decline(_ invitation: Invitation) {
        invitations.removeAll { $0.id == invitation.id }
        saveInvitations()

        guard let api else { return }
        Task { try? await api.leaveRoom(invitation.roomID) }
    }

    private func saveInvitations() {
        guard let data = try? JSONEncoder().encode(invitations) else { return }
        defaults.set(data, forKey: Keys.invitations)
    }

    func loadInvitations() {
        guard let data = defaults.data(forKey: Keys.invitations),
              let stored = try? JSONDecoder().decode([Invitation].self, from: data)
        else { return }

        invitations = stored
    }

    /// Tries the rooms still waiting to be joined again, at most once a minute.
    ///
    /// A join that failed was kept to be retried — but the retry only ran when another
    /// invitation happened to arrive, so a bridge portal whose join failed on a weak signal
    /// could wait for weeks, invisible. Now every sync that goes through asks again, with a
    /// minute between tries so a join that keeps failing doesn't knock on every sync.
    func retryPendingJoins() {
        guard Date.now.timeIntervalSince(lastJoinRetry) > 60 else { return }
        lastJoinRetry = .now
        accept([])
    }

    /// Drops a room from the invitations and from the joins still to be tried.
    func forgetInvitation(to roomID: String) {
        if invitations.contains(where: { $0.roomID == roomID }) {
            invitations.removeAll { $0.roomID == roomID }
            saveInvitations()
        }

        var pending = Set(defaults.stringArray(forKey: Keys.pendingInvites) ?? [])
        if pending.remove(roomID) != nil {
            defaults.set(Array(pending), forKey: Keys.pendingInvites)
        }
    }

    /// Joins rooms, one at a time, keeping the ones that fail.
    private func accept(_ roomIDs: [String]) {
        guard let api else { return }

        // Invitations arrive once and are never repeated, so a join that fails would
        // otherwise strand the conversation forever: the room stays invited on the server
        // and the client never hears about it again. They're kept until the join succeeds.
        var pending = Set(defaults.stringArray(forKey: Keys.pendingInvites) ?? [])
        pending.formUnion(roomIDs)

        guard !pending.isEmpty else { return }

        for roomID in pending where !joiningRooms.contains(roomID) {
            joiningRooms.insert(roomID)

            Task {
                let joined = (try? await api.joinRoom(roomID)) != nil
                joiningRooms.remove(roomID)

                if joined {
                    var remaining = Set(defaults.stringArray(forKey: Keys.pendingInvites) ?? [])
                    remaining.remove(roomID)
                    defaults.set(Array(remaining), forKey: Keys.pendingInvites)
                }
            }
        }

        defaults.set(Array(pending), forKey: Keys.pendingInvites)
    }


    /// Turns `m.direct`'s user-to-rooms mapping into rooms-to-user, which is how it's used.
    private func invertDirectRooms(_ directRooms: [String: [String]]) -> [String: String] {
        var result: [String: String] = [:]

        for (userID, roomIDs) in directRooms {
            for roomID in roomIDs {
                result[roomID] = userID
            }
        }

        return result
    }

    private func apply(
        _ room: MatrixAPI.SyncResponse.JoinedRoom,
        to roomID: String,
        directPartner: String?
    ) {
        let conversation = conversation(id: roomID) ?? {
            let new = Conversation(id: roomID)
            context.insert(new)
            hasUncountedRooms = true
            return new
        }()

        if let directPartner {
            conversation.isDirect = true
            conversation.directPartnerID = directPartner
            conversation.network = BridgeIdentity.network(of: directPartner)
        }

        // A limited timeline means the server skipped events: what's stored is still true,
        // it just isn't continuous any more. An earlier version threw the whole conversation
        // away to avoid that gap, which turned a busy chat into an empty screen with no way
        // back — the messages were gone locally and the token to re-fetch them with was gone
        // too. A gap nobody notices is better than a conversation that looks deleted.
        //
        // The token is taken whenever the server offers a newer one, so history can still be
        // pulled in from the point the gap starts.
        //
        // And for a room that has no way back yet — but "no token" means two things, and only
        // one of them wants a new one. A room nothing is stored for needs it. A room whose
        // token ran out because scrolling up reached its very first message does not: taking a
        // fresh one there meant the next scroll up downloaded the whole history again, page by
        // page, only to find every message already here. Told apart by whether anything is
        // stored — asked before this batch's own messages go in, below.
        if let token = room.timeline?.previousBatch {
            let skippedEvents = room.timeline?.isLimited == true
            let needsWayBack = conversation.previousBatch == nil && !hasStoredMessages(conversation)
            if skippedEvents || needsWayBack {
                conversation.previousBatch = token
            }
        }

        for event in room.state?.events ?? [] {
            applyStateEvent(event, to: conversation)
        }

        for event in room.timeline?.events ?? [] {
            applyTimelineEvent(event, to: conversation)
        }

        applyReceipts(room.ephemeral?.receipts ?? [], to: conversation)

        // Only when this batch actually said who is typing. See `Ephemeral.typing`.
        if let typing = room.ephemeral?.typing {
            // Never yourself: your own typing is not news, and the server echoes it back.
            let others = typing.filter { !isSelf($0) }
            if others.isEmpty {
                typingByRoom.removeValue(forKey: roomID)
            } else {
                typingByRoom[roomID] = others
            }
        }

        noteCounts(room.unreadNotifications, for: conversation)

        // What the account itself says about this room: put away, pinned, marked unread, or
        // named by hand. Each only when this batch actually mentioned it — a sync that says
        // nothing about tags must leave the drawer alone rather than emptying it.
        if let notes = room.accountData {
            if let lowPriority = notes.isLowPriority { conversation.isArchived = lowPriority }
            if let favourite = notes.isFavourite { conversation.isPinned = favourite }
            if let unread = notes.isMarkedUnread { conversation.isManuallyUnread = unread }
            if let chosen = notes.customName {
                conversation.customName = chosen.isEmpty ? nil : chosen
            }
        }

        nameIfNeeded(conversation, heroes: room.summary?.heroes)
    }

    /// Marks your own messages as delivered or read, from other people's read markers.
    ///
    /// A receipt says "I have read up to here", not "I have read this one". So it settles a
    /// whole run at once, which is exactly what's needed: bridges send one marker for a
    /// conversation, not one per message.
    private func applyReceipts(
        _ receipts: [MatrixAPI.SyncResponse.Receipt], to conversation: Conversation
    ) {
        guard !receipts.isEmpty else { return }

        for receipt in receipts {
            // Your own marker says only that you have caught up, which the sender already
            // knew. It's the other side's that means something — for ticks. For what is
            // waiting on you it is the other way round: read on the phone, in WhatsApp or in
            // Element, and it has been seen, wherever that was. Only when it reaches the
            // newest message, so a marker for something older doesn't clear something new.
            if isSelf(receipt.userID) {
                let upTo = message(id: receipt.eventID)?.timestamp ?? receipt.timestamp
                if let upTo, upTo >= conversation.lastActivity {
                    clearAttention(in: conversation)
                }
                continue
            }

            // The event the marker points at is usually one we have; when it isn't, the time
            // the marker was made is just as good a cut-off, and it's always present.
            guard let cutoff = message(id: receipt.eventID)?.timestamp ?? receipt.timestamp
            else { continue }

            // A marker from the bridge's own account means it has handed the message on.
            // From anyone else it means a person has seen it.
            let fromBridge = BridgeIdentity.isBridgeBot(receipt.userID)
            let when = receipt.timestamp ?? .now

            // Remembered on the conversation too, so a message loaded later — scrolling back
            // through history — can be marked without waiting for another receipt that may
            // never come.
            if conversation.deliveredThrough ?? .distantPast < cutoff {
                conversation.deliveredThrough = cutoff
            }
            if !fromBridge, conversation.readThrough ?? .distantPast < cutoff {
                conversation.readThrough = cutoff
            }

            // Asked of the store rather than walked in Swift.
            //
            // `conversation.messages` is the whole relationship: reading it pulls every
            // message in the room out of the database. Receipts arrive with every sync, and
            // in a busy group that meant loading thousands of messages, several times a
            // minute, to set a field on the two or three that needed it. This asks for
            // exactly those: sent by you, old enough to be covered, and not already marked.
            // Once everything is marked it comes back empty and costs nothing.
            for mine in unmarked(in: conversation, upTo: cutoff) {
                if mine.deliveredAt == nil { mine.deliveredAt = when }

                // Read implies delivered, never the other way round.
                if !fromBridge, mine.readAt == nil { mine.readAt = when }
            }
        }
    }

    /// Your own messages up to a point in time that still need a tick.
    private func unmarked(in conversation: Conversation, upTo cutoff: Date) -> [Message] {
        // Every account that counts as you: your Matrix ID, and whatever the bridges send
        // your own messages under.
        var mine = Array(selfAccounts)
        if let me = credentials?.userID { mine.append(me) }
        guard !mine.isEmpty else { return [] }

        let room = conversation.id
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.conversation?.id == room
                    && mine.contains(message.sender)
                    && message.timestamp <= cutoff
                    && !message.isPending
                    && (message.deliveredAt == nil || message.readAt == nil)
            }
        )

        return (try? context.fetch(descriptor)) ?? []
    }

    /// Marks a message that arrived after the receipt that covers it.
    ///
    /// Receipts and history arrive in whatever order the server feels like. This is the other
    /// half of ``applyReceipts``: one catches messages already stored, this catches the ones
    /// stored afterwards.
    private func applyKnownReceipts(to message: Message, in conversation: Conversation) {
        guard isSelf(message.sender), !message.isPending else { return }

        if let through = conversation.deliveredThrough,
           message.timestamp <= through, message.deliveredAt == nil {
            message.deliveredAt = through
        }

        if let through = conversation.readThrough,
           message.timestamp <= through, message.readAt == nil {
            message.readAt = through
        }
    }

    private func applyStateEvent(_ event: MatrixEvent, to conversation: Conversation) {
        switch event.content {
        case .roomName(let name):
            conversation.name = name

        case .roomAvatar(let url):
            conversation.avatarURL = url

        case .encrypted:
            conversation.isEncrypted = true

        case .membership(let membership):
            // Members give away which service this room belongs to, and unlike messages they
            // arrive again on every full sync — which is what lets an existing conversation
            // pick this up rather than waiting for someone to say something.
            if conversation.network == .matrix, let member = event.stateKey {
                let network = BridgeIdentity.network(of: member)
                if network != .matrix {
                    conversation.network = network
                }
            }

            // A one-to-one conversation takes its name from the other person, and this is
            // where that name arrives.
            if let member = event.stateKey, let displayName = membership.displayName {
                note(member, name: displayName, avatar: membership.avatarURL)
            }

            if conversation.isDirect,
               event.stateKey == conversation.directPartnerID,
               let displayName = membership.displayName {
                conversation.name = displayName
                conversation.avatarURL = membership.avatarURL ?? conversation.avatarURL
            }

        default:
            break
        }
    }

    private func applyTimelineEvent(_ event: MatrixEvent, to conversation: Conversation) {
        // State events can appear in the timeline too, so route them the same way.
        if event.stateKey != nil {
            applyStateEvent(event, to: conversation)
        }

        // A bridge's bot speaks when something about the bridge changed. See `noteBridgeSpoke`.
        if event.content.isMessage, BridgeIdentity.isBridgeBot(event.sender) {
            noteBridgeSpoke()
        }

        switch event.content {
        case .reaction(let key):
            guard let targetID = event.relation?.eventID,
                  let target = message(id: targetID) else { return }
            target.addReaction(key, by: event.sender, event: event.id)

        case .redaction:
            // Deleting a message is the one action where doing nothing is actively wrong:
            // someone took it back, and it stays on screen until this lands.
            guard let targetID = event.redactedEventID ?? event.relation?.eventID else { return }

            if let target = message(id: targetID) {
                remove(target, from: conversation)
            } else if let reacted = message(holdingReaction: targetID, in: conversation) {
                // Not a message: a reaction someone took back. Taking one back names the
                // reaction's own event, which is never stored as a message, so this used to
                // find nothing and the reaction stayed on the bubble for good.
                reacted.removeReaction(event: targetID)
            }

        case .text, .emote, .notice, .image, .video, .audio, .file, .encrypted:
            // An edit arrives as a whole new message pointing at the old one. Storing it as
            // its own message would show the conversation twice over — once as written and
            // once as corrected.
            if event.relation?.kind == .replacement, let targetID = event.relation?.eventID {
                // Never a message of its own, found or not. When the original has not been
                // loaded yet — the first sync brings one event per room, and that one can be
                // an edit — it used to fall through and be stored as a new message with the
                // "* corrected" fallback text, so the list read "* …" and the conversation
                // later showed both. Dropped instead: the original, when it comes, is still
                // the right message, only without the correction.
                guard let target = message(id: targetID) else { return }

                // Only the person who wrote it may change it — the rule Matrix itself sets.
                // Applied without asking, anyone in a group could send an edit pointing at
                // somebody else's message and have their words shown under that person's
                // name, marked as edited. "You" is any of your accounts: a message sent from
                // here and corrected in WhatsApp on the phone arrives under the bridge's
                // account for you, and that must still count as the same writer.
                guard event.sender == target.sender
                        || (isSelf(event.sender) && isSelf(target.sender))
                else { return }

                // `m.new_content` is what the message should now read. Its own `body` is the
                // fallback for clients that can't apply edits, and carries a leading "* " by
                // convention — taking that literally leaves an asterisk on every correction.
                target.body = event.replacementBody ?? event.content.preview
                target.wasEdited = true

                if conversation.lastMessagePreview.isEmpty
                    || target.timestamp >= conversation.lastActivity {
                    conversation.lastMessagePreview = target.body
                }
                return
            }

            insertMessage(event, into: conversation)

        case .sticker, .poll:
            insertMessage(event, into: conversation)

        case .pollResponse(let answers):
            // A vote, which belongs to its poll and is never a message of its own. When the
            // poll itself isn't here — older than anything loaded — there is nothing to count
            // it towards, and it goes: the same as a reaction to a message not yet loaded.
            guard let pollID = event.relation?.eventID,
                  let poll = message(id: pollID),
                  var state = poll.poll
            else { return }
            state.record(answers, by: event.sender)
            poll.poll = state

        case .pollEnd:
            guard let pollID = event.relation?.eventID,
                  let poll = message(id: pollID),
                  var state = poll.poll
            else { return }
            state.isClosed = true
            poll.poll = state

        case .sendStatus(let report):
            applySendStatus(report, about: event.relation?.eventID)

        case .membership, .roomName, .roomAvatar, .unsupported:
            break
        }
    }

    /// What a bridge said about one of your messages.
    ///
    /// Only a failure is news. Success is what "Delivered" already means, and it is marked
    /// here too so a bridge that sends these and no read marker still gets its tick. A
    /// failure is kept on the message, word for word from the bridge, so the bubble can say
    /// what went wrong instead of looking sent.
    func applySendStatus(_ report: MatrixEvent.SendStatusReport, about eventID: String?) {
        guard let eventID, let mine = message(id: eventID) else { return }

        switch report.outcome {
        case .success:
            mine.deliveryProblem = nil
            if mine.deliveredAt == nil { mine.deliveredAt = .now }
        case .failedRetriable, .failedPermanently:
            mine.deliveryProblem = report.message?.isEmpty == false
                ? report.message
                : String(localized: "Not delivered", bundle: .module)
        case .pending:
            break
        }
    }

    /// What a message actually says, without the copy of the message it answers.
    static func text(of event: MatrixEvent) -> String {
        guard event.relation?.kind == .reply else { return event.content.preview }
        return ReplyFallback.strip(event.content.preview)
    }

    /// The stored message for an event, whether it arrived just now or from history.
    ///
    /// One place, because there were two and they had drifted: history left out the sender's
    /// name, and each new thing a message could carry had to be added twice.
    static func makeMessage(from event: MatrixEvent, senderName: String?) -> Message {
        let media = event.content.media

        // A poll keeps its question as its words; the list shows it with the chart in front.
        let body: String
        if case .poll(let poll) = event.content {
            body = poll.question
        } else {
            body = text(of: event)
        }

        let message = Message(
            id: event.id,
            sender: event.sender,
            senderName: senderName,
            timestamp: event.timestamp,
            body: body,
            kind: event.content.messageKind,
            mediaURL: media?.url,
            mediaWidth: media?.width,
            mediaHeight: media?.height,
            mediaMimeType: media?.mimeType,
            mediaThumbnailURL: media?.thumbnailURL,
            isAnimated: media?.isAnimated ?? false,
            caption: media?.caption,
            replyToID: event.relation?.kind == .reply ? event.relation?.eventID : nil
        )

        message.isVoice = media?.isVoice ?? false
        message.mediaDuration = media?.duration
        if let shape = media?.waveform { message.waveform = shape }
        if case .poll(let poll) = event.content { message.poll = PollState(poll) }

        return message
    }

    private func insertMessage(_ event: MatrixEvent, into conversation: Conversation) {
        // Our own message coming back through sync: replace the local copy rather than
        // showing it twice.
        if let transactionID = event.transactionID, let pending = message(id: transactionID) {
            context.delete(pending)
        }

        guard message(id: event.id) == nil else { return }

        let message = Self.makeMessage(from: event, senderName: memberNames[event.sender])

        message.conversation = conversation
        context.insert(message)
        applyKnownReceipts(to: message, in: conversation)
        noteAttention(to: message, from: event, in: conversation)

        // Which service this room belongs to. `m.direct` names the other person in a private
        // chat, but a group has no such entry and a bridge doesn't always fill it in — while
        // the sender gives it away every time, because bridges name their accounts after
        // themselves. Only ever set, never unset: one Matrix reply doesn't make a Signal
        // conversation stop being one.
        if conversation.network == .matrix {
            let network = BridgeIdentity.network(of: event.sender)
            if network != .matrix {
                conversation.network = network
            }
        }

        if event.timestamp > conversation.lastActivity {
            conversation.lastActivity = event.timestamp
            conversation.lastMessagePreview = Self.text(of: event)
        }
    }

    /// Names a conversation that has no name of its own, using the people in it.
    private func nameIfNeeded(_ conversation: Conversation, heroes: [String]?) {
        guard conversation.name == nil, let heroes, !heroes.isEmpty else { return }

        let names = heroes.map { String(BridgeIdentity.localpart(of: $0)) }
        conversation.name = names.joined(separator: ", ")

        if conversation.network == .matrix, let first = heroes.first {
            conversation.network = BridgeIdentity.network(of: first)
        }
    }


    // MARK: - Store access

    /// Which device this is, and the behaviour that follows from it.
    public var deviceProfile: DeviceProfile { profile }

    func insert(_ model: some PersistentModel) {
        context.insert(model)
    }

    /// Takes a message out of its conversation, and puts the conversation's last line right
    /// if it was the newest.
    ///
    /// One place for this, because there were two ways to lose a message and only one of
    /// them fixed the line. Deleting your own newest message did not: the preview kept its
    /// text, and when the server's confirmation came back through the sync the message was
    /// already gone, so that repair never ran either. The deleted words sat in the list
    /// until somebody wrote something new.
    func remove(_ message: Message, from conversation: Conversation) {
        let removed = message.id
        let wasNewest = message.timestamp >= conversation.lastActivity
        context.delete(message)
        guard wasNewest else { return }

        // One indexed query for the newest one left, rather than loading the room.
        let room = conversation.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversation?.id == room && $0.id != removed },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        conversation.lastMessagePreview = (try? context.fetch(descriptor).first)?.body ?? ""
    }

    /// The message a reaction was given to, found by the reaction's own event.
    ///
    /// Reactions live in a string on the message they belong to, so this is a search of
    /// that string within one room — only ever run when something is taken back that is not
    /// a message, which is rare.
    func message(holdingReaction event: String, in conversation: Conversation) -> Message? {
        let room = conversation.id
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> {
                $0.conversation?.id == room && $0.reactionsBlob.contains(event)
            }
        )
        return (try? context.fetch(descriptor))?.first { $0.holdsReaction(event: event) }
    }

    func delete(_ model: some PersistentModel) {
        context.delete(model)
    }

    /// Records what a participant is called and what they look like.
    ///
    /// Kept across launches. Sync sends membership only for rooms that changed, so a name
    /// learned once would otherwise be gone the next morning — leaving a group of unnamed,
    /// faceless lines until someone happened to speak again.
    func note(_ member: String, name: String?, avatar: String?) {
        if let name, !name.isEmpty, memberNames[member] != name {
            memberNames[member] = name
            memberDetailsChanged = true
        }

        if let avatar, !avatar.isEmpty {
            if memberAvatars[member] != avatar {
                memberAvatars[member] = avatar
                memberDetailsChanged = true
            }
        } else if memberAvatars[member] == nil {
            // "Asked, and there is none" is an answer worth keeping: without it the same
            // fruitless request is made on every launch. A picture already known is never
            // cleared this way — a membership event that leaves the field out isn't proof
            // it's gone.
            memberAvatars[member] = ""
            memberDetailsChanged = true
        }
    }

    private struct MemberDetails: Codable {
        var names: [String: String]
        var avatars: [String: String]
    }

    private func restoreMemberDetails() {
        guard let data = defaults.data(forKey: Keys.memberDetails),
              let stored = try? JSONDecoder().decode(MemberDetails.self, from: data)
        else { return }

        memberNames = stored.names
        memberAvatars = stored.avatars
    }

    func saveMemberDetails() {
        guard memberDetailsChanged else { return }
        memberDetailsChanged = false

        let details = MemberDetails(names: memberNames, avatars: memberAvatars)
        guard let data = try? JSONEncoder().encode(details) else { return }
        defaults.set(data, forKey: Keys.memberDetails)
    }

    func saveContext() {
        try? context.save()
    }

    /// Looks up a conversation by room ID.
    /// The chats with the most recent activity, newest first, leaving out what's hidden. For
    /// places outside the app that offer a short list to pick from, like Shortcuts.
    public func recentConversations(limit: Int) -> [Conversation] {
        var descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.lastActivity, order: .reverse)]
        )
        descriptor.fetchLimit = limit * 2
        let all = (try? container.mainContext.fetch(descriptor)) ?? []
        return Array(all.filter { !isHidden($0) }.prefix(limit))
    }

    public func conversation(withID id: String) -> Conversation? {
        conversation(id: id)
    }

    /// Adds a message loaded from history.
    ///
    /// Unlike a newly arrived message this must not move the conversation to the top of the
    /// list: it's older than what's already there, and scrolling back through a conversation
    /// shouldn't reorder the list you came from.
    func addHistoricalMessage(_ event: MatrixEvent, to conversation: Conversation) {
        guard message(id: event.id) == nil else { return }

        let message = Self.makeMessage(from: event, senderName: nil)

        message.conversation = conversation
        context.insert(message)
        applyKnownReceipts(to: message, in: conversation)

        // History fetched after the fact still counts. Without this a conversation whose
        // messages arrived through a later request keeps the date it was created with, and
        // sinks to the bottom of the list no matter how recent it really is.
        if event.timestamp > conversation.lastActivity {
            conversation.lastActivity = event.timestamp
            conversation.lastMessagePreview = Self.text(of: event)
        }
    }

    // MARK: - Lookups

    private func conversation(id: String) -> Conversation? {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Whether anything is stored for a conversation. One counted row, not the whole room.
    func hasStoredMessages(_ conversation: Conversation) -> Bool {
        let room = conversation.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversation?.id == room }
        )
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Whether an account lives on the same server as yours.
    func isOnOwnServer(_ account: String) -> Bool {
        guard let mine = credentials?.userID,
              let own = mine.firstIndex(of: ":"),
              let theirs = account.firstIndex(of: ":")
        else { return false }
        return mine[mine.index(after: own)...] == account[account.index(after: theirs)...]
    }

    func message(id: String) -> Message? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

extension MatrixEvent.Content {
    /// The stored kind for this content, for the cases that become messages.
    var messageKind: Message.Kind {
        switch self {
        case .text: .text
        case .emote: .emote
        case .notice: .notice
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .file: .file
        case .encrypted: .encrypted
        case .sticker: .sticker
        case .poll: .poll
        default: .text
        }
    }

    var media: MatrixEvent.Media? {
        switch self {
        case .image(let media), .video(let media), .audio(let media), .file(let media),
             .sticker(let media):
            media
        default:
            nil
        }
    }
}
