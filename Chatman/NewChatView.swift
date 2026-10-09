import SwiftUI
import ChatmanKit

/// Starting a conversation: type a name, pick the person.
///
/// One search across every connected service. Nobody scrolls a contact list any more, and
/// splitting the results per service would make you guess which one someone is on before you
/// can look them up. Someone on both appears twice, badged — because which service you pick
/// decides where the conversation lands.
///
/// The contacts come from the bridges, not from Synapse's user directory: that directory only
/// knows people you already share a room with, which is exactly the wrong set here.
struct NewChatView: View {
    @Environment(ChatSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @Binding var openedConversationID: String?

    /// What was already being searched for when this opened, if anything.
    var initialSearch: String = ""

    @State private var everyone: [ChatSession.Reachable] = []
    @State private var searchTerm = ""
    @State private var isLoading = true
    @State private var startingWith: String?
    @State private var message: String?

    /// Selection mode. A group lives on one service, so the first person picked decides
    /// which one — the rest of the list follows.
    @State private var isMakingGroup = false
    @State private var chosen: [ChatSession.Reachable] = []
    @State private var groupName = ""
    @State private var isCreating = false

    /// Whether this sheet is still up.
    ///
    /// Starting a chat takes a few seconds while the bridge builds the room, and the sheet can
    /// be swiped away in the meantime. The answer used to be handed to the list regardless,
    /// after the list had already stopped listening for it — so it sat there, and the next
    /// time the sheet was opened and cancelled, that old chat opened out of nowhere. A chat
    /// started from a sheet you walked away from simply turns up in the list instead.
    @State private var isShowing = false

    @FocusState private var isSearchFocused: Bool

    private var results: [ChatSession.Reachable] {
        let term = searchTerm.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return [] }

        let matches = everyone.filter { person in
            person.name.lowercased().contains(term)
                || (person.number ?? "").replacingOccurrences(of: " ", with: "").contains(term)
        }

        guard let network = chosen.first?.network else { return matches }
        return matches.filter { $0.network == network }
    }

    private var canCreateGroup: Bool {
        chosen.count >= 2
            && !groupName.trimmingCharacters(in: .whitespaces).isEmpty
            && !isCreating
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isMakingGroup {
                    groupHeader
                }

                searchField

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }

                list
            }
            .navigationTitle(isMakingGroup ? "New group" : "New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isMakingGroup {
                        Button("Create") { createGroup() }
                            .disabled(!canCreateGroup)
                    } else {
                        Button("Group") { isMakingGroup = true }
                    }
                }
            }
            .task { await load() }
        }
        .onAppear { isShowing = true }
        .onDisappear { isShowing = false }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Name or number", text: $searchTerm)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)

            if !searchTerm.isEmpty {
                Button {
                    searchTerm = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
        .onAppear { isSearchFocused = true }
    }

    @ViewBuilder
    private var list: some View {
        if isLoading {
            Spacer()
            ProgressView("Loading contacts")
            Spacer()
        } else if searchTerm.isEmpty {
            ContentUnavailableView(
                "Search for someone",
                systemImage: "magnifyingglass",
                description: Text("\(everyone.count) contacts across your connected accounts.")
            )
        } else if results.isEmpty {
            ContentUnavailableView.search(text: searchTerm)
        } else {
            List(results) { person in
                Button {
                    if isMakingGroup { toggle(person) } else { start(with: person) }
                } label: {
                    row(for: person)
                }
                .disabled(startingWith != nil || isCreating)
            }
            .listStyle(.plain)
        }
    }

    private func row(for person: ChatSession.Reachable) -> some View {
        HStack(spacing: 10) {
            NetworkBadge(network: person.network, size: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(person.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(person.number ?? person.network.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if startingWith == person.id {
                ProgressView()
            } else if isMakingGroup {
                Image(systemName: chosen.contains(where: { $0.id == person.id })
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen.contains(where: { $0.id == person.id })
                                     ? Color.accentColor : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// The name field and who's in so far.
    private var groupHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Group name", text: $groupName)
                .textFieldStyle(.plain)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            if chosen.isEmpty {
                Text("Pick at least two people. A group lives on one service, so the first person you choose decides which.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chosen) { person in
                            Button {
                                toggle(person)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(person.name.split(separator: " ").first.map(String.init) ?? person.name)
                                        .font(.caption)
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.quaternary.opacity(0.5), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func toggle(_ person: ChatSession.Reachable) {
        if let index = chosen.firstIndex(where: { $0.id == person.id }) {
            chosen.remove(at: index)
        } else {
            chosen.append(person)
        }
    }

    private func createGroup() {
        guard let network = chosen.first?.network else { return }

        isCreating = true

        Task {
            defer { isCreating = false }

            do {
                let created = try await session.createGroup(
                    named: groupName, with: chosen, on: network
                )
                guard isShowing else { return }
                openedConversationID = created
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func load() async {
        if searchTerm.isEmpty, !initialSearch.isEmpty { searchTerm = initialSearch }

        isLoading = true
        defer { isLoading = false }

        everyone = await session.everyoneReachable()

        // An empty list and a failed request look identical, and only one is worth acting on.
        // Only the bridges this server actually runs. Listing a failure for each of the
        // dozen it doesn't have would bury the one that matters.
        let failures = session.availableNetworks
            .compactMap { network -> String? in
                guard let reason = session.contactLookupError(for: network) else { return nil }
                return "\(network.displayName): \(reason)"
            }

        message = failures.isEmpty ? nil : failures.joined(separator: "\n")
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
                openedConversationID = started
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
