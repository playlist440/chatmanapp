import ChatmanKit
import SwiftUI

/// Every emoji worth reacting with, and a box to find the rest.
///
/// The six in the menu cover most of what anybody sends, but "most" isn't all — and an app
/// that can only react in six ways feels like a demo. There is no system picker to call, so
/// this is a catalogue: grouped the way the keyboard groups them, searchable by the names
/// people actually use, and big enough to tap without aiming.
struct EmojiPicker: View {
    @Environment(\.dismiss) private var dismiss

    let onPick: (String) -> Void

    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 46), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(shown) { group in
                        Section {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(group.emoji, id: \.self) { emoji in
                                    Button {
                                        onPick(emoji)
                                        dismiss()
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: 32))
                                            .frame(width: 46, height: 46)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            // A glass chip rather than a strip of solid background. The
                            // heading has to stay legible while a hundred emoji scroll under
                            // it, and the rest of the app answers that with glass — so this
                            // does too, instead of laying an opaque bar across the picker.
                            Text(group.name)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .chatmanGlass(in: .capsule)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .searchable(text: $query, prompt: "Search emoji")
            .navigationTitle("React")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// What the search leaves standing.
    ///
    /// With nothing typed, the ones you use most come first: finding your usual in a grid of
    /// hundreds every time is a search for something you already know.
    private var shown: [Group] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else {
            let frequent = QuickReactions.frequent()
            guard !frequent.isEmpty else { return Self.groups }
            return [Group(name: "Frequently used", emoji: frequent)] + Self.groups
        }

        return Self.groups.compactMap { group in
            let hits = group.emoji.filter { emoji in
                Self.names[emoji]?.contains(needle) ?? false
            }
            return hits.isEmpty ? nil : Group(name: group.name, emoji: hits)
        }
    }

    struct Group: Identifiable {
        let name: String
        let emoji: [String]
        var id: String { name }
    }

    /// The catalogue. Not every emoji in Unicode — the ones people react with, which is a
    /// much shorter and much more useful list.
    private static let groups: [Group] = [
        Group(name: "Smileys", emoji: [
            "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃", "😉", "😊",
            "😇", "🥰", "😍", "🤩", "😘", "😗", "😚", "😙", "😋", "😛", "😜", "🤪",
            "😝", "🤑", "🤗", "🤭", "🤫", "🤔", "🤐", "🤨", "😐", "😑", "😶", "😏",
            "😒", "🙄", "😬", "😮‍💨", "🤥", "😌", "😔", "😪", "🤤", "😴", "😷", "🤒",
            "🤕", "🤢", "🤮", "🤧", "🥵", "🥶", "🥴", "😵", "🤯", "🤠", "🥳", "😎",
            "🤓", "🧐", "😕", "😟", "🙁", "😮", "😯", "😲", "😳", "🥺", "😦", "😧",
            "😨", "😰", "😥", "😢", "😭", "😱", "😖", "😣", "😞", "😓", "😩", "😫",
            "🥱", "😤", "😡", "😠", "🤬", "😈", "👿", "💀", "💩", "🤡", "👻", "👽",
            "🤖", "🎃"
        ]),
        Group(name: "Hands", emoji: [
            "👍", "👎", "👌", "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘", "🤙", "👈",
            "👉", "👆", "👇", "☝️", "👋", "🤚", "🖐️", "✋", "🖖", "👏", "🙌", "🫶",
            "👐", "🤲", "🤝", "🙏", "✍️", "💅", "🤳", "💪", "🦾", "🫡", "✊", "👊",
            "🤛", "🤜"
        ]),
        Group(name: "Hearts", emoji: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️", "💕",
            "💞", "💓", "💗", "💖", "💘", "💝", "💟", "❤️‍🔥", "❤️‍🩹"
        ]),
        Group(name: "People", emoji: [
            "👶", "🧒", "👦", "👧", "🧑", "👨", "👩", "🧓", "👴", "👵", "🙅", "🙆",
            "💁", "🙋", "🧏", "🙇", "🤦", "🤷", "👮", "🕵️", "💂", "👷", "🤴", "👸",
            "🎅", "🤶", "🦸", "🦹", "🧙", "🧚", "🧛", "🧜", "🧝", "💃", "🕺", "👯",
            "🧖", "🧗", "🤺", "🏇", "⛷️", "🏂", "🏌️", "🏄", "🚣", "🏊", "⛹️", "🏋️",
            "🚴", "🚵", "🤸", "🤼", "🤽", "🤾", "🤹", "🧘"
        ]),
        Group(name: "Animals", emoji: [
            "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮",
            "🐷", "🐸", "🐵", "🙈", "🙉", "🙊", "🐔", "🐧", "🐦", "🐤", "🦆", "🦅",
            "🦉", "🦇", "🐺", "🐗", "🐴", "🦄", "🐝", "🐛", "🦋", "🐌", "🐞", "🐢",
            "🐍", "🦎", "🐙", "🦑", "🦐", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳", "🐋",
            "🦈", "🐊", "🐅", "🦓", "🦍", "🐘", "🦏", "🐪", "🦒", "🐃", "🐄", "🐎",
            "🐖", "🐏", "🐑", "🐐", "🦌", "🐕", "🐩", "🐈", "🐓", "🦃", "🕊️", "🐇",
            "🐁", "🐀", "🐿️", "🦔"
        ]),
        Group(name: "Food", emoji: [
            "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍈", "🍒",
            "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑", "🥦", "🥬", "🥒", "🌶️",
            "🌽", "🥕", "🧄", "🧅", "🥔", "🍠", "🥐", "🥯", "🍞", "🥖", "🧀", "🥚",
            "🍳", "🧈", "🥞", "🧇", "🥓", "🍔", "🍟", "🍕", "🌭", "🥪", "🌮", "🌯",
            "🥗", "🍝", "🍜", "🍲", "🍣", "🍱", "🍚", "🍙", "🍥", "🥠", "🍦", "🍰",
            "🎂", "🧁", "🍫", "🍬", "🍭", "🍩", "🍪", "☕️", "🍵", "🧃", "🥤", "🍺",
            "🍻", "🥂", "🍷", "🥃", "🍸", "🍹", "🧉", "🥛"
        ]),
        Group(name: "Things", emoji: [
            "🎉", "🎊", "🎈", "🎁", "🏆", "🥇", "🥈", "🥉", "⚽️", "🏀", "🏈", "⚾️",
            "🎾", "🏐", "🏉", "🎱", "🏓", "🏸", "🥅", "⛳️", "🎣", "🎽", "🎿", "🛷",
            "🚗", "🚕", "🚌", "🚑", "🚒", "🚚", "🚲", "🛵", "🏍️", "✈️", "🚀", "🛸",
            "⛵️", "🚢", "🏠", "🏡", "🏢", "🏥", "🏦", "🏨", "🏫", "⛪️", "🕌", "🗼",
            "🗽", "⌚️", "📱", "💻", "🖥️", "🖨️", "📷", "🎥", "📺", "🎧", "🎸", "🎹",
            "🥁", "🎺", "🎬", "💡", "🔦", "📚", "📖", "📝", "✏️", "📌", "📎", "🔑",
            "🔒", "🔨", "🧰", "🧲", "💊", "🩺", "💰", "💳", "💎", "⚖️", "🧸", "🪁"
        ]),
        Group(name: "Symbols", emoji: [
            "✅", "❌", "⭕️", "🚫", "⚠️", "❗️", "❓", "‼️", "⁉️", "💯", "🔥", "✨",
            "⭐️", "🌟", "💫", "💥", "💦", "💨", "🕐", "⏰", "⏳", "🔔", "🔕", "🎵",
            "🎶", "➕", "➖", "✖️", "➗", "♾️", "💤", "👀", "🫠", "🆗", "🆕", "🆒",
            "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "⚫️", "⚪️", "🟤"
        ])
    ]

    /// What each one is called, for the search box. Only the words people would type.
    private static let names: [String: String] = {
        var names: [String: String] = [:]

        let known: [String: String] = [
            "😀": "smile happy grin", "😂": "laugh cry tears funny", "🤣": "laugh rolling funny",
            "🙂": "smile slight", "😉": "wink", "😊": "smile blush happy",
            "🥰": "love hearts adore", "😍": "love heart eyes", "😘": "kiss",
            "🤔": "think thinking hmm", "😐": "neutral flat", "🙄": "roll eyes",
            "😴": "sleep tired", "😭": "cry sad sob", "😡": "angry mad",
            "🤯": "mind blown shock", "🥳": "party celebrate", "😎": "cool sunglasses",
            "👍": "thumbs up yes good like", "👎": "thumbs down no bad",
            "👌": "ok perfect", "🙏": "please thanks pray", "👏": "clap applause well done",
            "💪": "strong muscle", "👋": "wave hello hi bye", "🤝": "deal agree handshake",
            "❤️": "heart love red", "💔": "broken heart", "🔥": "fire hot lit",
            "✨": "sparkle shiny", "🎉": "party celebrate congrats", "🎂": "cake birthday",
            "☕️": "coffee", "🍺": "beer drink", "🍕": "pizza food", "🚗": "car drive",
            "✈️": "plane flight travel", "🏠": "home house", "⏰": "alarm time late",
            "✅": "check done yes tick", "❌": "cross no wrong", "⚠️": "warning careful",
            "❓": "question", "❗️": "exclamation important", "💯": "hundred perfect",
            "👀": "eyes looking", "💤": "sleep zzz", "🐶": "dog puppy", "🐱": "cat"
        ]

        for group in groups {
            for emoji in group.emoji {
                names[emoji] = (known[emoji] ?? "") + " " + group.name.lowercased()
            }
        }

        return names
    }()
}
