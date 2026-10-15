import Foundation

/// Sự kiện riêng của Apple gửi qua message loại 23 (`HandleEventMessage2` của `screensharingd`): cuộn mượt kiểu trackpad và
/// cử chỉ chụm, xoay. Server chuyển nguyên payload cho `ScreensharingAgent`, nơi dựng `CGEvent` thật rồi post lên Mac.
///
/// Bố cục đọc từ binary và đã thử trên Mac thật (một cửa sổ AppKit ghi lại `NSEvent` nhận được): xem `docs/protocol-notes.md`
/// mục 4h. Mọi số đều big-endian.
public enum AppleInputEvent: Equatable, Sendable {
    /// Loại 11: một `kCGEventScrollWheel` đầy đủ (quãng theo point, pha cuộn, pha quán tính).
    case scroll(AppleScroll)
    /// Loại 3: chụm (`magnification` của `NSEvent`: thay đổi tương đối, ví dụ 0,05 là phóng thêm 5%).
    case magnify(Double, phase: AppleGesturePhase, x: UInt16, y: UInt16)
    /// Loại 5: xoay, độ (dương là ngược chiều kim đồng hồ, như `NSEvent.rotation`).
    case rotate(Double, phase: AppleGesturePhase, x: UInt16, y: UInt16)

    /// Phiên bản payload. Chụm/xoay phải dùng bản 2 (có pha): Mac thật **bỏ qua** chụm/xoay bản 1, không ứng dụng nào nhận được.
    var version: UInt16 {
        switch self {
        case .scroll: 1
        case .magnify, .rotate: 2
        }
    }

    var kind: UInt16 {
        switch self {
        case .scroll: 11
        case .magnify: 3
        case .rotate: 5
        }
    }

    /// Payload (phần sau tiêu đề 4 byte của message 23).
    var payload: Data {
        var data = Data()
        data.appendBigEndian(version)
        data.appendBigEndian(kind)
        switch self {
        case .scroll(let scroll):
            data.append(scroll.body)
        case .magnify(let value, let phase, let x, let y), .rotate(let value, let phase, let x, let y):
            let finite = value.isFinite ? value : 0
            withUnsafeBytes(of: finite.bitPattern.bigEndian) { data.append(contentsOf: $0) }
            data.appendBigEndian(x)
            data.appendBigEndian(y)
            withUnsafeBytes(of: phase.rawValue.bigEndian) { data.append(contentsOf: $0) }
            // "Mask" (trường 133): thử 0, 2, 4, 8 trên Mac thật đều cho cùng kết quả.
            withUnsafeBytes(of: UInt64(0)) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// `[23][cờ = 0][u16 độ dài payload][payload]`.
    var wireBytes: Data {
        let payload = payload
        var data = Data([23, 0])
        data.appendBigEndian(UInt16(payload.count))
        data.append(payload)
        return data
    }
}

/// Pha của chụm/xoay (trường 132 của `CGEvent`), giá trị như pha cuộn. Trên Mac thật thành `NSEvent.phase` began, changed, ended.
public enum AppleGesturePhase: UInt64, Sendable {
    case began = 1, changed = 2, ended = 4
}

/// Một bước cuộn kiểu trackpad (`kCGEventScrollWheel` có pha), toạ độ là pixel framebuffer như `PointerEvent`.
public struct AppleScroll: Equatable, Sendable {
    /// `kCGScrollPhase`.
    public enum Phase: UInt32, Sendable {
        case none = 0, began = 1, changed = 2, ended = 4, cancelled = 8, mayBegin = 128
    }

    /// `kCGMomentumScrollPhase`: quán tính sau khi nhấc ngón.
    public enum Momentum: UInt32, Sendable {
        case none = 0, begin = 1, `continue` = 2, end = 3
    }

    /// Quãng cuộn theo point của Mac. Dương: nội dung đi xuống / sang phải (như vuốt xuống trên trackpad với cuộn tự nhiên).
    public var deltaX: Int32
    public var deltaY: Int32
    public var phase: Phase
    public var momentum: Momentum
    public var x: UInt16
    public var y: UInt16

    public init(deltaX: Int32, deltaY: Int32, phase: Phase, momentum: Momentum = .none, x: UInt16, y: UInt16) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.phase = phase
        self.momentum = momentum
        self.x = x
        self.y = y
    }

    /// Point mỗi "dòng" của bánh xe: trackpad thật báo quãng dòng khoảng bằng point / 10.
    static let pointsPerLine: Int32 = 10

    /// 50 byte sau loại: dòng (s16 ×3), dòng dạng 16.16 (s32 ×3), point (s32 ×3), pha, pha quán tính, số lần, cờ, x, y.
    /// Thứ tự trục trong từng nhóm là ngang, dọc, trục 3 (đúng thứ tự agent đọc: offset 4 → trục 2, offset 6 → trục 1).
    var body: Data {
        var data = Data()
        func s16(_ value: Int32) { data.appendBigEndian(UInt16(bitPattern: Int16(clamping: value))) }
        func s32(_ value: Int32) { data.appendBigEndian(UInt32(bitPattern: value)) }
        // Agent cộng thêm 1 vào độ lớn quãng dòng khác 0, nên gửi phần nguyên của point / 10 (0 khi cuộn ít).
        s16(deltaX / Self.pointsPerLine)
        s16(deltaY / Self.pointsPerLine)
        s16(0)
        s32(Int32(clamping: Int64(deltaX) * 65_536 / Int64(Self.pointsPerLine)))
        s32(Int32(clamping: Int64(deltaY) * 65_536 / Int64(Self.pointsPerLine)))
        s32(0)
        s32(deltaX)
        s32(deltaY)
        s32(0)
        data.appendBigEndian(phase.rawValue)
        data.appendBigEndian(momentum.rawValue)
        s32(0) // số lần cuộn liên tiếp: để agent/hệ thống tự tính
        data.appendBigEndian(UInt32(1 << 1)) // bit 1: `IsContinuous` (trackpad, không phải bánh xe nấc)
        data.appendBigEndian(x)
        data.appendBigEndian(y)
        return data
    }
}
