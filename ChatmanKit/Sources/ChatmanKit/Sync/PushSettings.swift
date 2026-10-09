import Foundation

/// Where notifications stand, in one value.
///
/// Push is the one feature Chatman can't finish on its own: it needs a certificate from a
/// paid Apple account and a gateway on your server to hand messages to Apple. Everything on
/// this side is built and waiting; this is what says which of the missing pieces you have.
public enum PushState: Equatable, Sendable {

    /// Nothing has been asked for yet.
    case off

    /// No gateway address, so there is nowhere to register.
    case noGateway

    /// The build has no push entitlement — a free developer account can't have one.
    case unavailable(String)

    /// Permission was refused on the device.
    case refused

    /// Asked, and waiting for a token.
    case registering

    /// Registered with your homeserver.
    case on

    /// The homeserver refused the registration.
    case failed(String)

    public var summary: String {
        switch self {
        case .off: String(localized: "Off", bundle: .module)
        case .noGateway: String(localized: "No gateway set", bundle: .module)
        case .unavailable: String(localized: "Not available in this build", bundle: .module)
        case .refused: String(localized: "Refused on this device", bundle: .module)
        case .registering: String(localized: "Registering…", bundle: .module)
        case .on: String(localized: "On", bundle: .module)
        case .failed: String(localized: "Something went wrong", bundle: .module)
        }
    }

    public var detail: String? {
        switch self {
        case .off:
            String(localized: "Chatman fetches messages while it's open. Notifications need a push gateway on your server and a paid Apple developer account.", bundle: .module)
        case .noGateway:
            String(localized: "Set the address of your push gateway under Advanced, then turn this on.", bundle: .module)
        case .unavailable(let why):
            why
        case .refused:
            String(localized: "Notifications are switched off for Chatman in the Settings app.", bundle: .module)
        case .registering:
            nil
        case .on:
            String(localized: "Your server will wake Chatman when something arrives. It sends only the event's ID — never the message.", bundle: .module)
        case .failed(let why):
            why
        }
    }
}
