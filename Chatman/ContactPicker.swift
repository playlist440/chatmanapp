import ContactsUI
import SwiftUI

/// The system's own address book, for saying who somebody actually is.
///
/// Used in one place and for one reason: a conversation whose name can't be matched on a
/// phone number. Signal in particular lets people be reachable by username alone, and a chat
/// with one of them arrives named after their handle with nothing to look up. Rather than
/// invent a rename box, this asks the address book — so the name and the face come from the
/// same place as everybody else's, and stay right when you edit the contact later.
struct ContactPicker: UIViewControllerRepresentable {

    /// Called with the chosen name and picture, or with nothing when cancelled.
    let onPick: (String?, Data?) -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // What is shown in the picker's own list. What comes back is a separate matter —
        // see the delegate, which checks every key before reading it.
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        return picker
    }

    func updateUIViewController(_ picker: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        private let onPick: (String?, Data?) -> Void

        init(onPick: @escaping (String?, Data?) -> Void) {
            self.onPick = onPick
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            // Every one of these has to be asked for first. A `CNContact` only carries the
            // keys it was fetched with, and reading one it doesn't have doesn't return empty
            // — it raises an Objective-C exception, which in Swift means the app is gone.
            // The picker decides what it fetched, so nothing here may assume.
            func value(_ key: String, _ read: () -> String) -> String {
                contact.isKeyAvailable(key) ? read() : ""
            }

            let given = value(CNContactGivenNameKey) { contact.givenName }
            let family = value(CNContactFamilyNameKey) { contact.familyName }
            let nickname = value(CNContactNicknameKey) { contact.nickname }
            let organisation = value(CNContactOrganizationNameKey) { contact.organizationName }

            let name = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
            let chosen = nickname.isEmpty ? (name.isEmpty ? organisation : name) : nickname

            let photo = contact.isKeyAvailable(CNContactThumbnailImageDataKey)
                ? contact.thumbnailImageData
                : nil

            onPick(chosen.isEmpty ? nil : chosen, photo)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onPick(nil, nil)
        }
    }
}
