import SwiftUI
import ChatmanKit

/// Signing in.
///
/// Four fields, and the fourth is nearly always right already. Chatman talks to a server
/// somebody runs themselves, which means the two things a hosted app can assume — that the
/// address is known and that it's on the standard port — are exactly the two things that
/// aren't. Asking plainly beats a first attempt that times out and a message about it.
struct SignInView: View {
    @Environment(ChatSession.self) private var session

    @State private var username = ""
    @State private var password = ""
    @State private var server = ""
    @State private var port = "443"
    @State private var errorMessage: String?
    @State private var isSigningIn = false

    @FocusState private var focusedField: Field?

    private enum Field { case username, password, server, port }

    /// The address to connect to, from the two fields that describe it.
    ///
    /// The port is left off when it's the standard one, so a normal server produces a normal
    /// address rather than one with `:443` bolted on.
    private var address: String {
        let host = server.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        guard !host.isEmpty else { return "" }

        let number = port.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty, number != "443" else { return host }

        return "\(host):\(number)"
    }

    /// Who to sign in as.
    ///
    /// A bare name gets the server's domain put after it, which is what it means. Someone
    /// whose Matrix ID lives on a different domain than the server they connect to can type
    /// the whole thing instead, and it's taken as written.
    private var matrixID: String {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.hasPrefix("@"), !name.contains(":") else { return name }

        let host = server.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return name }

        return "@\(name):\(host)"
    }

    private var canSignIn: Bool {
        !username.isEmpty && !password.isEmpty && !server.isEmpty && !isSigningIn
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .server }
                } header: {
                    Text("Your account")
                } footer: {
                    Text("The account on your own Matrix server. Just the name — `alex`, not the whole address.")
                }

                Section {
                    TextField("matrix.example.com", text: $server)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("443", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .focused($focusedField, equals: .port)
                    }
                } header: {
                    Text("Your server")
                } footer: {
                    // The one detail that catches everybody: plenty of home connections have
                    // 443 blocked by the provider, and the server ends up somewhere else.
                    Text("Leave the port at 443 unless your server listens somewhere else — 8443 is the usual alternative when a provider blocks the standard one.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: signIn) {
                        HStack {
                            Spacer()
                            if isSigningIn {
                                ProgressView()
                            } else {
                                Text("Sign in")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSignIn)
                }
            }
            .navigationTitle("Chatman")
        }
        .onAppear { focusedField = .username }
    }

    private func signIn() {
        focusedField = nil
        isSigningIn = true
        errorMessage = nil

        Task {
            defer { isSigningIn = false }

            do {
                try await session.signIn(
                    address: address,
                    username: matrixID,
                    password: password
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
