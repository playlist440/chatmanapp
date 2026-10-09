import Combine
import SwiftData
import SwiftUI
import ChatmanKit

/// A way to look at a screen without a server behind it.
///
/// Half of this app can only be reached after signing in to a homeserver with bridges on it,
/// which makes checking whether something is a pixel out of place a twenty-minute round trip
/// through a real device. This puts any screen on a simulator in ten seconds, with invented
/// conversations in it.
///
/// It exists only when asked for by name on the command line, so nothing about the shipped
/// app changes: no menu, no gesture, no setting that could be stumbled into.
///
///     xcrun simctl launch <device> com.example.Chatman --design-preview settings
enum DesignPreview {

    /// Which screen was asked for, if any.
    static var requested: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--design-preview"),
              index + 1 < arguments.count
        else { return nil }

        return arguments[index + 1]
    }

    /// A session with nothing behind it but a store that lives in memory.
    @MainActor
    static func makeSession() -> (ChatSession, ModelContainer) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: Schema([Conversation.self, Message.self]), configurations: configuration
        )

        let session = ChatSession(
            profile: .phone,
            container: container,
            defaults: UserDefaults(suiteName: "design.preview") ?? .standard
        )

        // So a measurement can turn the backdrop off without fighting the preferences daemon
        // for it: a setting written from outside a running simulator is cached, rewritten and
        // quietly ignored. An argument is not.
        //
        // Set both ways round rather than only when the flag is there. Choosing it stores it,
        // so a single run with the flag would have switched it off for every run after — and
        // a measurement of the thing switched off, labelled as the thing switched on, is
        // worse than no measurement. This one did exactly that before anybody noticed.
        //
        // `--backdrop ribbon` picks one; `--no-backdrop` is the same as `--backdrop none`.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--no-backdrop") {
            session.backdrop = .none
        } else if let index = arguments.firstIndex(of: "--backdrop"), index + 1 < arguments.count,
                  let style = BackdropStyle(rawValue: arguments[index + 1]) {
            session.backdrop = style
        } else {
            session.backdrop = .stars
        }

        // And the same for the dark switch, for a reason that cost a measurement: the preview
        // keeps its own settings, so the one set in the real app does not reach it. Measuring
        // a backdrop that only draws in the dark, on a phone that happened to be in light,
        // measures nothing at all — and says so in a number that looks perfectly reasonable.
        session.forcesDarkMode = ProcessInfo.processInfo.arguments.contains("--dark")

        // So a colour can be looked at without tapping through to the settings first.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--colour"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let colour = BackdropColour(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
            session.backdropColour = colour
        }

        #if DEBUG
        CPUMeter.run(session)
        #endif

        seed(into: container)
        return (session, container)
    }

    /// Enough conversation to judge a layout by.
    @MainActor
    private static func seed(into container: ModelContainer) {
        let context = container.mainContext

        // Enough of them to fill the screen and then some: a list that fits without
        // scrolling never passes under the header, and a header with nothing behind it is
        // the one thing that makes glass look like paint.
        let people: [(String, ChatNetwork, Bool)] = [
            ("Anna", .signal, false),
            ("Weekend weg", .whatsapp, true),
            ("Papa", .whatsapp, false),
            ("Buurtapp", .signal, true),
            ("Anna de Vries", .whatsapp, false),
            ("Voetbal zaterdag", .signal, true),
            ("Mama", .whatsapp, false),
            ("Bas Louwers", .signal, false),
            ("Klas 4B", .whatsapp, true),
            ("Aniek Goorts", .whatsapp, false),
            ("Larissa Frijns", .signal, false),
            ("Werk", .signal, true),
            // Enough to have to scroll for. A list that fits on one screen can't show
            // whether the pinned row stays where it is.
            ("Tandarts", .whatsapp, false),
            ("Sportschool", .signal, true),
            ("Oma", .whatsapp, false),
            ("Jeroen Bakker", .signal, false),
            ("Vakantie 2026", .whatsapp, true),
            ("Sanne", .signal, false),
            ("Buren", .whatsapp, true),
            ("Thomas de Vries", .signal, false)
        ]

        for (index, person) in people.enumerated() {
            let conversation = Conversation(
                id: "!room\(index):example.com",
                name: person.0,
                isDirect: !person.2,
                network: person.1
            )
            conversation.otherMemberCount = person.2 ? 6 : 1
            conversation.lastActivity = Date(timeIntervalSinceNow: Double(-index) * 900)
            // One long enough to be cut off and one that is a single emoji, because the
            // bubble under a pinned face has to fit both: it used to take the whole column
            // whatever was in it, so one small face floated in the middle of a wide blue box.
            conversation.lastMessagePreview = switch index {
            case 0: "Zullen we om acht uur bij de ingang afspreken?"
            case 2: "👍"
            default: "See you at eight"
            }
            conversation.unreadCount = index < 3 ? 3 : 0

            // A few pinned, so the row of faces has something in it — and one of them with
            // something waiting, which is the state worth looking at.
            conversation.isPinned = index < 5

            if index == 2 { conversation.unreadCount = 12 }
            if index == 4 { conversation.isManuallyUnread = true }
            context.insert(conversation)

            // Longer than a screen, on purpose. A conversation of four lines fits with room
            // to spare, and a scroll view with slack in it hides every mistake about where
            // the bottom of one is — which is exactly the thing worth looking at.
            var lines: [(String, String)] = (1...36).map { number in
                number.isMultiple(of: 2)
                    ? ("@alex:example.com", "Bericht \(number), van mij")
                    : ("@signal_abc:example.com", "Bericht \(number), van de ander")
            }

            lines += [
                ("@signal_abc:example.com", "Ben je er al?"),
                ("@alex:example.com", "Bijna, over vijf minuten"),
                ("@signal_abc:example.com", "Top, ik zit binnen bij het raam"),
                ("@alex:example.com", "Zie je zo")
            ]

            for (offset, line) in lines.enumerated() {
                let message = Message(
                    id: "$m\(index)-\(offset)",
                    sender: line.0,
                    senderName: line.0.hasPrefix("@alex") ? "Alex" : person.0,
                    timestamp: Date(timeIntervalSinceNow: Double(offset - lines.count) * 120),
                    body: line.1,
                    kind: .text
                )
                message.conversation = conversation
                context.insert(message)
            }

            // A long answer to a long message: the shape a group chat takes when somebody is
            // arranging something, and the one that showed the text being cut off.
            let quoted = Message(
                id: "$long-\(index)-a",
                sender: "@signal_abc:example.com",
                senderName: person.0,
                timestamp: Date(timeIntervalSinceNow: -90),
                body: "We kunnen een diner bon van cusco in uden doen? Weet dat Gideon en Madelief daar graag komen en het is dichtbij",
                kind: .text
            )
            quoted.conversation = conversation
            context.insert(quoted)

            let answer = Message(
                id: "$long-\(index)-b",
                sender: "@signal_def:example.com",
                senderName: "Anna",
                timestamp: Date(timeIntervalSinceNow: -60),
                body: "Ik wil dit wel gaan regelen, zal ik 2 open tikkies sturen? 1 voor gideon en Madelief en 1 voor Sophia. Kan iedereen overmaken wat ie gepast vindt, dan koop ik de bon en breng ik hem langs",
                kind: .text,
                replyToID: quoted.id
            )
            answer.conversation = conversation
            context.insert(answer)

            // A photo with something written under it, which is its own layout and worth
            // being able to look at without a server.
            let photo = Message(
                id: "$photo-\(index)",
                sender: "@alex:example.com",
                senderName: "Alex",
                timestamp: Date(timeIntervalSinceNow: -30),
                body: "Photo",
                kind: .image
            )
            photo.caption = "Hier stonden we vanochtend, vlak voor het begon te regenen"
            photo.conversation = conversation
            context.insert(photo)

            // An album the way a WhatsApp bridge delivers one: every picture as its own
            // message, with a line of the bridge's own prose in the middle of them carrying
            // the reaction that was meant for the set.
            for number in 0..<7 {
                let part = Message(
                    id: "$album-\(index)-\(number)",
                    sender: "@signal_def:example.com",
                    senderName: "Jordy",
                    timestamp: Date(timeIntervalSinceNow: -20 + Double(number)),
                    body: "Photo",
                    kind: .image
                )
                part.conversation = conversation
                context.insert(part)

                if number == 0 {
                    let notice = Message(
                        id: "$album-\(index)-notice",
                        sender: "@signal_def:example.com",
                        senderName: "Jordy",
                        timestamp: Date(timeIntervalSinceNow: -19.5),
                        body: "Sent an album with 7 images:",
                        kind: .text
                    )
                    notice.reactions = ["❤️": 2]
                    notice.conversation = conversation
                    context.insert(notice)
                }
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--old-chat") {
            seedOldChat(into: context)
        }

        try? context.save()
    }

    /// A group that went quiet months ago and then filled up while nobody looked: four hundred
    /// messages, most of them unread, with more on the server. The shape a chat has to be in
    /// to be opened far back and widened a long way at once.
    @MainActor
    private static func seedOldChat(into context: ModelContext) {
        let conversation = Conversation(
            id: "!old:example.com",
            name: "Oud gesprek",
            isDirect: false,
            network: .whatsapp,
            lastActivity: .now,
            previousBatch: "t0"
        )
        conversation.otherMemberCount = 9
        conversation.unreadCount = 250
        context.insert(conversation)

        let people = ["Anna", "Jordy", "Sanne", "Bas", "Oma"]
        for number in 0..<400 {
            let who = people[number % people.count]
            let message = Message(
                id: "$old-\(number)",
                sender: "@whatsapp_\(who.lowercased()):example.com",
                senderName: who,
                timestamp: Date(timeIntervalSinceNow: Double(number - 400) * 3 * 3600),
                body: number.isMultiple(of: 7)
                    ? "Photo"
                    : "Bericht \(number) uit een gesprek dat al een tijd loopt, met wat meer tekst erin",
                kind: number.isMultiple(of: 7) ? .image : .text
            )
            message.conversation = conversation
            context.insert(message)
        }
    }

    /// One more message, as if somebody just sent it.
    @MainActor
    static func appendMessage(to conversation: Conversation) {
        let number = conversation.messages.count + 1
        let message = Message(
            id: "$live-\(number)-\(Int(Date().timeIntervalSince1970))",
            sender: "@signal_abc:example.com",
            senderName: conversation.name,
            timestamp: .now,
            body: "Net binnen: bericht \(number)",
            kind: .text
        )
        message.conversation = conversation
        conversation.lastActivity = message.timestamp
        conversation.modelContext?.insert(message)
        try? conversation.modelContext?.save()
    }
}

