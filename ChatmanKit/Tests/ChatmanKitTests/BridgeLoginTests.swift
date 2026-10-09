import Testing
import Foundation
@testable import ChatmanKit

/// Tests for reading the bridge's login steps.
///
/// These shapes come straight from mautrix's own API description, so they're worth pinning:
/// a change here is what turns "scan this code" into a blank screen.
@Suite("Bridge login steps")
struct BridgeLoginTests {

    private func decode(_ json: String) throws -> MatrixAPI.BridgeLoginStep {
        try JSONDecoder().decode(MatrixAPI.BridgeLoginStep.self, from: Data(json.utf8))
    }

    @Test("A QR step carries the contents to draw")
    func qrStep() throws {
        let step = try decode("""
        {
          "login_id": "bls_d9odvo93kqebp739hrmg",
          "type": "display_and_wait",
          "step_id": "fi.mau.signal.qr",
          "instructions": "Scan the QR code",
          "display_and_wait": {
            "type": "qr",
            "data": "sgnl://linkdevice?uuid=abc&pub_key=def",
            "can_cancel": true
          }
        }
        """)

        #expect(step.kind == .displayAndWait)
        #expect(step.loginID == "bls_d9odvo93kqebp739hrmg")
        #expect(step.stepID == "fi.mau.signal.qr")
        #expect(step.instructions == "Scan the QR code")
        #expect(step.displayAndWait?.type == .qr)
        #expect(step.displayAndWait?.data == "sgnl://linkdevice?uuid=abc&pub_key=def")
    }

    @Test("A finished login is recognised")
    func completeStep() throws {
        let step = try decode("""
        {"login_id":"bls_x","type":"complete","step_id":"fi.mau.signal.done",
         "complete":{"user_login_id":"+31600000000"}}
        """)

        #expect(step.kind == .complete)
        #expect(step.displayAndWait == nil)
    }

    @Test("A step type this app can't show is kept rather than dropped")
    func unknownStepIsNamed() throws {
        // Decoding must not throw: a bridge for another network can return steps Chatman has
        // no screen for, and a clear message beats a crash or an empty view.
        let step = try decode("""
        {"login_id":"bls_y","type":"webauthn","step_id":"fi.mau.other.key"}
        """)

        #expect(step.kind == .webauthn)

        let future = try decode("""
        {"login_id":"bls_z","type":"something_invented_later","step_id":"x"}
        """)

        #expect(future.kind == .unsupported("something_invented_later"))
    }

    @Test("Login flows decode with the fields needed to pick one")
    func flows() throws {
        struct Wrapper: Decodable { let flows: [MatrixAPI.BridgeLoginFlow] }

        let wrapper = try JSONDecoder().decode(Wrapper.self, from: Data("""
        {"flows":[{"id":"qr","name":"QR code",
                   "description":"Log in by scanning a QR code on the Signal app"}]}
        """.utf8))

        #expect(wrapper.flows.count == 1)
        #expect(wrapper.flows.first?.id == "qr")
    }
}
