import Foundation

#if canImport(Contacts)
import Contacts

/// The names and pictures already on this device.
///
/// A bridge shows whatever name someone chose on Signal or WhatsApp, which is often a handle
/// rather than a name — the person saved in your phone as "Kyra" arrives as "bdbkyra". You
/// already decided what to call these people; this uses that decision.
///
/// Nothing leaves the device. The address book is read locally and matched against phone
/// numbers the bridge already knows, and no contact is ever sent to the server.
public enum ContactBook {

    /// One person from the device's address book.
    public struct Person: Sendable {
        public let name: String
        public let imageData: Data?
    }

    /// Whether reading contacts is allowed, without prompting.
    ///
    /// Since iOS 18 someone can grant access to a chosen few contacts instead of all of them.
    /// That counts: the app reads what it's given and matches what it can, which is exactly
    /// what this feature does anyway.
    public static var isAuthorised: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)

        #if os(iOS) || os(watchOS)
        if #available(iOS 18.0, watchOS 11.0, *) {
            return status == .authorized || status == .limited
        }
        #endif

        return status == .authorized
    }

    /// Asks for access, if it hasn't been decided yet.
    ///
    /// Returns false when refused. That's a normal answer, not an error: the app works fine
    /// without it, showing whatever names the networks provide.
    public static func requestAccess() async -> Bool {
        if isAuthorised { return true }

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .denied, .restricted: return false
        default: break
        }

        return await withCheckedContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Everyone with a phone number, keyed by a comparable form of that number.
    ///
    /// Numbers are stored in every imaginable shape — `06 12 34 56 78`, `+31612345678`,
    /// `0031-6-12345678` — so both sides are reduced to their last nine digits before being
    /// compared. That's enough to identify a subscriber without needing to know the country.
    public static func peopleByPhoneNumber() -> [String: Person] {
        guard isAuthorised else { return [:] }

        let keys: [any CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var result: [String: Person] = [:]

        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            let name = displayName(for: contact)
            guard !name.isEmpty else { return }

            let person = Person(name: name, imageData: contact.thumbnailImageData)

            for number in contact.phoneNumbers {
                let key = comparable(number.value.stringValue)
                guard !key.isEmpty else { continue }
                result[key] = person
            }
        }

        return result
    }

    /// Reduces a phone number to the part that identifies the subscriber.
    public static func comparable(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        return String(digits.suffix(9))
    }

    private static func displayName(for contact: CNContact) -> String {
        if !contact.nickname.isEmpty { return contact.nickname }

        let full = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return full.isEmpty ? contact.organizationName : full
    }
}
#endif
