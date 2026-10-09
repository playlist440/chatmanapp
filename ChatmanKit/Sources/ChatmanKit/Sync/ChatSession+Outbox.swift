import Foundation
import SwiftData

/// Sending, as a queue that survives a bad connection, a locked phone and a closed app.
///
/// Everything you send becomes a stand-in first — a message on screen under its transaction
/// ID — and is then delivered from what that stand-in holds. That one change is what the rest
/// hangs on:
///
/// - **A failure that is the network's fault waits.** The stand-in stays "Sending…" and goes
///   out by itself as soon as a sync gets an answer, which is proof the connection is back.
///   WhatsApp and Signal behave this way; a red "Not sent" for a tunnel is a scare over nothing.
/// - **For ten minutes, and then it asks.** "I'm there in five" arriving half an hour late is
///   worse than not arriving, so after ``patience`` a waiting message stops and says so.
/// - **Trying again is the same message.** It goes out under the transaction ID it was first
///   sent with, and the server does each transaction once. If the first attempt did arrive and
///   only the answer got lost, the second changes nothing instead of posting it twice.
/// - **Nothing is lost when the app goes.** The stand-in is in the store and an attachment's
///   bytes are in the ``Outbox`` on disk, so a message that was on its way when the app was
///   closed is picked up again at the next launch.
extension ChatSession {

    /// How long a message may wait for a connection before it gives up and asks.
    static let patience: TimeInterval = 10 * 60

    /// How a delivery ended.
    enum Delivery {
        case sent
        /// Not yet: the connection is the problem — or something written earlier in the same
        /// chat is still waiting for it — and it will be tried again.
        case waiting
        case failed
    }

    /// What a stand-in holds, copied out before the first wait.
    ///
    /// The stand-in itself can be gone by the time the server answers — the sync brings the
    /// real message back and puts it in its place — and a deleted model must not be touched.
    private struct Draft {
        let id: String
        let room: String
        let kind: Message.Kind
        let body: String
        let caption: String?
        let replyTo: String?
        let mediaURL: String?
        let outboxFile: String?
        let mimeType: String?
        let width: Int?
        let height: Int?
        let duration: Int?
        let isVoice: Bool
        let waveform: [Int]
        let queuedAt: Date

        init(_ message: Message, room: String) {
            id = message.id
            self.room = room
            kind = message.kind
            body = message.body
            caption = message.caption
            // Only a real event can be answered. A reply to something of yours that is itself
            // still on its way goes out as a plain message rather than pointing at nothing.
            replyTo = message.replyToID.flatMap { $0.hasPrefix("$") ? $0 : nil }
            mediaURL = message.mediaURL
            outboxFile = message.outboxFile
            mimeType = message.mediaMimeType
            width = message.mediaWidth
            height = message.mediaHeight
            duration = message.mediaDuration
            isVoice = message.isVoice
            waveform = message.waveform
            queuedAt = message.queuedAt ?? message.timestamp
        }

        var isAttachment: Bool {
            switch kind {
            case .image, .video, .audio, .file, .sticker: true
            default: false
            }
        }

        /// Whether there are bytes to put on the server before the message can be sent.
        var needsUpload: Bool {
            isAttachment && mediaURL == nil
        }

        /// The name the file goes out under: its own, when it came from disk.
        var filename: String {
            if let outboxFile, let last = outboxFile.split(separator: "/").last {
                return String(last)
            }
            return body
        }
    }

    /// Why a stand-in can't be sent, when that isn't the network's fault.
    private enum Refusal: Error {
        /// The bytes of the attachment are gone from disk.
        case lostAttachment
    }

