import Foundation
import RFBKit

/// Phím bổ trợ đang giữ. Khớp ý nghĩa của `UIKeyModifierFlags`, nhưng không phụ thuộc UIKit.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// Một lần nhấn hoặc nhả phím vật lý, đã tách khỏi `UIPress`.
public struct KeyPress: Sendable, Equatable {
    /// Mã HID Usage (Keyboard/Keypad page), ví dụ `0x28` là Return. Đây là định danh phím vật lý.
    public var hidUsage: Int
    /// Ký tự phím tạo ra, đã tính các phím bổ trợ (Shift ra chữ hoa...).
    public var characters: String
    /// Ký tự phím tạo ra khi bỏ qua các phím bổ trợ, trừ Shift.
    public var charactersIgnoringModifiers: String
    public var modifiers: KeyModifiers
    public var isDown: Bool

    public init(hidUsage: Int, characters: String = "", charactersIgnoringModifiers: String = "",
                modifiers: KeyModifiers = [], isDown: Bool) {
        self.hidUsage = hidUsage
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.isDown = isDown
    }
}

/// Đổi phím sang keysym X11 (`keysymdef.h`), thứ mà giao thức RFB dùng để nói "phím nào".
public enum KeysymMapper {
    /// Cách đặt tên keysym cho phím Command. **Chưa kiểm chứng với server Apple**: không rõ server hiểu Command là
    /// `Meta_L`, `Super_L` hay `Alt_L`. Giữ ở một chỗ để đổi được mà không sửa logic.
    public static let commandLeft: UInt32 = 0xFFE7 // Meta_L
    public static let commandRight: UInt32 = 0xFFE8 // Meta_R

    /// Phím không in ra ký tự, tra theo HID Usage.
    static let specialKeys: [Int: UInt32] = {
        var table: [Int: UInt32] = [
            0x28: 0xFF0D, // Return
            0x29: 0xFF1B, // Escape
            0x2A: 0xFF08, // Backspace
            0x2B: 0xFF09, // Tab
            0x39: 0xFFE5, // Caps Lock
            0x46: 0xFF61, // Print Screen
            0x47: 0xFF14, // Scroll Lock
            0x48: 0xFF13, // Pause
            0x49: 0xFF63, // Insert
            0x4A: 0xFF50, // Home
            0x4B: 0xFF55, // Page Up
            0x4C: 0xFFFF, // Delete (xóa tới)
            0x4D: 0xFF57, // End
            0x4E: 0xFF56, // Page Down
            0x4F: 0xFF53, // Phải
            0x50: 0xFF51, // Trái
            0x51: 0xFF54, // Xuống
            0x52: 0xFF52, // Lên
            0xE0: 0xFFE3, // Control trái
            0xE1: 0xFFE1, // Shift trái
            0xE2: 0xFFE9, // Option trái (Alt_L)
            0xE3: commandLeft,
            0xE4: 0xFFE4, // Control phải
            0xE5: 0xFFE2, // Shift phải
            0xE6: 0xFFEA, // Option phải (Alt_R)
            0xE7: commandRight,
        ]
        for index in 0..<12 { table[0x3A + index] = UInt32(0xFFBE + index) } // F1...F12
        for index in 0..<12 { table[0x68 + index] = UInt32(0xFFCA + index) } // F13...F24
        return table
    }()

    /// Keysym cho một lần nhấn, hoặc `nil` nếu phím không tạo ra gì gửi được.
    public static func keysym(for press: KeyPress) -> UInt32? {
        if let special = specialKeys[press.hidUsage] { return special }

        // Với Control, Command hoặc Option, ký tự đã bị đổi: thành mã điều khiển (Ctrl+C là 0x03), không ổn định
        // (Command), hoặc đã soạn sẵn (Option+X là `≈`). Dùng ký tự gốc của phím và để Mac từ xa tự soạn, giống bàn phím
        // Mac thật: Ctrl+C gửi `Control` rồi `c`, Option+X gửi `Alt` rồi `x`.
        let text = press.modifiers.isDisjoint(with: [.control, .command, .option]) ? press.characters : press.charactersIgnoringModifiers
        guard let scalar = text.unicodeScalars.first else { return nil }
        return keysym(forUnicode: scalar)
    }

    /// Chuỗi phím cho ⌘ + một ký tự: Command nhấn, ký tự nhấn rồi nhả, Command nhả. Dùng cho các tổ hợp mà iPadOS giữ lại cho
    /// chính nó (như ⌘F) nên không tới `pressesBegan`; `nil` nếu ký tự không đổi được sang keysym.
    ///
    /// - Parameter commandAlreadyDown: ⌘ đã được gửi xuống (người dùng đang giữ ⌘ thật, hoặc ⌘ đang dính trên thanh phím phụ).
    ///   Khi đó chỉ gửi ký tự: tự nhấn rồi nhả ⌘ sẽ làm Mac thấy ⌘ đã nhả trong khi ngón tay vẫn giữ, và phím kế tiếp (⌘G, ⌘V)
    ///   thành chữ thường.
    public static func commandChord(_ character: Character, commandAlreadyDown: Bool = false) -> [ClientMessage]? {
        guard let scalar = String(character).lowercased().unicodeScalars.first, let keysym = keysym(forUnicode: scalar) else { return nil }
        if commandAlreadyDown { return [.keyEvent(isDown: true, keysym: keysym), .keyEvent(isDown: false, keysym: keysym)] }
        return [
            .keyEvent(isDown: true, keysym: commandLeft), .keyEvent(isDown: true, keysym: keysym),
            .keyEvent(isDown: false, keysym: keysym), .keyEvent(isDown: false, keysym: commandLeft),
        ]
    }

