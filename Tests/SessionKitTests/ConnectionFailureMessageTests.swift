import Foundation
import Network
import RFBKit
import Testing
@testable import SessionKit

@Suite("ConnectionFailureMessage: lỗi thành chỉ dẫn")
struct ConnectionFailureMessageTests {
    private func text(_ error: Error, user: Bool = true) -> String {
        ConnectionFailureMessage.text(for: error, hasUsername: user)
    }

    @Test func wrongPasswordWithAUserNamesTheAccountRequirement() {
        let message = text(RFBError.authenticationFailed(reason: ""))
        #expect(message.contains("tên tài khoản hoặc mật khẩu"))
        #expect(message.contains("Chia sẻ màn hình"))
    }

    /// Lỗi người dùng đã gặp: để trống tên rồi nhận thông báo không nói thiếu gì. Phải chỉ ra đúng việc cần làm.
    @Test func blankUsernameIsCalledOutBecauseMacsNeedAnAccountName() {
        let message = text(RFBError.authenticationFailed(reason: ""), user: false)
        #expect(message.contains("tên tài khoản macOS"))
        #expect(!message.contains("Sai tên tài khoản hoặc mật khẩu"), "không được đổ lỗi cho tên khi người dùng chưa nhập")
    }

    @Test func macOfferingOnlyAccountLoginAsksForTheUsername() {
        let error = RFBError.noCompatibleSecurityType(offered: [.appleRemoteDesktop])
        #expect(text(error, user: false).contains("nhập tên tài khoản"))
    }

    @Test func unsupportedAuthWithAUsernameStaysGeneric() {
        let error = RFBError.noCompatibleSecurityType(offered: [.appleRemoteDesktop])
        #expect(text(error, user: true).contains("chưa hỗ trợ"))
    }

    @Test func refusedDowngradeExplainsHowToUseWeakAuthOnPurpose() {
        let error = RFBError.noCompatibleSecurityType(offered: [.vncAuthentication])
        let message = text(error, user: true)
        #expect(message.contains("bỏ trống tên tài khoản"))
        #expect(message.contains("không tự chuyển"))
    }

    @Test(arguments: [NWError.posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.EHOSTUNREACH), .dns(-65570)])
    func noRouteTellsWhatToCheckAndKeepsTheCode(error: NWError) {
        let message = text(error)
        #expect(message.contains("Mạng cục bộ"))
        #expect(message.contains("mã"))
        #expect(!message.contains("iPad"), "dùng được cho cả iPhone")
    }

    @Test func refusedPointsAtScreenSharingSetting() {
        #expect(text(NWError.posix(.ECONNREFUSED)).contains("Bật Chia sẻ màn hình"))
    }

    @Test func timeoutsAreNotBlamedOnTheCredentials() {
        #expect(!text(RFBError.timedOut).contains("mật khẩu"))
        #expect(!text(NWError.posix(.ETIMEDOUT)).contains("mật khẩu"))
    }

    @Test func giveUpMessagesNameTheMachineAndTheAttempts() {
        let exhausted = ConnectionFailureMessage.giveUp(
            .attemptsExhausted, error: RFBError.connectionClosed, name: "Mac mini", attempts: 6, hasUsername: true
        )
        #expect(exhausted.contains("Mac mini"))
        #expect(exhausted.contains("6 lần"))
        let auth = ConnectionFailureMessage.giveUp(
            .authenticationFailed, error: RFBError.authenticationFailed(reason: ""), name: "Mac mini", attempts: 1, hasUsername: true
        )
        #expect(auth.contains("không còn được chấp nhận"))
    }
}
