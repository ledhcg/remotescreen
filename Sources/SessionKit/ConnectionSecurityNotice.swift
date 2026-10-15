import RFBKit

/// Lời nhắc về an toàn khi kết nối, tách khỏi giao diện để test được.
///
/// RFB không mã hoá luồng dữ liệu: màn hình, phím gõ và clipboard đi dạng rõ. Đăng nhập Apple (type 30) chỉ bảo vệ tên và
/// mật khẩu. Hai cách xác thực còn lại còn yếu hơn, nên được nhắc suốt phiên.
public enum ConnectionSecurityNotice {
    /// Hiện ở hộp thoại đăng nhập, trước khi người dùng gửi mật khẩu.
    public static let loginFooter =
        "Hình ảnh, phím gõ và clipboard không được mã hoá khi truyền. Chỉ dùng trong mạng tin cậy, hoặc đi qua VPN hay SSH."

    /// Cảnh báo hiện suốt phiên, hoặc `nil` nếu cách xác thực không đáng lo thêm.
    public static func sessionWarning(for type: RFBSecurityType?) -> String? {
        switch type {
        case .vncAuthentication?:
            return "Đăng nhập bằng mật khẩu VNC (yếu). Chỉ dùng trên mạng tin cậy."
        case .noAuthentication?:
            return "Máy này không yêu cầu đăng nhập. Bất kỳ ai trong mạng đều xem được."
        default:
            return nil
        }
    }
}
