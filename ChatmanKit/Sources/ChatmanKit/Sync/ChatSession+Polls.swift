import Foundation

/// Voting, from this side of a bridge.
extension ChatSession {

    /// The answers you picked in a poll, whichever of your accounts the vote came from.
    ///
    /// A vote cast here comes back under your Matrix account; one cast in WhatsApp itself
    /// comes back under the account the bridge keeps for you there. Both are yours.
    public func myVote(in poll: Message) -> Set<String> {
        guard let votes = poll.poll?.votes else { return [] }
        return Set(votes.filter { isSelf($0.key) }.flatMap(\.value))
    }

    /// Picks an answer, or takes it back when it was already picked.
    ///
    /// With one answer allowed, picking another moves the vote. With more allowed, each tap
    /// adds or removes one, up to the limit. Shown at once and put back if the server says no —
    /// the same bargain as everything else you send.
    public func vote(for answer: String, in poll: Message) async {
        guard let api, let me = credentials?.userID,
              let room = poll.conversation?.id,
              var state = poll.poll, !state.isClosed
        else { return }

        let target = poll.id
        let before = state
        var picked = myVote(in: poll)

        if picked.contains(answer) {
            picked.remove(answer)
        } else if state.maxSelections <= 1 {
            picked = [answer]
        } else if picked.count < state.maxSelections {
            picked.insert(answer)
        } else {
            return
        }

        // In the poll's own order, which is the order the other side shows.
        let ordered = state.answers.map(\.id).filter(picked.contains)

        // Whatever you voted under another account is replaced: it is one person voting.
        for account in state.votes.keys where isSelf(account) {
            state.votes.removeValue(forKey: account)
        }
        state.record(ordered, by: me)
        poll.poll = state
        saveContext()

        do {
            try await api.vote(ordered, inPoll: target, in: room)
        } catch {
            if let current = message(id: target) {
                current.poll = before
                saveContext()
            }
        }
    }
}
