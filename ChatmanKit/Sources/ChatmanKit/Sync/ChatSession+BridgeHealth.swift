import Foundation
import SwiftData

/// Whether the bridges are still bridging, said where you'd see it.
///
/// A WhatsApp that was logged out three days ago looks exactly like a quiet WhatsApp: no new
/// messages, no error, nothing. That is the typical way a bridge set-up fails, and the status
/// used to be visible only inside Settings. Now a bridge that needs you is a line at the top
/// of the list, on the phone and on the watch.
extension ChatSession {

    /// A bridge that stopped passing messages on, and why.
    public struct BridgeProblem: Identifiable, Hashable, Sendable {
        public let network: ChatNetwork
        /// The bridge's own words, when it gave any.
        public let detail: String?
        /// Whether the bridge itself didn't answer, rather than answering that the account
        /// is signed out.
        public var isUnanswered = false
        public var id: String { network.rawValue }
    }

    private static let connectedKey = "chatman.connectedNetworks"
    private static let forgottenKey = "chatman.forgottenNetworks"
    private static let reconnectingKey = "chatman.reconnectingSince"

    /// How long a bridge may say it is reconnecting before that counts as stuck.
    static let reconnectingPatience: TimeInterval = 10 * 60

    /// When each bridge was first seen reconnecting, without being seen connected since.
    ///
    /// Kept across launches: "reconnecting" since yesterday evening is a bridge that isn't
    /// coming back by itself, and a fresh launch shouldn't start that count again.
    var reconnectingSince: [ChatNetwork: Date] {
        get {
            let stored = defaults.dictionary(forKey: Self.reconnectingKey) as? [String: Double] ?? [:]
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                ChatNetwork(rawValue: key).map { ($0, Date(timeIntervalSince1970: value)) }
            })
        }
        set {
            defaults.set(
                Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }),
                forKey: Self.reconnectingKey
            )
        }
    }

    /// Notes which bridges are reconnecting now, and since when. Called after every look.
    func noteReconnecting() {
        var since = reconnectingSince
        for network in ChatNetwork.allCases {
            if case .reconnecting = bridgeAccounts[network]?.status {
                if since[network] == nil { since[network] = .now }
            } else if bridgeAccounts[network] != nil {
                since[network] = nil
            }
        }
        if since != reconnectingSince { reconnectingSince = since }
    }

    /// Networks let go of on purpose. See `forget`.
    private var forgotten: Set<ChatNetwork> {
        get {
            Set((defaults.stringArray(forKey: Self.forgottenKey) ?? []).compactMap(ChatNetwork.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.forgottenKey)
        }
    }

    /// Networks that have been connected at some point, so one that has quietly lost its
    /// login is told apart from one that was never set up.
    var everConnected: Set<ChatNetwork> {
        get {
            Set((defaults.stringArray(forKey: Self.connectedKey) ?? []).compactMap(ChatNetwork.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Self.connectedKey)
        }
    }

    /// Every bridge that needs you, in a steady order.
    ///
    /// Only the ones that won't mend themselves. A bridge reconnecting after a blip is
    /// retrying on its own and will be fine in a minute; saying so would be a warning that
    /// teaches you to ignore warnings.
    ///
    /// And every network you have used that has gone quiet in a way that won't fix itself:
    /// signed out, or no login at all any more, or a bridge that doesn't answer. Those used to
    /// be told apart from "never set up" only when the bridge answered — so a WhatsApp whose
    /// bridge was in trouble simply vanished from the settings and said nothing, which is the
    /// one way of failing this whole check exists to catch.
    public var bridgeProblems: [BridgeProblem] {
        var problems: [BridgeProblem] = []
        let used = everConnected

        for network in ChatNetwork.allCases {
            if used.contains(network), unansweredNetworks.contains(network) {
                // Checked before the account below, which is whatever the bridge said last
                // time it answered and may well still say "connected".
                problems.append(BridgeProblem(
                    network: network,
                    detail: String(localized: "The \(network.displayName) bridge on your server isn't answering. Nothing arrives from \(network.displayName) until it does.", bundle: .module),
                    isUnanswered: true
                ))
            } else if let account = bridgeAccounts[network] {
                switch account.status {
                case .loggedOut(let detail), .failed(let detail):
                    problems.append(BridgeProblem(network: network, detail: detail))
                case .reconnecting:
                    // Retrying on its own is no news for a few minutes. For longer than that
                    // it isn't mending itself, and nothing arrives while it tries.
                    if let since = reconnectingSince[network],
                       Date.now.timeIntervalSince(since) > Self.reconnectingPatience {
                        let when = since.formatted(date: .omitted, time: .shortened)
                        problems.append(BridgeProblem(
                            network: network,
                            detail: String(localized: "Trying to reconnect since \(when). Nothing arrives from \(network.displayName) until it does.", bundle: .module),
                            isUnanswered: false
                        ))
                    }
                case .connected, .connecting:
                    break
                }
            } else if installedNetworks.contains(network), used.contains(network) {
                // The bridge answered and has no login for you any more.
                problems.append(BridgeProblem(network: network, detail: nil))
            }
        }

        return problems
    }

    /// What the app knows about one bridge, for the settings: plainly, without interpretation.
    public struct BridgeDiagnosis: Identifiable, Sendable {
        public let network: ChatNetwork
        public let answer: BridgeAnswer?
        public let hasAccount: Bool
        public let isUsed: Bool
        public let isMissing: Bool
        /// When it was asked, while its answer is still out.
        public let askingSince: Date?
        public var id: String { network.rawValue }
    }

    /// Every bridge that answered, is being asked, has an account or is in use.
    ///
    /// The raw facts the rest of this file reasons from. When a bridge is in trouble and the
    /// app says something odd about it, this is what tells which of the two got it wrong.
    public var bridgeDiagnoses: [BridgeDiagnosis] {
        let used = everConnected
        return Self.configurableNetworks.compactMap { network in
            let answer = bridgeAnswers[network]
            let asking = bridgeQuestions[network]
            guard answer != nil || asking != nil || used.contains(network) || bridgeAccounts[network] != nil
            else { return nil }
            return BridgeDiagnosis(
                network: network,
                answer: answer,
                hasAccount: bridgeAccounts[network] != nil,
                isUsed: used.contains(network),
                isMissing: missingNetworks.contains(network),
                askingSince: asking
            )
        }
    }

    /// Stops counting a network as one you use, so its absence is no longer a problem.
    ///
    /// For an account signed out on purpose somewhere else: without this, a WhatsApp you meant
    /// to stop using would be reported as disconnected for ever.
    public func forget(_ network: ChatNetwork) {
        everConnected.remove(network)
        forgotten.insert(network)
        bridgeAccounts[network] = nil
        unansweredNetworks.remove(network)
    }

    /// Asks the bridges again in half a minute when one you use didn't answer.
    ///
    /// A bridge being restarted doesn't answer for a few seconds, and the next ordinary look
    /// is five minutes away: a warning for a blip would stand all that time. Asking once more
    /// soon takes it down again as soon as the bridge is back — and confirms it when it isn't.
    ///
    /// Once per ordinary look, not again and again: a bridge that is really down is said to be
    /// down, and asked about again with everything else five minutes later.
    func recheckSoonIfUnanswered() {
        guard !isRecheckScheduled,
              Date.now.timeIntervalSince(lastQuickRecheck) > 4 * 60,
              !unansweredNetworks.isDisjoint(with: everConnected)
        else { return }
        isRecheckScheduled = true
        lastQuickRecheck = .now

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self else { return }
            isRecheckScheduled = false
            await refreshBridges()
        }
    }

    /// Remembers which networks have a login now. Called after every look at the bridges.
    ///
    /// And every network there are chats from. A WhatsApp you have conversations with is a
    /// WhatsApp you use, whatever its bridge has or hasn't said since this list was started —
    /// which is the difference between a disconnected WhatsApp saying so and saying nothing.
    func noteConnectedNetworks() {
        let signedIn = Set(bridgeAccounts.keys)

        // Signing in again takes back letting it go.
        let letGo = forgotten
        if !signedIn.isDisjoint(with: letGo) {
            forgotten = letGo.subtracting(signedIn)
        }

        let used = signedIn.union(networksWithChats()).subtracting(forgotten)
        let known = everConnected
        if !used.isSubset(of: known) {
            everConnected = known.union(used)
        }
    }

    /// The bridged networks there are conversations from.
    private func networksWithChats() -> Set<ChatNetwork> {
        let conversations = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []
        return Set(conversations.map(\.network)).intersection(Self.configurableNetworks)
    }

    /// A bridge bot said something: look at the bridges again, now rather than in five minutes.
    ///
    /// Bots speak when something changed — "you were logged out", "reconnected", "this message
    /// couldn't be sent". What they say isn't read; that they spoke is reason enough to ask.
    func noteBridgeSpoke() {
        // At most once a minute: a chatty bot in a busy hour shouldn't mean a round of
        // fourteen requests for every line it posts.
        guard hasSyncedBefore, !isRecheckingBridges,
              Date.now.timeIntervalSince(lastBridgeCheck) > 60
        else { return }
        isRecheckingBridges = true

        Task {
            await refreshBridges()
            lastBridgeCheck = .now
            isRecheckingBridges = false
        }
    }
}
