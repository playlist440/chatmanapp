import SwiftUI
import ChatmanKit

/// Starting a conversation from the watch: the people you talk to most, or a name.
///
/// Most of the time the person is one of a handful, so they are simply there, one tap away,
/// and that tap opens the chat you already have — nothing asked of the bridge. Anybody else
/// is a name away: one search across every connected service, same as on the phone, and
/// dictation makes saying it faster here than anywhere.
///
/// The full contact list is only fetched once you start typing. Fetching it every time the
/// sheet opened meant every bridge's whole address book over the watch's radio, for the
/// four times in five that you then tapped a face at the top.
struct WatchNewChatView: View {
    @Environment(ChatSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Reported back so the list can open what was just started.
    @Binding var startedConversationID: String?

    @State private var everyone: [ChatSession.Reachable] = []
    @State private var searchTerm = ""
    @State private var isLoading = false
    @State private var hasLoaded = false

    /// The people you write to most, worked out when the sheet opens.
    @State private var closest: [Conversation] = []
    @State private var startingWith: String?
    @State private var message: String?

    /// Whether this sheet is still up.
    ///
    /// Starting a chat takes a few seconds while the bridge builds the room, and the sheet can
    /// be swiped away in the meantime. The answer used to be handed to the list regardless,
    /// after the list had stopped listening for it — so the next time this sheet was opened
    /// and closed, that old chat opened out of nowhere. Walked away from, it simply turns up
    /// in the list instead.
    @State private var isShowing = false

    private var results: [ChatSession.Reachable] {
        let term = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return [] }

        return everyone.filter { person in
            person.name.lowercased().contains(term)
                || (person.number ?? "").contains(term)
        }
    }

    var body: some View {
        List {
            TextField("Name", text: $searchTerm)
                .textInputAutocapitalization(.never)

            if searchTerm.isEmpty {
                ForEach(closest) { conversation in
                    Button {
                        startedConversationID = conversation.id
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            NetworkBadge(network: conversation.network, size: 14)
                            Text(session.displayName(for: conversation))
                                .lineLimit(1)
                        }
                    }
                }
            } else if isLoading {
                ProgressView()
            } else if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if results.isEmpty {
                Text("No one found.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(results) { person in
                Button {
                    start(with: person)
                } label: {
                    HStack(spacing: 6) {
                        NetworkBadge(network: person.network, size: 14)

                        Text(person.name)
                            .lineLimit(1)

                        Spacer()

                        if startingWith == person.id { ProgressView() }
                    }
                }
                .disabled(startingWith != nil)
            }
        }
        .navigationTitle("New chat")
        .onAppear { closest = session.closestPeople() }
        // The contacts, the first time there is something to look for in them.
        .task(id: searchTerm.isEmpty) {
            guard !searchTerm.isEmpty, !hasLoaded else { return }
            await load()
        }
        .onAppear { isShowing = true }
        .onDisappear { isShowing = false }
    }

    private func load() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        everyone = await session.everyoneReachable()

        // Only the bridges this server actually runs.
        let failures = session.availableNetworks
            .compactMap { session.contactLookupError(for: $0) }

        message = failures.first
    }

    private func start(with person: ChatSession.Reachable) {
        startingWith = person.id

        Task {
            defer { startingWith = nil }

            do {
                let started = try await session.startChat(
                    with: person.contact, on: person.network
                )
                // See `isShowing`.
                guard isShowing else { return }
                startedConversationID = started
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
