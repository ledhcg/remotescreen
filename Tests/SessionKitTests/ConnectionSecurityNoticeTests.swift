import Testing
import RFBKit
@testable import SessionKit

@Suite("ConnectionSecurityNotice")
struct ConnectionSecurityNoticeTests {
    @Test func weakAuthenticationIsCalledOutAndAccountLoginIsNot() {
        #expect(ConnectionSecurityNotice.sessionWarning(for: .vncAuthentication)?.contains("yếu") == true)
        #expect(ConnectionSecurityNotice.sessionWarning(for: .noAuthentication)?.contains("không yêu cầu đăng nhập") == true)
        #expect(ConnectionSecurityNotice.sessionWarning(for: .appleRemoteDesktop) == nil)
        #expect(ConnectionSecurityNotice.sessionWarning(for: nil) == nil)
    }

    @Test func loginFooterSaysTheStreamIsNotEncrypted() {
        #expect(ConnectionSecurityNotice.loginFooter.contains("không được mã hoá"))
    }
}