    /// Puts a stand-in in line behind whatever else is on its way to the same chat.
    ///
    /// One at a time per chat, in the order they were written. The server keeps messages in
    /// the order they reach it, and two sent side by side — which is what coming back after a
    /// lost connection used to do with everything that was waiting — could reach it the other
    /// way round and swap places on screen, and in the chat of whoever got them.
    ///
    /// An attachment still to be uploaded does that first, and outside the line. A film can
    /// take minutes to go up, and a line that held "I'm there in five" behind it for all of
    /// them would keep it in order by making it late. Only the message that points at the
    /// upload waits its turn — so a few words written while a film is going up go first, the
    /// way they do everywhere else, and two of them never swap.
    ///
    /// Synchronous on purpose: the line is decided by the order of the calls, not by which
    /// task happens to start first.
    @discardableResult
    func enqueue(_ transactionID: String) -> Task<Delivery, Never>? {
        guard !sending.contains(transactionID),
              let stand = message(id: transactionID),
              let room = stand.conversation?.id
        else { return nil }

        sending.insert(transactionID)

        guard Draft(stand, room: room).needsUpload else {
            return line(transactionID, in: room, checksAge: true)
        }

        return Task { [weak self] () -> Delivery in
            guard let self else { return .waiting }

            uploading.insert(transactionID)
            let stopped = await upload(transactionID)
            uploading.remove(transactionID)

            if let stopped {
                sending.remove(transactionID)
                return stopped
            }

            // Up. However long that took was the upload's time, not the message's, so the
            // ten minutes aren't held against it.
            return await line(transactionID, in: room, checksAge: false).value
        }
    }

    /// Takes a place in a chat's line: waits for whatever went in before, then sends.
    private func line(_ transactionID: String, in room: String, checksAge: Bool) -> Task<Delivery, Never> {
        let ahead = lanes[room]

        let turn = Task { [weak self] () -> Delivery in
            _ = await ahead?.value
            guard let self else { return .waiting }
            defer { self.sending.remove(transactionID) }

            // Sent in the meantime, or given up on: nothing to do.
            guard let stand = message(id: transactionID) else { return .sent }
            if stand.didFailToSend { return .failed }
            if !stand.isPending { return .sent }

            // Ten minutes is ten minutes, in a line or out of it: something held back that
            // long stops and asks rather than arriving late. See `patience`.
            if checksAge, Date.now.timeIntervalSince(stand.queuedAt ?? stand.timestamp) >= Self.patience {
                settle(transactionID, sent: false)
                saveContext()
                return .failed
            }

            // Something written earlier in this chat is still waiting for the connection.
            // Going out ahead of it is the very swap this line is here to prevent, so this
            // one waits too, and the next sync that gets through sends both, in order.
            if isWaiting(before: stand, in: room) { return .waiting }

            return await deliver(transactionID)
        }

        lanes[room] = turn
        return turn
    }

    /// Whether a stand-in written before this one, in the same chat, has yet to go.
    ///
    /// Not counting an attachment that is being uploaded right now: that one is on its way,
    /// and takes its place in line when it's up. See `enqueue`.
    private func isWaiting(before stand: Message, in room: String) -> Bool {
        let mine = stand.queuedAt ?? stand.timestamp
        return waitingStandIns().contains {
            $0.id != stand.id
                && !uploading.contains($0.id)
                && $0.conversation?.id == room
                && ($0.queuedAt ?? $0.timestamp) < mine
        }
    }

