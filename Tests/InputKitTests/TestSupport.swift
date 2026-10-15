import RFBKit
@testable import InputKit

extension Array where Element == InputIntent {
    /// The RFB messages these intents encode to, for tests that assert on wire behavior.
    var rfb: [ClientMessage] { RFBInputEncoder().encode(self) }
}

extension TouchOutput {
    /// RFB messages for `intents`, so wire-level assertions keep reading naturally.
    var messages: [ClientMessage] { intents.rfb }
}
