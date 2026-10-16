import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Foundation
import SystemConfiguration

/// Names and addresses the iPad may try when it scans the pairing QR code. They are hints only: the iPad pins the Mac's key,
/// so a wrong or spoofed hint cannot redirect pairing to another machine.
enum HostHints {
    static let maxCount = 4

    static func current() -> [String] {
        var hints: [String] = []
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            hints.append(name + ".local")
        }
        // Keep room for a VPN address (Tailscale, 100.64.0.0/10 on a utun interface): away from home it is the only one the
        // iPad can reach. At most two LAN addresses, then the VPN one, then whatever is left.
        let lan = ipv4Addresses(prefix: "en")
        let vpn = ipv4Addresses(prefix: "utun").filter(isCarrierGradeNAT)
        hints.append(contentsOf: lan.prefix(2))
        hints.append(contentsOf: vpn.prefix(1))
        hints.append(contentsOf: lan.dropFirst(2))
        hints.append(contentsOf: vpn.dropFirst(1))
        var seen = Set<String>()
        return hints.filter { $0.utf8.count <= 253 && seen.insert($0).inserted }.prefix(maxCount).map { $0 }
    }

    /// 100.64.0.0/10, the range Tailscale (and other overlay VPNs) assign.
    static func isCarrierGradeNAT(_ text: String) -> Bool {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// IPv4 addresses of running interfaces whose name starts with `prefix` (`en` for Ethernet/Wi-Fi, `utun` for VPN tunnels),
    /// never loopback or link-local.
    static func ipv4Addresses(prefix: String = "en") -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard String(cString: entry.ifa_name).hasPrefix(prefix) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isUsableLANAddress(text) { result.append(text) }
        }
        return result
    }

    static func isUsableLANAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 169 && parts[1] == 254 { return false }  // link-local
        if parts[0] == 127 || parts[0] == 0 { return false }
        return true
    }
}

enum QRCode {
    /// A crisp (nearest-neighbour) QR image for `text`, `points` wide. Error correction M.
    static func image(for text: String, points: CGFloat = 260) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, (points * 2 / output.extent.width).rounded(.down))
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: points, height: points))
    }
}
