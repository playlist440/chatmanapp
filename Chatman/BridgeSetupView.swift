import SwiftUI
import CoreImage.CIFilterBuiltins
import ChatmanKit

/// Connecting a chat account.
///
/// One thing on screen at a time, and nothing about bridges. Every mautrix bridge describes
/// its own way in — a code to scan, a form to fill, a page to sign in on — so this renders
/// whatever it's handed rather than knowing anything about Signal or Telegram or X. That's
/// what makes fourteen networks the same amount of work as two.
struct BridgeSetupView: View {
    @Environment(ChatSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let network: ChatNetwork

    @State private var login: BridgeLogin?

    /// True when there is no bridge for this network on the server at all — or none that
    /// answers, which from here is the same thing and is said differently.
    @State private var isMissing = false

    /// True while the bridge is being asked whether it's there, before anything is shown.
    @State private var isChecking = true
    @State private var copied = false
    @State private var openFailed: String?

    var body: some View {
        Group {
            if isMissing {
                missing
            } else if isChecking {
                ProgressView("Getting ready")
                    .controlSize(.large)
            } else if let login {
                content(for: login)
            } else {
                ContentUnavailableView(
                    "Not signed in",
                    systemImage: "person.slash",
                    description: Text("Sign in to Chatman first.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Connect \(network.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    login?.cancel()
                    dismiss()
                }
            }
        }
        .task {
            guard login == nil, !isMissing else { return }

            // Asked before anything is attempted. Starting a login against a bridge that
            // isn't there means a minute of spinner followed by a timeout, which reads as an
            // app that ignored the tap.
            //
            // And asked now, when it hasn't answered yet in this run. Deciding from what was
            // known when the screen opened said "No WhatsApp bridge yet" to anybody quick
            // enough to tap before the first look at the bridges had come back.
            if !session.isInstalled(network) {
                await session.refreshBridges()
            }
            isChecking = false

            guard session.isInstalled(network) else {
                isMissing = true
                return
            }

            login = session.beginBridgeLogin(for: network)
            login?.start()
        }
        .onDisappear { login?.cancel() }
    }

    /// What to say when the server has no bridge for this service, or one that won't answer.
    ///
    /// Two different things, said differently. A bridge that is there and in trouble is
    /// something to look at on the server; telling somebody to "add the container" for one
    /// that is plainly running sends them looking in the wrong place.
    private var missing: some View {
        let silent = session.isUnanswered(network)

        return VStack(spacing: 14) {
            NetworkBadge(network: network, size: 44)

            Text(silent
                 ? "The \(network.displayName) bridge isn't answering"
                 : "No \(network.displayName) bridge yet")
                .chatmanFont(size: 17, weight: .semibold, relativeTo: .headline)
                .multilineTextAlignment(.center)

            Text(silent
                 ? "It is on your server, but it didn't answer Chatman. Its log on the server says why; once it's running again, this screen will connect you."
                 : "Chatman talks to bridges running on your own server, and there isn't one for \(network.displayName) there. Add the container, and this screen will connect you.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let answer = session.bridgeAnswers[network] {
                Text(answer.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button(silent ? "Try again" : "Try anyway") {
                isMissing = false
                login = session.beginBridgeLogin(for: network)
                login?.start()
            }
            .font(.footnote)
            .buttonStyle(.bordered)
        }
        .padding()
    }

    @ViewBuilder
    private func content(for login: BridgeLogin) -> some View {
        switch login.stage {
        case .preparing:
            ProgressView("Getting ready")
                .controlSize(.large)

        case .scan(let code):
            scanning(code: code, instructions: login.instructions, login: login)

        case .form(let form):
            LoginForm(
                network: network,
                form: form,
                instructions: login.instructions,
                onSubmit: { login.submit($0) },
                alternatives: { otherWaysIn(login) }
            )

        case .website(let request):
            CookieLoginView(
                network: network,
                request: request,
                onCollected: { login.submit($0) },
                onGiveUp: { login.cancel(); dismiss() }
            )

        case .showCode(let code):
            ScrollView {
                VStack(spacing: 18) {
                    // Large and spaced, because it is read off one screen and typed into
                    // another, often on the same phone after switching apps. Selectable, so it
                    // can be copied rather than copied out.
                    Text(code)
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .tracking(4)
                        .textSelection(.enabled)
                        .padding(.top, 24)

                    if let instructions = login.instructions, !instructions.isEmpty {
                        Text(instructions)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    ProgressView()
                        .padding(.top, 8)
                }
                .padding()
            }

        case .finishing:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Connecting…")
                    .foregroundStyle(.secondary)
            }

        case .done:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)

                Text("\(network.displayName) connected")
                    .chatmanFont(size: 17, weight: .semibold, relativeTo: .headline)

                Text("Your chats will appear in a moment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .task {
                try? await Task.sleep(for: .seconds(2))
                dismiss()
            }

        case .failed(let reason):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)

                Text("That didn't work")
                    .chatmanFont(size: 17, weight: .semibold, relativeTo: .headline)

                Text(session.isInstalled(network)
                     ? reason
                     : "No \(network.displayName) bridge is running on your server yet. Add one, then come back — the app needs nothing else.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Try again") { login.start() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .padding()
        }
    }

    /// The other ways in, when the bridge offers more than one.
    ///
    /// Underneath rather than in front: nearly everybody wants the one that started, and a
    /// question asked before the answer is a step for nothing. This is here for the people
    /// the other way suits better — a phone with no second device to scan from, mostly.
    @ViewBuilder
    private func otherWaysIn(_ login: BridgeLogin) -> some View {
        if !login.alternatives.isEmpty {
            Menu {
                ForEach(login.alternatives) { flow in
                    Button(flow.name) { login.use(flow) }
                }
            } label: {
                Text("Sign in another way")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func scanning(
        code: String, instructions: String?, login: BridgeLogin
    ) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                if let hint = network.connectionHint {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                QRCode(contents: code)
                    .frame(width: 240, height: 240)

                // The bridge's own wording, when it sent any — it knows about steps this app
                // doesn't, and dropping what it says would leave people guessing.
                if let instructions, !instructions.isEmpty {
                    Text(instructions)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }

                sameDeviceOptions(code: code)

                otherWaysIn(login)
                    .padding(.top, 4)
            }
            .padding()
        }
    }

    /// What to do when the other app is on the phone you're holding.
    ///
    /// A camera can't photograph its own screen, so the code is useless here. The link behind
    /// it can still be handed straight to the app — whether it accepts it depends on a
    /// restriction each network sets for itself, so this offers the attempt and a way out if
    /// it's refused, rather than promising something that might not happen.
    @ViewBuilder
    private func sameDeviceOptions(code: String) -> some View {
        VStack(spacing: 10) {
            Divider()
                .padding(.vertical, 4)

            Text("\(network.displayName) on this phone?")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                openInApp(code)
            } label: {
                Label("Open \(network.displayName)", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)

            Button {
                UIPasteboard.general.string = code
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if let openFailed {
                Text(openFailed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }

    private func openInApp(_ code: String) {
        openFailed = nil

        guard let url = URL(string: code) else {
            openFailed = "That link can't be opened."
            return
        }

        UIApplication.shared.open(url) { opened in
            guard !opened else { return }
            openFailed = """
            \(network.displayName) didn't take the link. Open this screen on another device \
            and scan the code there, or send yourself the copied link.
            """
        }
    }
}

// MARK: - Filling in a form

/// Whatever the bridge asked for, as a form.
///
/// Nothing here knows what a phone number is. The bridge names the fields and says what type
/// each one is; this picks a keyboard and a label to match, and hands the answers back under
/// the names they came with.
private struct LoginForm<Alternatives: View>: View {
    let network: ChatNetwork
    let form: MatrixAPI.BridgeLoginStep.UserInput
    let instructions: String?
    let onSubmit: ([String: String]) -> Void
    @ViewBuilder let alternatives: () -> Alternatives

    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        Form {
            Section {
                ForEach(form.fields) { field in
                    row(for: field)
                }
            } header: {
                if let hint = network.connectionHint {
                    Text(hint)
                        .textCase(nil)
                }
            } footer: {
                if let instructions, !instructions.isEmpty {
                    Text(instructions)
                }
            }

            Section {
                Button("Continue") {
                    onSubmit(values)
                }
                .disabled(!isComplete)
            }

            Section {
                alternatives()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color.clear)
        }
        .onAppear {
            for field in form.fields where values[field.id] == nil {
                values[field.id] = field.defaultValue ?? ""
            }
            focused = form.fields.first?.id
        }
    }

    @ViewBuilder
    private func row(for field: MatrixAPI.BridgeLoginStep.UserInput.Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.type {
            case .password:
                SecureField(field.name, text: binding(for: field))
                    .focused($focused, equals: field.id)
                    .textContentType(.password)

            case .select:
                Picker(field.name, selection: binding(for: field)) {
                    ForEach(field.options ?? [], id: \.self) { option in
                        Text(option).tag(option)
                    }
                }

            default:
                TextField(field.name, text: binding(for: field))
                    .focused($focused, equals: field.id)
                    .keyboardType(keyboard(for: field.type))
                    .textContentType(contentType(for: field.type))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding(for field: MatrixAPI.BridgeLoginStep.UserInput.Field) -> Binding<String> {
        Binding(
            get: { values[field.id] ?? "" },
            set: { values[field.id] = $0 }
        )
    }

    /// Every field is required: the bridge only asks for what it needs.
    private var isComplete: Bool {
        form.fields.allSatisfy { !(values[$0.id] ?? "").isEmpty }
    }

    private func keyboard(for type: MatrixAPI.BridgeLoginStep.UserInput.Field.Kind) -> UIKeyboardType {
        switch type {
        case .phoneNumber: .phonePad
        case .email: .emailAddress
        case .twoFactorCode: .numberPad
        case .url, .domain: .URL
        default: .default
        }
    }

    private func contentType(
        for type: MatrixAPI.BridgeLoginStep.UserInput.Field.Kind
    ) -> UITextContentType? {
        switch type {
        case .phoneNumber: .telephoneNumber
        case .email: .emailAddress
        case .twoFactorCode: .oneTimeCode
        case .url, .domain: .URL
        case .username: .username
        default: nil
        }
    }
}

/// A QR code drawn from a string.
///
/// Core Image does this, so there's no library to add. Interpolation is turned off on purpose:
/// smoothing the squares is what makes a code hard to scan.
private struct QRCode: View {
    let contents: String

    var body: some View {
        if let image = render() {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.gray.opacity(0.2))
                .overlay { Text("Couldn't draw the code").font(.footnote) }
        }
    }

    private func render() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(contents.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
