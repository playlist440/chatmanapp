#if canImport(UIKit)
import SwiftUI

/// Somebody's picture, on its own and as large as the screen allows.
///
/// Both apps show the same thing for the same reason: the picture at the top of a chat is the
/// size of a fingernail, and it's often the only photo you have of that person that isn't in
/// a group shot. Tapping it should show it, and showing it should mean showing it — not a
/// menu with "view photo" three items down.
public struct AvatarPortrait: View {

    private let conversation: Conversation
    private let session: ChatSession
    private let onDismiss: () -> Void

    public init(
        conversation: Conversation,
        session: ChatSession,
        onDismiss: @escaping () -> Void
    ) {
        self.conversation = conversation
        self.session = session
        self.onDismiss = onDismiss
    }

    private var initials: String {
        let words = session.displayName(for: conversation).split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    @State private var drag: CGFloat = 0

    public var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                picture
                    .frame(maxWidth: 320, maxHeight: 320)
                    .clipShape(Circle())
                    // A ring the width of a hair, to keep a dark photo from dissolving into
                    // a dark screen.
                    .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)

                Text(session.displayName(for: conversation))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.horizontal, 24)
        }
        // Three ways out, because this is a dead end otherwise: the cross, a tap anywhere,
        // and the pull-down everybody tries first on a full-screen picture.
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.15), in: Circle())
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(20)
        }
        .offset(y: drag)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Downwards only. Dragging a picture up to dismiss it is nobody's habit.
                    drag = max(0, value.translation.height)
                }
                .onEnded { value in
                    if value.translation.height > 100 {
                        onDismiss()
                    } else {
                        withAnimation(.snappy) { drag = 0 }
                    }
                }
        )
    }

    @ViewBuilder
    private var picture: some View {
        // Asked for at a size worth looking at, not the one the title bar uses.
        RemoteImage(
            request: session.avatarRequest(for: conversation, size: 512),
            cacheKey: conversation.avatarURL.map { "\($0)@512" }
        ) {
            if let data = session.contactPhoto(for: conversation),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // Nobody has a picture everywhere. Initials on the service's own colour beat
                // a grey circle and an apology.
                let brand = conversation.network.brandColour

                Circle()
                    .fill(Color(red: brand.red, green: brand.green, blue: brand.blue)
                        .opacity(0.35))
                    .overlay {
                        Text(initials)
                            .font(.system(size: 96, weight: .light))
                            .foregroundStyle(.white.opacity(0.85))
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
#endif
