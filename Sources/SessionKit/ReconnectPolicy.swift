import Foundation
import RFBKit

/// Khi nào thử kết nối lại sau khi mất kết nối, và khi nào thôi.
///
/// Đây là một **quyết định về trải nghiệm**, không chỉ kỹ thuật: thử nhiều và lâu thì phiên liền mạch hơn nhưng pin và mạng
/// bị gọi lặp khi Mac đã tắt; thử ít thì người dùng phải bấm lại nhiều. Mặc định bên dưới là một lựa chọn hợp lý, dễ chỉnh.
public struct ReconnectPolicy: Equatable, Sendable {
    /// Thời gian chờ trước mỗi lần thử. Hết mảng thì bỏ cuộc. Lần đầu rất ngắn: phần lớn lần đứt là do app vừa quay lại
    /// từ nền, kết nối cũ đã chết, và kết nối mới thường lên ngay.
    public var delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    /// 0,5 s, 2 s, 4 s, 8 s, 15 s, 30 s: tổng khoảng một phút rưỡi chờ, đủ cho Mac thức dậy hay Wi-Fi nối lại.
    public static let standard = ReconnectPolicy(delays: [
        .milliseconds(500), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30),
    ])

    /// Không thử lại: mất kết nối là báo ngay.
    public static let never = ReconnectPolicy(delays: [])

    public var maxAttempts: Int { delays.count }

    public enum GiveUpReason: Equatable, Sendable {
        /// Sai tên tài khoản hay mật khẩu (hoặc server từ chối): thử lại chỉ làm khóa tài khoản.
        case authenticationFailed
        /// Server không tương thích: sai phiên bản, kiểu xác thực lạ, encoding lạ, dữ liệu sai giao thức.
        case incompatible
        /// Đã thử hết số lần cho phép.
        case attemptsExhausted
    }

    public enum Decision: Equatable, Sendable {
        /// Chờ `delay` rồi thử lần thứ `attempt` (đếm từ 1).
        case retry(after: Duration, attempt: Int)
        case giveUp(GiveUpReason)
    }

    /// - Parameters:
    ///   - error: lỗi làm đứt kết nối hay làm lần thử vừa rồi thất bại.
    ///   - attemptsMade: số lần đã thử lại (0 ở lần đứt đầu tiên).
    public func decision(after error: Error, attemptsMade: Int) -> Decision {
        if let reason = Self.permanentReason(for: error) { return .giveUp(reason) }
        guard attemptsMade >= 0, attemptsMade < delays.count else { return .giveUp(.attemptsExhausted) }
        return .retry(after: delays[attemptsMade], attempt: attemptsMade + 1)
    }

    /// Lỗi mà thử lại chắc chắn vô ích (hoặc có hại), khác với lỗi mạng tạm thời.
    static func permanentReason(for error: Error) -> GiveUpReason? {
        guard let error = error as? RFBError else { return nil } // lỗi mạng (NWError, POSIX, hủy): tạm thời
        switch error {
        case .authenticationFailed, .serverRejected, .credentialTooLong:
            return .authenticationFailed
        case .invalidVersionString, .unsupportedVersion, .unsupportedSecurityType, .invalidKeyExchange,
             .unsupportedEncoding, .noCompatibleSecurityType, .malformed:
            return .incompatible
        case .connectionClosed, .timedOut:
            return nil
        }
    }
}
