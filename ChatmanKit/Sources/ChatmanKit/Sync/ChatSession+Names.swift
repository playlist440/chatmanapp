import Foundation
import SwiftData

/// Names that have to survive: the ones the phone hands the watch, and the ones you chose.
extension ChatSession {

    private enum NameKeys {
        static let contactNames = "chatman.received.contactNames"
        static let senderNames = "chatman.received.senderNames"
        static let photos = "chatman.received.photos"
        static let publishedChosen = "chatman.publishedChosenNames"
    }

    /// The account data type under which hand-chosen names for people are kept.
    static let chosenNamesType = "nl.chatman.names"

    /// On the watch: what the phone last sent, kept on the watch itself.
    ///
    /// The watch only ever learns these from the phone, and only while the two talk. Kept in
    /// memory alone, a watch app that started without the phone nearby knew nobody's name, and
    /// one that was installed again knew nobody's until the phone happened to send them.
    func restoreReceivedNames() {
        guard profile == .watch else { return }
        contactNames = defaults.dictionary(forKey: NameKeys.contactNames) as? [String: String] ?? [:]
        contactNamesByAccount = defaults.dictionary(forKey: NameKeys.senderNames) as? [String: String] ?? [:]
        contactPhotos = defaults.dictionary(forKey: NameKeys.photos) as? [String: Data] ?? [:]
    }

    /// Takes names from the phone. An empty list is not taken over a full one: the phone has
    /// nothing to say yet, which is not the same as everyone having lost their name.
    func receiveNames(_ names: [String: String]) {
        guard !names.isEmpty || contactNames.isEmpty else { return }
        contactNames = names
        defaults.set(names, forKey: NameKeys.contactNames)
    }

    func receiveSenderNames(_ names: [String: String]) {
        guard !names.isEmpty || contactNamesByAccount.isEmpty else { return }
        contactNamesByAccount = names
        defaults.set(names, forKey: NameKeys.senderNames)
    }

    func receivePhotos(_ photos: [String: Data]) {
        guard !photos.isEmpty || contactPhotos.isEmpty else { return }
        contactPhotos = photos
        defaults.set(photos, forKey: NameKeys.photos)
    }

    /// Takes the names you chose for people, as the account holds them.
    ///
    /// Kept with the account so that they reach the watch however the two devices are doing,
    /// and survive either app being deleted and put back.
    func applyChosenNames(_ chosen: [String: String]) {
        let cleaned = chosen.filter { !$0.value.isEmpty }
        if customAccountNames != cleaned { customAccountNames = cleaned }
    }

    /// Writes the names you chose for people to the account.
    func publishChosenNames() {
        guard profile == .phone, let api, let userID = credentials?.userID else { return }
        let names = customAccountNames
        Task {
            try? await api.setAccountData(
                MatrixAPI.ChosenNames(names: names), type: Self.chosenNamesType, for: userID
            )
        }
    }

    /// Once, for names chosen before they were kept with the account.
    func publishChosenNamesIfNeeded() {
        guard profile == .phone, !defaults.bool(forKey: NameKeys.publishedChosen),
              !customAccountNames.isEmpty
        else { return }
        publishChosenNames()
        defaults.set(true, forKey: NameKeys.publishedChosen)
    }
}
