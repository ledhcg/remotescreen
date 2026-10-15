import Foundation
import Network
import RFBKit

/// Lời giải thích cho người dùng khi không kết nối được, kèm việc cần làm.
///
/// Tách khỏi giao diện để test được: đây là chỗ biến lỗi kỹ thuật thành chỉ dẫn, và là nơi một thông báo mơ hồ
/// ("Máy chủ chỉ cho phép cách xác thực mà ứng dụng chưa hỗ trợ") từng làm người dùng không biết mình sai ở đâu.
public enum ConnectionFailureMessage {
    /// - Parameter hasUsername: người dùng đã nhập tên tài khoản chưa. Mac cần tên tài khoản macOS; để trống thì app chỉ thử
    ///   mật khẩu VNC, thứ mà Mac chỉ nhận khi người dùng bật riêng trong Cài đặt hệ thống.
    public static func text(for error: Error, hasUsername: Bool) -> String {
        if let networkError = error as? NWError { return text(for: networkError) }
        guard let error = error as? RFBError else { return "Không kết nối được: \(error.localizedDescription)" }
        switch error {
        case .authenticationFailed, .serverRejected:
            return hasUsername
                ? "Sai tên tài khoản hoặc mật khẩu. Dùng tài khoản macOS của máy đó, và tài khoản phải được phép chia sẻ màn hình "
                    + "(Cài đặt hệ thống › Chung › Chia sẻ › Chia sẻ màn hình › Cho phép truy cập)."
                : "Mật khẩu không được chấp nhận. Nếu đây là máy Mac, hãy nhập cả tên tài khoản macOS, không chỉ mật khẩu."
        case .timedOut:
            return "Hết thời gian chờ. Kiểm tra địa chỉ, và Mac đang bật, không ngủ."
        case .connectionClosed:
            return "Máy chủ đã đóng kết nối."
        case .noCompatibleSecurityType(let offered):
            if !hasUsername, offered.contains(.appleRemoteDesktop) {
                return "Máy này đăng nhập bằng tên tài khoản và mật khẩu macOS. Hãy nhập tên tài khoản."
            }
            if hasUsername, !offered.contains(.appleRemoteDesktop),
               offered.contains(.vncAuthentication) || offered.contains(.noAuthentication) {
                return "Máy chủ này không hỗ trợ đăng nhập bằng tài khoản, chỉ có mật khẩu VNC (yếu, không mã hoá). "
                    + "Vì an toàn, ứng dụng không tự chuyển sang cách đó. Nếu vẫn muốn dùng, hãy bỏ trống tên tài khoản."
            }
            return "Máy chủ chỉ cho phép cách xác thực mà ứng dụng chưa hỗ trợ."
        case .credentialTooLong:
            return "Tên tài khoản hoặc mật khẩu quá dài (tối đa 63 byte)."
        default:
            return "Lỗi giao thức: \(error)"
        }
    }

    /// Lý do thôi nối lại sau khi một phiên đã từng sống.
    public static func giveUp(
        _ reason: ReconnectPolicy.GiveUpReason, error: Error, name: String, attempts: Int, hasUsername: Bool
    ) -> String {
        let detail = text(for: error, hasUsername: hasUsername)
        switch reason {
        case .authenticationFailed:
            return "Không nối lại được \(name): tên tài khoản hoặc mật khẩu không còn được chấp nhận."
        case .incompatible:
            return "Không nối lại được \(name): máy chủ không tương thích. (\(detail))"
        case .attemptsExhausted:
            return "Mất kết nối với \(name) và không nối lại được sau \(attempts) lần thử. "
                + "Kiểm tra Mac còn bật, không ngủ và cùng mạng. (\(detail))"
        }
    }

    /// Mã ngắn gọn để người dùng đọc lại khi báo lỗi, thay cho chuỗi mô tả dài của Swift.
    private static func code(of error: NWError) -> String {
        switch error {
        case .posix(let code): "POSIX \(code.rawValue)"
        case .dns(let code): "DNS \(code)"
        case .tls(let status): "TLS \(status)"
        default: "\(error)"
        }
    }

    /// Lỗi mạng kèm việc cần làm. Mã gốc được giữ ở cuối câu để báo lại khi cần chẩn đoán.
    static func text(for error: NWError) -> String {
        switch error {
        case .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.EHOSTUNREACH), .dns(-65570):
            return "Thiết bị chưa có đường mạng tới địa chỉ này. Kiểm tra: Wi-Fi đang bật và cùng mạng với Mac; "
                + "Cài đặt › RemoteScreen › Mạng cục bộ đang bật. (mã \(code(of: error)))"
        case .posix(.ECONNREFUSED):
            return "Mac từ chối kết nối. Bật Chia sẻ màn hình: Cài đặt hệ thống › Chung › Chia sẻ. (mã \(code(of: error)))"
        case .posix(.ETIMEDOUT):
            return "Mac không trả lời. Kiểm tra địa chỉ, và Mac đang bật, không ngủ. (mã \(code(of: error)))"
        default:
            return "Không kết nối được: \(error)"
        }
    }
}
