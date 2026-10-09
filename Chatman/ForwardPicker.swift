import SwiftUI
import ChatmanKit

/// Where a message goes next.
///
/// Every conversation, whatever service it belongs to — that's the point of it. A photo from
/// a Signal chat can go to a WhatsApp group because neither of them ever handles the file:
/// it already sits on your own server, and both bridges fetch it from there.
struct ForwardPicker: View {
    @Environment(ChatSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let message: Message

    @State private var query = ""
    @State private var sendingTo: String?
    @State private var problem: String?

    private var targets: [Conversation] {
        let all = session.forwardTargets().filter { $0.id != message.conversation?.id }
        guard query.count >= 1 else { return all }

        return all.filter {
            session.displayName(for: $0).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Section {
                    ForEach(targets) { conversation in
                        Button {
                            forward(to: conversation)
                        } label: {
                            HStack(spacing: 10) {
                                Avatar(conversation: conversation, size: 32)

                                Text(session.displayName(for: conversation))
                                    .foregroundStyle(.primary)

                                Spacer()

                                if sendingTo == conversation.id {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(sendingTo != nil)
                    }
                } header: {
                    Text(preview)
                        .textCase(nil)
                }
            }
            .searchable(text: $query, prompt: "Search chats")
            .navigationTitle("Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// What is being passed on, in one line, so nobody sends the wrong thing.
    private var preview: String {
        switch message.kind {
        case .image: "Photo"
        case .video: message.isAnimated ? "GIF" : "Video"
        case .audio: message.isVoice ? "Voice message" : message.body
        case .sticker: "Sticker"
        case .poll: "📊 " + message.body
        case .file: message.body
        default: message.body
        }
    }

    private func forward(to conversation: Conversation) {
        sendingTo = conversation.id
        problem = nil

        Task {
            defer { sendingTo = nil }

            do {
                try await session.forward(message, to: conversation)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