    /// Latin-1 dùng thẳng mã Unicode làm keysym. Ký tự khác dùng dạng `0x01000000 + mã Unicode` mà X11 quy định.
    static func keysym(forUnicode scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x20...0x7E, 0xA0...0xFF: scalar.value
        case 0...0x1F, 0x7F...0x9F: nil // ký tự điều khiển
        default: 0x0100_0000 + scalar.value
        }
    }
}

/// Nhịp lặp phím khi giữ. Bàn phím thật của Mac lặp sau khoảng 0,4 giây, rồi khoảng 15 lần mỗi giây.
public enum KeyRepeat {
    public static let initialDelay: Duration = .milliseconds(400)
    public static let interval: Duration = .milliseconds(65)
    /// Lưới an toàn: lặp liên tục lâu hơn mức này thì dừng (lần nhả có thể đã bị một view khác nhận, nên ta không bao giờ thấy
    /// nó). Không ai giữ một phím 30 giây; còn Backspace lặp mãi trên Mac thì xóa sạch tài liệu.
    public static let maximumDuration: Duration = .seconds(30)
}

/// Phím đang được giữ mà máy từ xa nên thấy lặp lại.
public struct RepeatingKey: Equatable, Sendable {
    public var hidUsage: Int
    public var keysym: UInt32
}

/// Theo dõi các phím đang giữ để mỗi lần nhấn đều có đúng một lần nhả tương ứng.
///
/// Phím nhả phải dùng **cùng keysym với lúc nhấn**: nếu người dùng nhả Shift trước chữ cái thì lúc nhả ký tự đã
/// đổi từ `A` sang `a`, và server sẽ thấy `A` kẹt mãi.
public struct KeyboardState: Sendable {
    private var held: [(hidUsage: Int, keysym: UInt32)] = []

    public init() {}

    public var heldKeyCount: Int { held.count }

    /// Có phím nào đang giữ mà đã gửi keysym này không (ví dụ ⌘ trái 0xFFE7).
    public func isHolding(keysym: UInt32) -> Bool {
        held.contains { $0.keysym == keysym }
    }

    /// Phím cần lặp lúc này, hoặc `nil`. Máy từ xa không tự lặp phím do ta gửi (chỉ bàn phím vật lý mới sinh lặp), và iPadOS
    /// cũng không gửi lại `pressesBegan` cho phím đang giữ, nên giữ Backspace hay mũi tên sẽ chỉ ra một lần nếu không lặp thủ công.
    ///
    /// Như bàn phím thật: chỉ phím nhấn **sau cùng** lặp, nhả nó thì ngừng (phím nhấn trước đó không lặp tiếp), phím bổ trợ
    /// (Shift, Control, Option, Command, Caps Lock) không lặp.
    public private(set) var repeating: RepeatingKey?

    private static func isRepeatable(_ hidUsage: Int) -> Bool {
        !(0xE0...0xE7).contains(hidUsage) && hidUsage != 0x39
    }

    public mutating func handle(_ press: KeyPress) -> [ClientMessage] {
        if press.isDown {
            guard let keysym = KeysymMapper.keysym(for: press) else { return [] }
            if let index = held.firstIndex(where: { $0.hidUsage == press.hidUsage }) {
                held[index].keysym = keysym // lặp phím: gửi lại lần nhấn, không thêm mục giữ mới
                // Hệ điều hành tự gửi lần lặp thì để nó lo, không lặp chồng lên.
                if repeating?.hidUsage == press.hidUsage { repeating = nil }
            } else {
                held.append((press.hidUsage, keysym))
                repeating = Self.isRepeatable(press.hidUsage) ? RepeatingKey(hidUsage: press.hidUsage, keysym: keysym) : nil
            }
            return [.keyEvent(isDown: true, keysym: keysym)]
        }
        guard let index = held.firstIndex(where: { $0.hidUsage == press.hidUsage }) else { return [] }
        if repeating?.hidUsage == press.hidUsage { repeating = nil }
        let keysym = held.remove(at: index).keysym
        return [.keyEvent(isDown: false, keysym: keysym)]
    }

    /// Nhả mọi phím đang giữ, theo thứ tự ngược với lúc nhấn. Gọi khi mất focus, vào nền hoặc ngắt kết nối,
    /// để máy từ xa không bị kẹt phím (ví dụ Command không bao giờ được nhả).
    public mutating func releaseAll() -> [ClientMessage] {
        defer {
            held.removeAll()
            repeating = nil
        }
        return held.reversed().map { .keyEvent(isDown: false, keysym: $0.keysym) }
    }

    /// Gõ một chuỗi ký tự (cho bàn phím ảo): mỗi ký tự là một lần nhấn rồi nhả.
    /// Xuống dòng gửi Return, Tab gửi Tab. Ký tự không đổi được sang keysym bị bỏ qua.
    public static func typing(_ text: String) -> [ClientMessage] {
        text.unicodeScalars.flatMap { scalar -> [ClientMessage] in
            let keysym: UInt32? = switch scalar {
            case "\n", "\r": 0xFF0D
            case "\t": 0xFF09
            default: KeysymMapper.keysym(forUnicode: scalar)
            }
            guard let keysym else { return [] }
            return [.keyEvent(isDown: true, keysym: keysym), .keyEvent(isDown: false, keysym: keysym)]
        }
    }
}
