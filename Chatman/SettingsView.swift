import SwiftUI
import ChatmanKit
import PhotosUI

struct SettingsView: View {
    @Environment(ChatSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var isConfirmingSignOut = false

    /// The services with an account on them, in the order they're offered — and the ones you
    /// use that have lost theirs, which stay here saying so rather than disappearing as if
    /// they had never been set up.
    private var connected: [ChatNetwork] {
        let troubled = Set(session.bridgeProblems.map(\.network))
        return ChatSession.configurableNetworks.filter {
            session.bridgeAccounts[$0] != nil || troubled.contains($0)
        }
    }

    var body: some View {
        @Bindable var session = session

        // The sign-off is stacked over the whole screen rather than inset into it: an inset
        // is placed above the home indicator by definition, and that gap is exactly what he
        // is supposed to be peeking over.
        return NavigationStack {
            Form {
                // Who you are and where, as one card at the top — the way the system's own
                // Settings opens with your name rather than two rows of labels.
                if let credentials = session.credentials {
                    Section {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(Monogram.gradient(for: credentials.userID))
                                .frame(width: 52, height: 52)
                                .overlay {
                                    Text(String(credentials.userID.dropFirst().prefix(1)).uppercased())
                                        .font(.title2.weight(.semibold))
                                        .fontDesign(.rounded)
                                        .foregroundStyle(.white)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credentials.userID.dropFirst().prefix { $0 != ":" })
                                    .font(.title3.weight(.semibold))
                                Text(credentials.homeserver.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                    }
                }

                Section {
                    ForEach(connected, id: \.self) { network in
                        NavigationLink {
                            AccountView(network: network)
                        } label: {
                            AccountRow(
                                network: network,
                                account: session.bridgeAccounts[network],
                                problem: session.bridgeProblems.first { $0.network == network }
                            )
                        }
                    }

                    NavigationLink {
                        NetworkPicker()
                    } label: {
                        Label("Add an account", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text(connected.isEmpty
                         ? "Connect a service your server has a bridge for."
                         : "Tap an account to see how it is doing.")
                }
                .task { await session.refreshBridges() }

                Section {
                    NavigationLink {
                        BackgroundSettings()
                    } label: {
                        LabeledContent("Background", value: session.backdrop.displayName)
                    }

                    Picker("Typeface", selection: $session.typeface) {
                        ForEach(Typeface.allCases, id: \.self) { face in
                            Text(face.displayName).tag(face)
                        }
                    }

                    Toggle("Always dark", isOn: $session.forcesDarkMode)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Light sets names and messages in a thinner weight.")
                }

                Section {
                    Picker("Photos you take", selection: $session.photoQuality) {
                        ForEach(PhotoQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                } header: {
                    Text("Sending")
                } footer: {
                    Text(verbatim: session.photoQuality.explanation + "\n\n")
                        + Text("Photos from your library are always sent unchanged.")
                }

                Section {
                    Toggle("Notifications", isOn: Binding(
                        get: { session.wantsNotifications },
                        set: { wanted in
                            session.wantsNotifications = wanted
                            guard wanted else {
                                // Off means off: the server stops sending, and so does Apple.
                                UIApplication.shared.unregisterForRemoteNotifications()
                                Task { await session.unregisterForPush() }
                                return
                            }
                            Task { await PushRegistrar.enable() }
                        }
                    ))

                    .disabled(session.pushGateway.isEmpty && !session.wantsNotifications)
                } header: {
                    Text("Notifications")
                } footer: {
                    if session.pushGateway.isEmpty {
                        Text("Notifications need a push gateway on your server, set under Advanced. Until then Chatman fetches messages while it's open.")
                    } else if let detail = session.pushState.detail {
                        Text(detail)
                    }
                }

                Section {
                    NavigationLink {
                        AdvancedView()
                    } label: {
                        Text("Advanced")
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        isConfirmingSignOut = true
                    }
                } footer: {
                    // Under the last section, in the scrolling content: never over a row. He
                    // used to stand at the bottom edge of the screen over every settings
                    // screen, where he covered half of whatever row was lowest.
                    HStack(alignment: .bottom, spacing: 8) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Chatman, supersnel op MSN")
                            Text(verbatim: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")
                                .monospacedDigit()
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                        ChatmanPeek()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // No `navigationDestination` for networks: every way into the connect screen is a
            // link that carries its own destination. The two kinds mixed in one stack — a
            // screen pushed as a view, a link inside it pushed as a value — is what made
            // "Add an account" jump on by a screen and leave another one behind it.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Sign out of Chatman?",
                isPresented: $isConfirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    Task {
                        await session.signOut()
                        dismiss()
                    }
                }
            } message: {
                Text("Your conversations stay on your server. This device downloads them again next time you sign in.")
            }
        }

        // Again here, and not only at the root of the app.
        //
        // This screen arrives as a sheet, and a sheet is its own presentation: the root's
        // choice reaches it when it opens and then stops listening. So the switch that turns
        // the app dark left the screen you flipped it on exactly as it was — the one screen
        // where you are certain to be looking.
        .preferredColorScheme(session.forcesDarkMode ? .dark : nil)
    }

}

/// What a connected account is doing, and how to get out of it.
///
/// Tapping a service you have already connected used to open the screen that connects one —
/// a code to scan for an account that is signed in perfectly well. What you actually want to
/// know at that moment is whether it's still working.
private struct AccountView: View {
    @Environment(ChatSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let network: ChatNetwork

    @State private var isConfirmingForget = false

    private var account: ChatSession.BridgeAccount? { session.bridgeAccounts[network] }

    /// What is wrong, when the bridge said nothing about an account — or nothing at all.
    private var problem: ChatSession.BridgeProblem? {
        session.bridgeProblems.first { $0.network == network }
    }

    var body: some View {
        @Bindable var session = session

        return Form {
            Section {
                LabeledContent("Service", value: network.displayName)

                if let name = account?.name, !name.isEmpty {
                    LabeledContent("Account", value: name)
                }

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(indicator)
                            .frame(width: 8, height: 8)
                        Text(status)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    NetworkBadge(network: network, size: 22)
                    Text("Connection")
                }
                .textCase(nil)
            } footer: {
                // And what the bridge itself last said, so a bridge in trouble can be told
                // apart from an app in trouble without a computer.
                VStack(alignment: .leading, spacing: 4) {
                    if let detail, !detail.isEmpty {
                        Text(detail)
                    }
                    if let answer = session.bridgeAnswers[network] {
                        Text("\(answer.summary) · \(answer.at.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2.monospaced())
                    }
                }
            }

            if network == .whatsapp {
                Section {
                    Toggle("Hide status updates", isOn: $session.hidesStatusUpdates)
                } footer: {
                    Text("WhatsApp collects everybody's status posts in one chat. Hidden means hidden: out of both lists, out of the count on your watch, and muted on your server.")
                }
            }

            if needsAttention {
                Section {
                    NavigationLink {
                        BridgeSetupView(network: network)
                    } label: {
                        Label("Connect again", systemImage: "arrow.clockwise")
                    }
                } footer: {
                    Text("Signs in to \(network.displayName) again, the same way you did the first time.")
                }
            }

            Section {
                NavigationLink {
                    BridgeSetupView(network: network)
                } label: {
                    Label("Add another account", systemImage: "plus")
                }
            }

            // For an account signed out on purpose: without a way to say so, it would be
            // reported as disconnected for as long as the app is installed.
            if account == nil, problem != nil {
                Section {
                    Button("Stop Using \(network.displayName)", role: .destructive) {
                        isConfirmingForget = true
                    }
                } footer: {
                    Text("Only if you signed out on purpose. Chatman stops warning about it; your chats stay where they are.")
                }
            }
        }
        .confirmationDialog(
            "Stop using \(network.displayName) in Chatman?",
            isPresented: $isConfirmingForget,
            titleVisibility: .visible
        ) {
            Button("Stop Using \(network.displayName)", role: .destructive) {
                session.forget(network)
                dismiss()
            }
        }
        .navigationTitle(network.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.refreshBridges() }
    }

    private var status: String {
        if problem?.isUnanswered == true { return "Not answering" }
        return switch account?.status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .loggedOut: "Signed out"
        case .failed: "Not working"
        case nil: problem == nil ? "Not connected" : "Disconnected"
        }
    }

    private var detail: String? {
        if let problem {
            return problem.detail
                ?? "Nothing arrives from \(network.displayName) until it's connected again."
        }
        switch account?.status {
        case .loggedOut(let message), .failed(let message): return message
        case .connected: return "Messages are coming through."
        default: return nil
        }
    }

    private var indicator: Color {
        if problem != nil { return .red }
        switch account?.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .loggedOut, .failed: return .red
        case nil: return .secondary
        }
    }

    private var needsAttention: Bool {
        switch account?.status {
        case .loggedOut, .failed, nil: true
        default: false
        }
    }
}

/// The one thing that differs between servers and can't be guessed.
///
/// Chatman finds a bridge at `/bridge/<network>/` because that's how the stack it ships with
/// routes them. Somebody else's server may do it differently, and there is no standard to
/// fall back on — so rather than a rewrite, it's a line of text, tucked away where nobody who
/// doesn't need it will ever meet it.
private struct AdvancedView: View {
    @Environment(ChatSession.self) private var session

    @State private var path = MatrixAPI.bridgePathTemplate

    var body: some View {
        Form {
            Section {
                TextField(MatrixAPI.defaultBridgePath, text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: path) { _, new in
                        MatrixAPI.bridgePathTemplate = new
                    }

                if path != MatrixAPI.defaultBridgePath {
                    Button("Reset") {
                        path = MatrixAPI.defaultBridgePath
                        MatrixAPI.bridgePathTemplate = MatrixAPI.defaultBridgePath
                    }
                }
            } header: {
                Text("Where the bridges live")
            } footer: {
                Text("The path where each bridge answers, with {network} standing in for signal, whatsapp and the rest. Change it only if your server routes them differently.")
            }

            Section {
                TextField(
                    "https://matrix.example.com/_matrix/push/v1/notify",
                    text: Binding(
                        get: { session.pushGateway },
                        set: { session.pushGateway = $0 }
                    )
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                // Registered as soon as it's entered. It used to wait for the next launch:
                // registering only ever happened when Apple handed over a token, and with the
                // gateway still empty at that moment it was skipped — so switching
                // notifications on first and filling this in second gave silence until the
                // app was restarted.
                .onSubmit {
                    guard session.wantsNotifications else { return }
                    Task { await PushRegistrar.enable() }
                }
            } header: {
                Text("Push gateway")
            } footer: {
                Text("The address of the push gateway on your server. Without one, Chatman fetches messages only while it is open.")
            }

            Section {
                Text(session.contactMatchingSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !session.unmatchedConversations.isEmpty {
                    DisclosureGroup("Not matched (\(session.unmatchedConversations.count))") {
                        ForEach(session.unmatchedConversations, id: \.self) { name in
                            Text(name)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.footnote)
                }
            } header: {
                Text("Names from your contacts")
            } footer: {
                Text("Names are matched to your address book by phone number.")
            }

            // A log, not a setting: what each bridge last answered, on a page of its own.
            Section {
                NavigationLink("Bridge Diagnostics") {
                    BridgeDiagnosticsView()
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .task { await session.applyDeviceContacts() }
    }
}

/// Everything this server can bridge.
///
/// All of them are listed, not only the ones installed, because a server gains a bridge by
/// deploying a container and the app has no way to be told about it other than asking. What
/// it does say is which ones answered — tapping a service that isn't there would otherwise
/// end in a spinner and no explanation.
private struct NetworkPicker: View {
    @Environment(ChatSession.self) private var session

    @State private var isAskingAboutMSN = false

    private var available: [ChatNetwork] {
        ChatSession.configurableNetworks.filter { session.isInstalled($0) }
    }

    private var rest: [ChatNetwork] {
        ChatSession.configurableNetworks.filter { !session.isInstalled($0) }
    }

    var body: some View {
        List {
            if !available.isEmpty {
                Section("On your server") {
                    ForEach(available, id: \.self) { network in
                        NavigationLink {
                            BridgeSetupView(network: network)
                        } label: {
                            NetworkRow(network: network)
                        }
                    }
                }
            }

            if !rest.isEmpty {
                Section {
                    // Tappable, even though nothing here answers yet. Somebody testing this
                    // has their own server with their own bridges, and a row they can't
                    // press is a row that can't be tested.
                    ForEach(rest, id: \.self) { network in
                        NavigationLink {
                            BridgeSetupView(network: network)
                        } label: {
                            NetworkRow(network: network)
                        }
                        .foregroundStyle(.secondary)
                    }

                    Button { isAskingAboutMSN = true } label: {
                        HStack(spacing: 10) {
                            // The one badge that isn't a real network. Drawn by hand, in the
                            // green everybody who used it still remembers.
                            Text("M")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Color(red: 0.29, green: 0.65, blue: 0.11), in: Circle())

                            Text("MSN Messenger")
                        }
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text(available.isEmpty ? "Services" : "Not on your server yet")
                } footer: {
                    Text("Available once the matching bridge runs on your server.")
                }
            }
        }
        .navigationTitle("Add an account")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAskingAboutMSN) { MSNRegrets() }
        .task { await session.refreshBridges() }
    }
}

/// What Chatman has to say about MSN.
///
/// He is, after all, the man who was supersnel op MSN — it's the only thing the character was
/// ever famous for, and the app is named after him. Someone will tap it hoping. This is the
/// kindest possible no.
private struct MSNRegrets: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Text("MSN Messenger")
                    .chatmanFont(size: 20, weight: .semibold, relativeTo: .title3)

                Text("""
                Chatman would love this one back. He was supersnel op MSN — it said so on \
                every poster — and he has been refreshing his contact list since 2013.

                There is no bridge for it, because there is nothing left on the other side to \
                bridge to. Sorry.
                """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Text("*nudge*")
                    .font(.footnote.italic())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Him, over the bottom edge, looking exactly as hopeful as the text.
            Image("chatman-peek")
                .resizable()
                .scaledToFit()
                .frame(height: 130)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .padding(10)
            }
            .buttonStyle(.plain)
            .chatmanGlass(in: .circle, interactive: true)
            .padding()
        }
    }
}

private struct NetworkRow: View {
    let network: ChatNetwork

    var body: some View {
        HStack(spacing: 10) {
            NetworkBadge(network: network, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(network.displayName)

                // Said once, here, rather than in a warning on every screen afterwards.
                if !network.isSupported {
                    Text("Not tried yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// One connected service, and whether it's actually working.
///
/// Showing only "Connect" was the thing that hid a bridge sitting logged out for hours while
/// everything looked fine. A row that never changes teaches people to stop reading it.
private struct AccountRow: View {
    let network: ChatNetwork
    let account: ChatSession.BridgeAccount?
    var problem: ChatSession.BridgeProblem?

    var body: some View {
        HStack(spacing: 10) {
            NetworkBadge(network: network, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(network.displayName)
                    .foregroundStyle(.primary)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(action)
                .foregroundStyle(needsAttention ? .orange : .secondary)
        }
    }

    private var detail: String? {
        if problem?.isUnanswered == true { return "Not answering — your server's bridge" }
        if account == nil, problem != nil { return "Disconnected — connect again" }

        switch account?.status {
        case .connected:
            return account?.name.map { "Connected · \($0)" } ?? "Connected"
        case .connecting:
            return "Connecting…"
        case .reconnecting:
            return "Reconnecting…"
        case .loggedOut(let message):
            return message ?? "Signed out — connect again"
        case .failed(let message):
            return message ?? "Something went wrong"
        case nil:
            return nil
        }
    }

    private var action: String {
        if needsAttention { return "Fix" }
        return account == nil ? "Connect" : ""
    }

    private var needsAttention: Bool {
        if problem != nil { return true }
        switch account?.status {
        case .loggedOut, .failed: return true
        default: return false
        }
    }
}

/// The ten colours the backdrop can be lit in.
///
/// A row of what they actually look like rather than a list of their names. "Brown" and
/// "orange" are the same word to most people until they are side by side, and no wording
/// settles that argument as fast as two circles next to each other.
private struct BackdropColours: View {
    @Binding var chosen: BackdropColour

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 60), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(BackdropColour.allCases, id: \.self) { colour in
                    Button {
                        // Springy, because choosing a colour is the one thing on this screen
                        // that is pure pleasure. Everything else here is a setting.
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) {
                            chosen = colour
                        }
                    } label: {
                        swatch(colour)
                    }
                    .buttonStyle(.chatmanPress)
                    .accessibilityLabel(colour.displayName)
                }
            }

            // The description of whichever is chosen, rather than ten of them at once.
            Text(chosen.displayName + " · " + chosen.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                // The words change with the colour rather than being swapped out from under
                // it: one line replacing another in place reads as a glitch.
                .contentTransition(.opacity)
                .id(chosen)
                .transition(.opacity)
        }
        .padding(.vertical, 4)
    }

    /// One circle: the field it makes, with its own light across the middle.
    private func swatch(_ colour: BackdropColour) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [colour.edge, colour.glow, colour.edge],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Capsule()
                .fill(colour.light.opacity(0.75))
                .frame(height: 1.5)
                .padding(.horizontal, 7)
                .rotationEffect(.degrees(-16))

            Circle()
                .strokeBorder(
                    chosen == colour ? colour.light : Color.primary.opacity(0.12),
                    lineWidth: chosen == colour ? 2 : 0.5
                )
        }
        .frame(height: 44)
        // The chosen one stands a little proud of the rest, and gets there by growing.
        .scaleEffect(chosen == colour ? 1.08 : 1)
        .contentShape(.circle)
    }
}

/// A picture of your own: the one chosen, how it looks behind a conversation, and how much it
/// is softened and veiled.
///
/// The system's photo picker, which hands over the one picture chosen and nothing else — so
/// there is no permission to ask for and no library to look into.
private struct BackdropPhotoChoice: View {
    @Environment(\.colorScheme) private var scheme

    @Binding var veil: Double
    @Binding var blur: Double

    @State private var picked: PhotosPickerItem?
    @State private var isLoading = false
    @State private var problem: String?

    private var photo: BackdropPhoto { BackdropPhoto.shared }

    var body: some View {
        let hasPhoto = photo.image != nil

        VStack(alignment: .leading, spacing: 12) {
            if hasPhoto {
                PhotoBackdrop(veil: veil, blur: blur)
                    .frame(height: 150)
                    .overlay(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 6) {
                            bubble("Gaan we nog een keer een zaterdag rijden?")
                            bubble("Ja hoor")
                        }
                        .padding(10)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                dial("Veil", $veil)
                dial("Blur", $blur)
            }

            HStack {
                PhotosPicker(selection: $picked, matching: .images) {
                    Label(
                        hasPhoto ? "Choose Another" : "Choose a Photo",
                        systemImage: "photo.on.rectangle"
                    )
                }
                .disabled(isLoading)

                Spacer()

                if isLoading {
                    ProgressView()
                } else if hasPhoto {
                    Button("Remove", role: .destructive) {
                        withAnimation { photo.remove() }
                    }
                }
            }
            .buttonStyle(.borderless)

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            isLoading = true
            problem = nil

            Task {
                defer {
                    isLoading = false
                    picked = nil
                }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw BackdropPhoto.Failure.unreadable
                    }
                    try await photo.use(data)
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
    }

    private func dial(_ name: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Slider(value: value, in: 0...1, step: 0.05)
                .accessibilityLabel(name)

            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}

/// How strongly the light comes through, with the answer above the dials.
///
/// The thing being judged sits directly over the dials that change it, with a line of text on
/// top, because the question was never how it looks but whether you can still read through
/// it.
///
/// Two, because they are two different things. One is what is drawn: the strands, the stars
/// or the lines. The other is the wash of colour it lies on — and the light where the ribbon
/// turns — which the first one never touched, so you could turn the drawing down to nothing
/// and still be looking at a green screen.
private struct BackdropStrength: View {
    @Environment(\.colorScheme) private var scheme

    let style: BackdropStyle
    let colour: BackdropColour
    @Binding var presence: Double
    @Binding var glow: Double

    @State private var depth = SkyDepth()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            preview
            dial(style.lightName, $presence)
            dial("Glow", $glow)
        }
        .padding(.vertical, 4)
        // The colour swatch above sets this going; without it the little conversation jumps
        // from one colour to the next while the circle it came from is still growing.
        .animation(.easeInOut(duration: 0.3), value: colour)
    }

    private func dial(_ name: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Slider(value: value, in: 0...1, step: 0.05)
                .accessibilityLabel(name)

            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    /// A conversation in miniature, in whichever of light and dark the app is in now: the
    /// backdrop as it will actually be seen, with a line of text over it — because the
    /// question was never only how it looks, but whether you can still read through it.
    private var preview: some View {
        BackdropPicture(style: style, colour: colour, presence: presence, glow: glow, depth: depth)
            .frame(height: 150)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    bubble("Gaan we nog een keer een zaterdag rijden?")
                    bubble("Ja hoor")
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
    }
}


/// The background, on a page of its own: the choice, and the colour and dials for it.
private struct BackgroundSettings: View {
    @Environment(ChatSession.self) private var session

    var body: some View {
        Form {
            Section {
                ForEach(BackdropStyle.allCases, id: \.self) { style in
                    Button {
                        withAnimation(.snappy(duration: 0.3)) { session.backdrop = style }
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.displayName)
                                    .foregroundStyle(.primary)
                                Text(style.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            if session.backdrop == style {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(session.backdrop == style ? .isSelected : [])
                }
            } header: {
                Text("Background")
            } footer: {
                Text("Behind the chat list and every conversation, in light and in dark.")
            }

            // The colours and the dials come in under the choice rather than appearing
            // fully formed where there was nothing a moment ago. One set for all three drawn
            // ones: the colour you like is the colour you like, whatever it is lighting.
            if session.backdrop != .none {
                Section {
                    if session.backdrop == .photo {
                        BackdropPhotoChoice(
                            veil: Binding(
                                get: { session.backdropVeil },
                                set: { session.backdropVeil = $0 }
                            ),
                            blur: Binding(
                                get: { session.backdropBlur },
                                set: { session.backdropBlur = $0 }
                            )
                        )
                        .transition(.opacity)
                    }

                    if session.backdrop.isDrawn {
                        BackdropStrength(
                            style: session.backdrop,
                            colour: session.backdropColour,
                            presence: Binding(
                                get: { session.backdropPresence },
                                set: { session.backdropPresence = $0 }
                            ),
                            glow: Binding(
                                get: { session.backdropGlow },
                                set: { session.backdropGlow = $0 }
                            )
                        )
                        .transition(.opacity)

                        BackdropColours(chosen: Binding(
                            get: { session.backdropColour },
                            set: { session.backdropColour = $0 }
                        ))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } footer: {
                    Text(session.backdrop.note)
                }
            }

        }
        .navigationTitle("Background")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What each bridge said, word for word. The accounts list is what the app makes of it; this
/// is what it was made from, so a bridge in trouble and an app that misread it can be told
/// apart without a computer.
private struct BridgeDiagnosticsView: View {
    @Environment(ChatSession.self) private var session

    /// What a bridge last said, and when.
    private static func answerLine(of diagnosis: ChatSession.BridgeDiagnosis) -> String {
        guard let answer = diagnosis.answer else { return "Not asked yet" }
        let when = answer.at.formatted(date: .omitted, time: .standard)
        return answer.summary + " · " + when
    }

    /// The three facts under a bridge's answer, in one line.
    private static func flags(of diagnosis: ChatSession.BridgeDiagnosis) -> String {
        var words: [String] = []
        words.append(diagnosis.hasAccount ? "account" : "no account")
        words.append(diagnosis.isUsed ? "in use" : "not in use")
        if diagnosis.isMissing { words.append("marked missing") }
        if let since = diagnosis.askingSince {
            words.append("asking since " + since.formatted(date: .omitted, time: .standard))
        }
        return words.joined(separator: " · ")
    }

    /// Which bridges the latest look asked, and whether it is over.
    private static func roundLine(of round: ChatSession.BridgeRound?) -> String {
        guard let round else { return "Not asked yet since Chatman opened." }
        let start = round.started.formatted(date: .omitted, time: .standard)
        let asked = round.asked.map(\.rawValue).joined(separator: ", ")
        guard let finished = round.finished else {
            return "Asking since " + start + ": " + asked + ". Not every answer is in yet."
        }
        let end = finished.formatted(date: .omitted, time: .standard)
        return "Last asked " + start + " – " + end + ": " + asked + "."
    }

    var body: some View {
        Form {
            Section {
                ForEach(session.bridgeDiagnoses) { diagnosis in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            NetworkBadge(network: diagnosis.network, size: 20)
                            Text(diagnosis.network.displayName)
                        }
                        Text(Self.answerLine(of: diagnosis))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(Self.flags(of: diagnosis))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                }

                Button("Ask Again") {
                    Task { await session.refreshBridges() }
                }
            } header: {
                Text("Bridges")
            } footer: {
                Text(Self.roundLine(of: session.bridgeRound))
            }

        }
        .navigationTitle("Bridge Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