    /// Every stand-in that hasn't gone and hasn't given up, oldest first.
    ///
    /// Nearly always none, and never more than a handful: one small question to the store.
    private func waitingStandIns() -> [Message] {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> {
                $0.isPending && !$0.didFailToSend && !$0.id.starts(with: "$")
            }
        )
        let waiting = (try? container.mainContext.fetch(descriptor)) ?? []
        return waiting.sorted { ($0.queuedAt ?? $0.timestamp) < ($1.queuedAt ?? $1.timestamp) }
    }

    /// Puts an attachment's bytes on the server.
    ///
    /// - Returns: Nil when they are up, or were already, and the message can be sent;
    ///   otherwise how it ended.
    private func upload(_ transactionID: String) async -> Delivery? {
        guard let api,
              let stand = message(id: transactionID),
              let room = stand.conversation?.id
        else { return .waiting }

        let draft = Draft(stand, room: room)
        guard draft.needsUpload else { return nil }

        // Carried on past the screen going dark. See `KeepAwake`.
        let awake = KeepAwake.begin("Sending a message")
        defer { awake.end() }

        do {
            guard let file = draft.outboxFile, Outbox.holds(file) else {
                throw Refusal.lostAttachment
            }

            let address = try await api.uploadMedia(
                fileAt: Outbox.url(for: file),
                filename: draft.filename,
                mimeType: draft.mimeType ?? "application/octet-stream"
            )

            // Remembered straight away, so a send that fails after the upload doesn't
            // upload the same film a second time when it's tried again.
            if let current = message(id: transactionID) {
                current.mediaURL = address
                saveContext()
            }
            return nil
        } catch {
            return giveUpOrWait(transactionID, after: error, queuedAt: draft.queuedAt)
        }
    }

    /// Sends one stand-in, from what it holds. Only ever from its turn in line; see `enqueue`.
    private func deliver(_ transactionID: String) async -> Delivery {
        guard let api,
              let stand = message(id: transactionID),
              let room = stand.conversation?.id
        else { return .waiting }

        // Carried on past the screen going dark. See `KeepAwake`.
        let awake = KeepAwake.begin("Sending a message")
        defer { awake.end() }

        stand.isPending = true
        stand.didFailToSend = false
        saveContext()

        // Up already, nearly always; see `enqueue`.
        if let stopped = await upload(transactionID) { return stopped }
        guard let current = message(id: transactionID) else { return .sent }
        let draft = Draft(current, room: room)

        do {
            try await post(draft, address: draft.mediaURL, with: api)

            settle(transactionID, sent: true)
            Outbox.remove(draft.outboxFile)
            saveContext()
            return .sent
        } catch {
            return giveUpOrWait(transactionID, after: error, queuedAt: draft.queuedAt)
        }
    }

    /// What a failed attempt comes to: waiting for the connection while the message is young
    /// and the network is to blame, given up on otherwise.
    private func giveUpOrWait(_ transactionID: String, after error: Error, queuedAt: Date) -> Delivery {
        let transient = (error as? MatrixError)?.isTransient ?? false
        let young = Date.now.timeIntervalSince(queuedAt) < Self.patience

        if transient, young {
            // Left as it is: "Sending…", in the queue. The next sync that gets through
            // sends it again. See `flushOutbox`.
            return .waiting
        }

        settle(transactionID, sent: false)
        saveContext()
        return .failed
    }

    /// The request itself, for whichever kind of message this is.
    private func post(_ draft: Draft, address: String?, with api: MatrixAPI) async throws {
        if draft.isAttachment, let address {
            // A photo that came from this device goes out as a photo, caption and all. Anything
            // else — a film, a file, a recording, something forwarded — as an attachment.
            if draft.kind == .image, let file = draft.outboxFile {
                try await api.sendImage(
                    mxcURL: address,
                    filename: draft.filename,
                    mimeType: draft.mimeType ?? "image/jpeg",
                    byteCount: Outbox.size(of: file) ?? 0,
                    width: draft.width,
                    height: draft.height,
                    caption: draft.caption,
                    to: draft.room,
                    replyingTo: draft.replyTo,
                    transactionID: draft.id
                )
            } else {
                try await api.sendAttachment(
                    mxcURL: address,
                    msgtype: draft.kind == .sticker ? "m.image" : Self.msgtype(for: draft.kind),
                    filename: draft.filename,
                    mimeType: draft.mimeType,
                    width: draft.width,
                    height: draft.height,
                    byteCount: draft.outboxFile.flatMap(Outbox.size(of:)),
                    duration: draft.duration,
                    isVoice: draft.isVoice,
                    waveform: draft.waveform.isEmpty ? nil : draft.waveform,
                    to: draft.room,
                    replyingTo: draft.replyTo,
                    transactionID: draft.id
                )
            }
            return
        }

        try await api.sendText(
            draft.body, to: draft.room, replyingTo: draft.replyTo, transactionID: draft.id
        )
    }

    private static func msgtype(for kind: Message.Kind) -> String {
        switch kind {
        case .image, .sticker: "m.image"
        case .video: "m.video"
        case .audio: "m.audio"
        case .file: "m.file"
        default: "m.text"
        }
    }

    /// Sends whatever is waiting, now that the server answered.
    ///
    /// Called after every sync that gets through, and once at launch. Cheap when there is
    /// nothing waiting, which is nearly always: one question to the store, answered empty.
    ///
    /// Anything that has waited past ``patience`` is marked as not sent instead, so it can be
    /// looked at before it goes — including what was on its way when the app was closed.
    func flushOutbox() {
        let waiting = waitingStandIns()
        guard !waiting.isEmpty else { return }

        // Oldest first, so each chat's line is in the order things were written.
        var changed = false
        for stand in waiting where !sending.contains(stand.id) {
            let queued = stand.queuedAt ?? stand.timestamp
            if Date.now.timeIntervalSince(queued) >= Self.patience {
                stand.isPending = false
                stand.didFailToSend = true
                changed = true
                continue
            }

            enqueue(stand.id)
        }

        if changed { saveContext() }
    }

    /// Clears out attachments nothing is waiting for any more. Once a launch.
    func sweepOutbox() {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.outboxFile != nil }
        )
        let kept = ((try? container.mainContext.fetch(descriptor)) ?? [])
            .filter(\.isStandIn)
            .compactMap(\.outboxFile)
        Outbox.sweep(keeping: Set(kept))
    }

    /// Whether a message that didn't go can be sent again.
    ///
    /// Text always can. An attachment can when its bytes are still on disk, or when it is
    /// already on the server and only the message pointing at it failed — a forward, or a send
    /// that broke off after the upload.
    public func canRetry(_ message: Message) -> Bool {
        guard message.didFailToSend else { return false }

        switch message.kind {
        case .text, .emote, .notice:
            return true
        case .image, .video, .audio, .file, .sticker:
            return message.mediaURL != nil || Outbox.holds(message.outboxFile)
        case .encrypted, .poll:
            return false
        }
    }

    /// Sends a message again after it failed. Same message, same transaction.
    public func retry(_ message: Message) async {
        guard canRetry(message), let conversation = message.conversation else { return }

        // To the bottom, where something you just sent belongs, and with a fresh ten minutes.
        message.timestamp = .now
        message.queuedAt = .now
        message.didFailToSend = false
        message.isPending = true
        conversation.lastActivity = message.timestamp
        saveContext()

        _ = await enqueue(message.id)?.value
    }

    /// Marks a message you sent as sent or failed, once the server has answered.
    ///
    /// Looked up again by its transaction ID rather than written to directly. The server's
    /// copy of the message comes back through the sync, and it can come back before the
    /// answer to sending it does — which one wins is chance. When the sync wins, it has
    /// already replaced this stand-in with the real message and deleted it, and writing to a
    /// deleted model is how SwiftData stops an app. Found by ID, a stand-in that has been
    /// replaced is simply not there any more, and there is nothing left to settle.
    func settle(_ transactionID: String, sent: Bool) {
        guard let stand = message(id: transactionID) else { return }
        stand.isPending = false
        stand.didFailToSend = !sent
    }

    /// Puts a new stand-in on screen and in the store, ready to be delivered.
    func queue(_ stand: Message, in conversation: Conversation, preview: String) {
        stand.queuedAt = .now
        stand.conversation = conversation
        insert(stand)

        conversation.lastActivity = stand.timestamp
        conversation.lastMessagePreview = preview
        noteCloseness(to: conversation, weight: 1)
        saveContext()
    }

    /// How many messages are waiting to go, for the status screen.
    public var outboxCount: Int {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.isPending && !$0.id.starts(with: "$") }
        )
        return (try? container.mainContext.fetchCount(descriptor)) ?? 0
    }
}

extension Message {
    /// Whether the bytes of this attachment are on this device, waiting to be sent.
    ///
    /// A picture you are sending can be shown from them straight away, rather than as a grey
    /// box until the server has it.
    public var hasLocalCopy: Bool {
        Outbox.holds(outboxFile)
    }

    /// Where those bytes are.
    public var localCopy: URL? {
        guard let outboxFile, Outbox.holds(outboxFile) else { return nil }
        return Outbox.url(for: outboxFile)
    }
}