/// The screen asked for on the command line.
struct DesignPreviewView: View {
    let screen: String
    let session: ChatSession

    var body: some View {
        content
            // So a typeface picked on the settings screen is visible on the others.
            .environment(\.chatmanTypeface, session.typeface)
            // And so does the dark switch, for the same reason the real root has it: a
            // setting you can't see working in the preview is a setting you can't judge.
            .preferredColorScheme(session.forcesDarkMode ? .dark : nil)
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        // The pinned faces and the shelf at a row of in-between moments, side by side.
        //
        // Both follow a finger or a scroll point for point, and a jump halfway is invisible
        // at full speed and glaring when done slowly. Stills of the in-between states are
        // the only way to look at that without a thumb on a phone.
        case "steps":
            ChromeSteps(session: session)
                .environment(session)
                .preferredColorScheme(.dark)

        case "settings":
            SettingsView()
                .environment(session)

        case "fonts":
            FontPreview()

        // The backdrop on its own, with nothing over it. Judging the flares through a
        // conversation is judging them through a wall of grey bubbles — and measuring what
        // they cost through one measures a conversation.
        //
        // It honours the choice rather than drawing unconditionally, so `--no-backdrop` gives
        // a screen that really is doing nothing. That is the whole point of a baseline: on a
        // conversation it came back at eight tenths of a percent, which is the picture loader
        // retrying URLs that were never going to work, not the cost of an empty screen.
        case "backdrop":
            Backdrop(depth: SkyDepth())
                .ignoresSafeArea()
                .environment(session)

        case "conversation":
            // Outside the stack, for the same reason as its neighbour on the watch: what is
            // handed to the root of a navigation stack does not reach what the stack pushes.
            NavigationStack {
                if let conversation = session.conversation(withID: "!room0:example.com") {
                    ConversationView(conversation: conversation)
                }
            }
            .environment(session)

        // The same screen, with somebody talking into it every five seconds.
        //
        // Whether a conversation follows along is not something a still picture can answer:
        // the question is what happens at the moment a message lands, and whether the answer
        // differs when you are at the bottom or halfway up. Without a server behind the
        // preview nothing ever arrives, so this supplies the other half of the conversation.
        case "conversation-live":
            NavigationStack {
                if let conversation = session.conversation(withID: "!room0:example.com") {
                    ConversationView(conversation: conversation)
                        .environment(session)
                        .onReceive(
                            Timer.publish(every: 5, on: .main, in: .common).autoconnect()
                        ) { _ in
                            DesignPreview.appendMessage(to: conversation)
                        }
                }
            }

        default:
            ConversationListView()
                .environment(session)
        }
    }
}

/// The pinned faces folded to 0, 35, 70 and 100 percent, and the shelf open to 40, 48, 50, 52
/// and 60 percent — the stretch where its tiles turn into cards.
private struct ChromeSteps: View {
    let session: ChatSession

    @Namespace private var opening

    @State private var folds: [ListChrome] = [0, 0.35, 0.7, 1].map { collapse in
        let chrome = ListChrome()
        chrome.pinnedCollapse = collapse
        return chrome
    }
    @Query(sort: \Conversation.lastActivity, order: .reverse) private var all: [Conversation]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(folds.enumerated()), id: \.offset) { _, chrome in
                    PinnedRow(
                        conversations: all.filter(\.isPinned),
                        onOpen: { _ in },
                        opening: opening,
                        chrome: chrome
                    )
                    .overlay(alignment: .topLeading) {
                        label("\(Int((chrome.pinnedCollapse * 100).rounded()))%")
                    }
                }

            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(3)
            .background(.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
    }
}
