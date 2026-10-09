import Foundation

/// Connecting a chat account, as a screen rather than a conversation.
///
/// Every Matrix client makes you find a bridge's bot, open a chat with it and type `login`.
/// That's a leak: the bot is an implementation detail of how bridges are built, not something
/// anyone signed up for. This walks the same process over the bridge's HTTP interface and
/// reduces the whole thing to one thing on screen — a code to scan.
///
/// The process is a loop by design. The bridge hands back one step at a time and the client
/// keeps asking for the next, so a network that needs two codes, or a code and then a
/// confirmation, needs no special handling here.
@MainActor
@Observable
public final class BridgeLogin {

    /// What the person should be looking at.
    public enum Stage: Equatable {
        case preparing
        /// Scan this. The string is what the QR code must contain.
        case scan(String)
        /// Type these in. The bridge decides what they are.
        case form(MatrixAPI.BridgeLoginStep.UserInput)
        /// Sign in on the network's own page, and hand back what it leaves behind.
        case website(MatrixAPI.BridgeLoginStep.Cookies)
        /// Type this into the network's own app — a pairing code, or emoji to compare.
        case showCode(String)
        /// Scanned or submitted; the bridge is finishing up.
        case finishing
        case done
        case failed(String)

        public static func == (lhs: Stage, rhs: Stage) -> Bool {
            switch (lhs, rhs) {
            case (.preparing, .preparing), (.finishing, .finishing), (.done, .done):
                true
            case (.scan(let a), .scan(let b)), (.showCode(let a), .showCode(let b)):
                a == b
            case (.failed(let a), .failed(let b)):
                a == b
            case (.form(let a), .form(let b)):
                a.fields == b.fields
            case (.website(let a), .website(let b)):
                a.url == b.url && a.fields == b.fields
            default:
                false
            }
        }
    }

    public private(set) var stage: Stage = .preparing

    /// The bridge's own wording for the current step, when it gave any.
    public private(set) var instructions: String?

    /// The other ways into this network, when there is more than one.
    ///
    /// Not a question asked up front. WhatsApp takes a scanned code or a pairing code typed
    /// into the phone, and asking which every single time would put a screen in front of the
    /// answer almost everybody wants. So the best one starts, and this is what the screen
    /// offers underneath it for the people the other one suits better.
    public private(set) var alternatives: [MatrixAPI.BridgeLoginFlow] = []

    /// Set when someone picked one of those, so starting over doesn't undo the choice.
    private var forcedFlow: String?

    public let network: ChatNetwork

    private let api: MatrixAPI
    private let userID: String
    private var task: Task<Void, Never>?

    public init(api: MatrixAPI, network: ChatNetwork, userID: String) {
        self.api = api
        self.network = network
        self.userID = userID
    }

