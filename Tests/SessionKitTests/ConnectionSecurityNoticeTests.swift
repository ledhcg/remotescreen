import Localization
import Testing
import RFBKit
@testable import SessionKit

@Suite("ConnectionSecurityNotice")
struct ConnectionSecurityNoticeTests {
    init() { Localization.forcedLanguage = "en" }

    @Test func weakAuthenticationIsCalledOutAndAccountLoginIsNot() {
        #expect(ConnectionSecurityNotice.sessionWarning(for: .vncAuthentication)?.contains("weak") == true)
        #expect(ConnectionSecurityNotice.sessionWarning(for: .noAuthentication)?.contains("does not require a login") == true)
        #expect(ConnectionSecurityNotice.sessionWarning(for: .appleRemoteDesktop) == nil)
        #expect(ConnectionSecurityNotice.sessionWarning(for: nil) == nil)
    }

    @Test func loginFooterSaysTheStreamIsNotEncrypted() {
        #expect(ConnectionSecurityNotice.loginFooter.contains("not encrypted"))
    }
}
