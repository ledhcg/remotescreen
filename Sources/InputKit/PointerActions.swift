import RFBKit

/// Nhận biết các mốc của thao tác chuột trong dãy thông điệp gửi đi.
public enum PointerActions {
    /// `true` nếu có lúc nút chuột (trái, giữa, phải; không tính các nút bánh xe 4-7) chuyển từ đang nhấn sang nhả hết, tức một
    /// cú nhấp hay một lần kéo vừa xong. `previousButtons` mang trạng thái qua các lần gọi.
    public static func completesAButtonAction(_ messages: [ClientMessage], previousButtons: inout UInt8) -> Bool {
        var completed = false
        for case .pointerEvent(let buttons, _, _) in messages {
            let pressed = buttons & 0x07
            if previousButtons != 0, pressed == 0 { completed = true }
            previousButtons = pressed
        }
        return completed
    }
}
