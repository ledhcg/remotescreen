import Foundation
import os

/// Gộp các thông điệp đang chờ gửi: bỏ những lần **di chuột thuần** đã bị lần di sau thay thế.
///
/// Chỉ có tác dụng khi đường truyền đang nghẽn (nhiều thông điệp dồn lại trước một lần ghi); mạng thông thoáng thì mỗi lần
/// `post` được ghi riêng và không mất gì. Không bao giờ bỏ hay đổi thứ tự: lần nhấn hay nhả nút (kể cả nấc bánh xe), phím,
/// yêu cầu cập nhật, clipboard, message riêng của Apple.
public struct OutboundCoalescer: Sendable {
    /// Trạng thái nút của sự kiện chuột cuối cùng đã đi qua (giữ qua các lần gộp).
    public private(set) var lastButtons: UInt8 = 0

    public init() {}

    public mutating func coalesce(_ messages: [ClientMessage]) -> [ClientMessage] {
        var result: [ClientMessage] = []
        result.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            guard case .pointerEvent(let buttons, _, _) = message else {
                result.append(message)
                continue
            }
            // Di chuyển thuần: cùng nút với sự kiện chuột trước. Bỏ nếu ngay sau nó là một lần di khác cùng nút.
            let isPureMove = buttons == lastButtons
            if isPureMove, index + 1 < messages.count, case .pointerEvent(let nextButtons, _, _) = messages[index + 1],
               nextButtons == buttons {
                continue
            }
            result.append(message)
            lastButtons = buttons
        }
        return result
    }
}

/// Hàng đợi gửi của một phiên: `post` thêm vào và đánh thức task ghi; task ghi lấy hết những gì đang chờ, gộp, ghi một lần.
final class OutboundQueue: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (messages: [ClientMessage](), closed: false))
    private let signal: AsyncStream<Void>.Continuation
    /// Mỗi phần tử là một lần "có việc"; nhiều lần thêm khi task ghi đang bận chỉ để lại một tín hiệu.
    let wakeups: AsyncStream<Void>

    init() {
        (wakeups, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func append(_ messages: [ClientMessage]) {
        let accepted = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.messages += messages
            return true
        }
        if accepted { signal.yield() }
    }

    func takeAll() -> [ClientMessage] {
        state.withLock { state in
            defer { state.messages.removeAll(keepingCapacity: true) }
            return state.messages
        }
    }

    func close() {
        state.withLock { state in
            state.closed = true
            state.messages.removeAll()
        }
        signal.finish()
    }
}
