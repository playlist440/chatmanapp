import SwiftUI
import ChatmanKit

/// The same screen in several typefaces, for choosing between them.
///
/// A specimen line tells you what a font looks like; it doesn't tell you what the app looks
/// like. So this is a chat row and a message bubble, the two things you spend all your time
/// reading, drawn once per candidate at the sizes Chatman actually uses.
///
/// Arial Nova isn't among them because it isn't on iOS — only Arial, Arial Bold and Arial
/// Rounded are — and shipping it would need a licence from Monotype that a Windows or Office
/// copy doesn't grant.
struct FontPreview: View {

    private struct Face: Identifiable {
        let name: String
        let note: String
        /// Nil means the system font at this weight.
        let postScript: String?
        let weight: Font.Weight

        var id: String { name }

        func font(_ size: CGFloat, bold: Bool = false) -> Font {
            guard let postScript else {
                return .system(size: size, weight: bold ? .semibold : weight)
            }
            return .custom(bold ? boldName : postScript, size: size)
        }

        private var boldName: String {
            guard let postScript else { return "" }
            if postScript.hasPrefix("HelveticaNeue") { return "HelveticaNeue-Medium" }
            if postScript == "ArialMT" { return "Arial-BoldMT" }
            if postScript.hasPrefix("AvenirNext") { return "AvenirNext-DemiBold" }
            return postScript
        }
    }

    private let faces: [Face] = [
        Face(name: "Nu", note: "systeem, normaal", postScript: nil, weight: .regular),
        Face(name: "Systeem licht", note: "San Francisco Light", postScript: nil, weight: .light),
        Face(
            name: "Helvetica Neue Light",
            note: "het dichtst bij Arial Nova Light",
            postScript: "HelveticaNeue-Light",
            weight: .regular
        ),
        Face(
            name: "Helvetica Neue",
            note: "zelfde vorm, normaal gewicht",
            postScript: "HelveticaNeue",
            weight: .regular
        ),
        Face(name: "Arial", note: "op iOS, geen Light", postScript: "ArialMT", weight: .regular),
        Face(
            name: "Avenir Next",
            note: "ronder, rustig op klein formaat",
            postScript: "AvenirNext-Regular",
            weight: .regular
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(faces) { face in
                        sample(face)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .navigationTitle("Lettertypes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func sample(_ face: Face) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(face.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)

                Text(face.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // A chat row, at the sizes the list uses.
            HStack(spacing: 10) {
                Circle()
                    .fill(.tertiary)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text("RD")
                            .font(face.font(16))
                            .foregroundStyle(.secondary)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Anna de Vries")
                        .font(face.font(18, bold: true))

                    Text("Ik wil dit wel gaan regelen, zal ik 2 open tikkies sturen?")
                        .font(face.font(15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // And a message, which is where the reading actually happens.
            Text("Zullen we om acht uur bij de ingang afspreken? Dan lopen we samen naar binnen.")
                .font(face.font(17))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 18).fill(.quaternary)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.4))
        }
    }
}
