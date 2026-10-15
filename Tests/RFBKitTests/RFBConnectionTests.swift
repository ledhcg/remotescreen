import Foundation
import Testing
@testable import RFBKit

@Suite("RFBConnection: chọn security type")
struct ChooseSecurityTypeTests {
    private let apple = RFBSecurityType(rawValue: 33) // type Apple chưa hỗ trợ

    @Test func prefersARDWhenThereIsAUsername() {
        // Thứ tự server Apple gửi thật: 30, 33, 36, 31, 32, 2, 35.
        let offered = [30, 33, 36, 31, 32, 2, 35].map { RFBSecurityType(rawValue: UInt8($0)) }
        #expect(RFBConnection.chooseSecurityType(from: offered, hasUsername: true) == .appleRemoteDesktop)
    }

    @Test func withoutUsernameARDIsSkippedAndVNCPasswordIsUsed() {
        let offered = [30, 33, 2].map { RFBSecurityType(rawValue: UInt8($0)) }
        #expect(RFBConnection.chooseSecurityType(from: offered, hasUsername: false) == .vncAuthentication)
    }

    @Test func neverDowngradesFromARDWhenThereIsAUsername() {
        // Server (hoặc kẻ ở giữa) chỉ chào type yếu: không được gửi phản hồi DES khi người dùng đã nhập tài khoản.
        #expect(RFBConnection.chooseSecurityType(from: [.vncAuthentication, .noAuthentication], hasUsername: true) == nil)
        #expect(RFBConnection.chooseSecurityType(from: [.vncAuthentication], hasUsername: true) == nil)
        #expect(RFBConnection.chooseSecurityType(from: [.noAuthentication], hasUsername: true) == nil)
    }

    @Test func noneIsChosenOnlyAsALastResort() {
        #expect(RFBConnection.chooseSecurityType(from: [.noAuthentication, .vncAuthentication], hasUsername: false) == .vncAuthentication)
        #expect(RFBConnection.chooseSecurityType(from: [.noAuthentication], hasUsername: false) == RFBSecurityType.noAuthentication)
    }

    @Test func returnsNilWhenNothingUsableIsOffered() {
        // Chỉ có các type Apple chưa hiểu, hoặc chỉ có ARD mà không có tên tài khoản.
        #expect(RFBConnection.chooseSecurityType(from: [apple, RFBSecurityType(rawValue: 35)], hasUsername: true) == nil)
        #expect(RFBConnection.chooseSecurityType(from: [.appleRemoteDesktop], hasUsername: false) == nil)
        #expect(RFBConnection.chooseSecurityType(from: [], hasUsername: true) == nil)
    }
}

@Suite("withDeadline")
struct WithDeadlineTests {
    @Test func returnsTheValueWhenTheOperationFinishesInTime() async throws {
        let value = try await withDeadline(.seconds(5), onTimeout: {}) { 42 }
        #expect(value == 42)
    }

    @Test func propagatesTheOperationsOwnError() async {
        await #expect(throws: RFBError.malformed("x")) {
            try await withDeadline(.seconds(5), onTimeout: {}) { () -> Int in throw RFBError.malformed("x") }
        }
    }

    @Test func alwaysReportsTimedOutAndCallsOnTimeoutFirst() async {
        let closed = OSFlag()
        await #expect(throws: RFBError.timedOut) {
            try await withDeadline(.milliseconds(50), onTimeout: { closed.set() }) { () -> Int in
                // Mô phỏng đọc không hủy được: chỉ kết thúc (bằng một lỗi KHÁC) sau khi luồng bị đóng.
                while !closed.isSet { try await Task.sleep(for: .milliseconds(5)) }
                throw RFBError.connectionClosed
            }
        }
        #expect(closed.isSet)
    }
}

/// Cờ thread-safe cho test.
final class OSFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
