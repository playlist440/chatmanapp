import Testing
import Foundation
@testable import ChatmanKit

/// Tests for how failures are classified.
///
/// The distinction that matters most here: "you typed the wrong address" versus "the server
/// said no". Getting it wrong means either asking for a server address when the password was
/// simply mistyped, or leaving someone stuck with a timeout and no way to correct it.
@Suite("Error classification")
struct ErrorTests {

    @Test("A server that can't be reached is treated as a wrong address")
    func unreachableServerAsksForAddress() {
        // This is exactly what a homeserver on port 8443 looks like: the well-known lookup
        // goes to 443, finds nothing listening, and times out.
        let timedOut = MatrixError.network(URLError(.timedOut))
        #expect(timedOut.suggestsWrongAddress)

        #expect(MatrixError.network(URLError(.cannotConnectToHost)).suggestsWrongAddress)
        #expect(MatrixError.network(URLError(.cannotFindHost)).suggestsWrongAddress)
        #expect(MatrixError.invalidHomeserver.suggestsWrongAddress)
    }

    @Test("Something that answers but isn't a homeserver counts as a wrong address")
    func notAHomeserverAsksForAddress() {
        #expect(MatrixError.unexpectedStatus(404).suggestsWrongAddress)
    }

    @Test("A refused password does not ask for a server address")
    func wrongPasswordIsNotAnAddressProblem() {
        let forbidden = MatrixError.api(
            MatrixErrorResponse(errcode: "M_FORBIDDEN", error: "Invalid password",
                                retryAfterMilliseconds: nil)
        )
        #expect(!forbidden.suggestsWrongAddress)
        // And it isn't worth retrying either.
        #expect(!forbidden.isTransient)
    }

    @Test("A server under load is retried, not questioned")
    func serverErrorsAreTransient() {
        let overloaded = MatrixError.unexpectedStatus(503)
        #expect(overloaded.isTransient)
        #expect(!overloaded.suggestsWrongAddress)
    }

    @Test("An expired session is recognised as needing a fresh sign-in")
    func expiredTokenRequiresSignIn() {
        let expired = MatrixError.api(
            MatrixErrorResponse(errcode: "M_UNKNOWN_TOKEN", error: nil,
                                retryAfterMilliseconds: nil)
        )
        #expect(expired.requiresSignIn)
        #expect(!expired.isTransient)
    }
}