    /// Runs the login from the beginning.
    public func start() {
        pending?.resume(returning: [:])
        pending = nil
        task?.cancel()
        stage = .preparing
        instructions = nil

        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops waiting and tells the bridge to forget the attempt.
    public func cancel() {
        pending?.resume(returning: [:])
        pending = nil
        task?.cancel()
        task = nil
    }

    // MARK: - The loop

    /// What the screen is waiting to hand back, once someone has filled it in.
    private var pending: CheckedContinuation<[String: String], Never>?

    /// Called by the screen when a form has been filled in, or a website has given up its
    /// cookies. Anything already waiting on it carries on from there.
    public func submit(_ values: [String: String]) {
        let waiting = pending
        pending = nil
        stage = .finishing
        waiting?.resume(returning: values)
    }

    /// Starts again using one of the other ways in.
    public func use(_ flow: MatrixAPI.BridgeLoginFlow) {
        forcedFlow = flow.id
        start()
    }

    private func run() async {
        do {
            let flow = try await chooseFlow()
            var step = try await api.startBridgeLogin(flow: flow, as: userID, on: network)

            while !Task.isCancelled {
                instructions = step.instructions

                switch step.kind {
                case .complete:
                    stage = .done
                    return

                case .displayAndWait:
                    guard let display = step.displayAndWait else {
                        stage = .failed(String(localized: "The bridge asked to show something but sent nothing.", bundle: .module))
                        return
                    }

                    present(display)

                    do {
                        step = try await api.awaitBridgeLoginStep(
                            loginID: step.loginID, stepID: step.stepID,
                            as: userID, on: network
                        )
                    } catch let error as MatrixError where isTimeout(error) {
                        // The code went stale before anyone scanned it. Starting over is the
                        // right answer, and it's what the person would do by hand anyway.
                        guard !Task.isCancelled else { return }
                        stage = .preparing
                        step = try await api.startBridgeLogin(flow: flow, as: userID, on: network)
                    }

                case .userInput:
                    guard let form = step.userInput, !form.fields.isEmpty else {
                        stage = .failed(String(localized: "The bridge asked a question with nothing in it.", bundle: .module))
                        return
                    }

                    stage = .form(form)
                    let answers = await waitForInput()
                    guard !Task.isCancelled else { return }

                    step = try await api.submitBridgeLoginInput(
                        loginID: step.loginID, stepID: step.stepID,
                        values: answers, as: userID, on: network
                    )

                case .cookies:
                    guard let cookies = step.cookies else {
                        stage = .failed(String(localized: "The bridge asked for a sign-in page but sent no address.", bundle: .module))
                        return
                    }

                    stage = .website(cookies)
                    let collected = await waitForInput()
                    guard !Task.isCancelled else { return }

                    step = try await api.submitBridgeLoginCookies(
                        loginID: step.loginID, stepID: step.stepID,
                        values: collected, as: userID, on: network
                    )

                default:
                    // Client-side HTTP and WebAuthn are the two nobody's bridge asks for yet.
                    // Saying so beats leaving someone on a blank screen.
                    stage = .failed(String(localized: "This account needs a kind of sign-in Chatman can't show yet.", bundle: .module))
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            stage = .failed(error.localizedDescription)
        }
    }

    /// Hands control to the screen until someone has answered.
    private func waitForInput() async -> [String: String] {
        await withCheckedContinuation { continuation in
            pending = continuation
        }
    }

    private func chooseFlow() async throws -> String {
        let flows = try await api.bridgeLoginFlows(as: userID, on: network)

        guard !flows.isEmpty else {
            throw MatrixError.decoding(String(localized: "The bridge offers no way to sign in.", bundle: .module))
        }

        // Scanning a code from another device beats typing a password into a third-party app,
        // so that's what starts — but which is easier depends on what's in your hand, and on
        // a phone with no second device the code is the useless option. Hence the rest are
        // kept and offered.
        let ordered = flows.sorted { rank($0) < rank($1) }
        let chosen = forcedFlow.flatMap { id in ordered.first { $0.id == id } } ?? ordered[0]

        alternatives = ordered.filter { $0.id != chosen.id }

        return chosen.id
    }

    /// How highly to place a way of signing in. Lower comes first.
    private func rank(_ flow: MatrixAPI.BridgeLoginFlow) -> Int {
        let id = flow.id.lowercased()
        if id.contains("qr") { return 0 }
        if id.contains("phone") || id.contains("sms") { return 1 }
        if id.contains("password") || id.contains("app_password") { return 2 }
        if id.contains("cookie") || id.contains("browser") { return 3 }
        return 4
    }

    private func present(_ display: MatrixAPI.BridgeLoginStep.DisplayAndWait) {
        switch display.type {
        case .qr:
            if let data = display.data, !data.isEmpty {
                stage = .scan(data)
            } else {
                stage = .failed(String(localized: "The bridge sent an empty code.", bundle: .module))
            }

        case .code, .emoji:
            // Something for you to type into the network's app. It used to go the same way as
            // "nothing", straight to "Connecting…", with the code itself thrown away — so a
            // WhatsApp sign-in by phone number, the way in for anyone without a second device
            // to scan from, waited for a code nobody had been shown and could never finish.
            if let data = display.data, !data.isEmpty {
                stage = .showCode(data)
            } else {
                stage = .finishing
            }

        case .nothing:
            // Nothing to scan; the bridge is doing the waiting.
            stage = .finishing
        }
    }

    private func isTimeout(_ error: MatrixError) -> Bool {
        guard case .network(let urlError) = error else { return false }
        return urlError.code == .timedOut
    }
}
