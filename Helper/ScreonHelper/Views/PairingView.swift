import SwiftUI

/// The "Pair New iPad" window: a QR code (camera pairing) or instructions for "Pair Without Camera" (six digits).
struct PairingView: View {
    let model: HelperModel

    var body: some View {
        VStack(spacing: 14) {
            switch model.pairing {
            case .idle:
                ProgressView()
            case .qr(let image, _, let expiry):
                Text("Scan this code with Screon on your iPad.").font(.headline)
                if let image {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 260, height: 260)
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(Text("Pairing code"))
                }
                Countdown(expiry: expiry)
                AddressLine(model: model)
                Text("The code works once. Your Mac will ask you to confirm with Touch ID or your password.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            case .sas(let expiry):
                Image(systemName: "number.circle").font(.system(size: 40)).foregroundStyle(.tint).accessibilityHidden(true)
                Text("On your iPad, choose Pair Without Camera.").font(.headline)
                Text("Enter this address and port on the iPad. Six digits will then appear here and on the iPad. Confirm that they match.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                AddressLine(model: model)
                Countdown(expiry: expiry)
            case .paired(let name):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green).accessibilityHidden(true)
                if name.isEmpty {
                    Text("iPad paired.").font(.headline)
                } else {
                    Text("Paired with “\(name)”.").font(.headline)
                }
            case .failed:
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 40)).foregroundStyle(.orange).accessibilityHidden(true)
                Text("The pairing code expired.").font(.headline)
            }
            HStack {
                if case .qr = model.pairing {
                    Button("Copy Link") { model.copyPairingLink() }
                        .help(Text("For an iPad that cannot scan: paste the link in Screon, Set up App Mode, Paste link."))
                    Button("New Code") { model.beginQRPairing() }
                } else if case .failed = model.pairing {
                    Button("New Code") { model.beginQRPairing() }
                    Button("Pair Without Camera") { model.beginSASPairing() }
                }
                Button("Close") { model.windows.close(id: WindowID.pairing) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

/// The Mac's address and port as the iPad needs them for "Pair with code".
private struct AddressLine: View {
    let model: HelperModel

    var body: some View {
        if let address = model.pairingAddress {
            HStack(spacing: 16) {
                LabeledContent("Address") { Text(address.host).textSelection(.enabled) }
                LabeledContent("Port") { Text(String(address.port)).textSelection(.enabled) }
            }
            .font(.callout.monospaced())
            .accessibilityIdentifier("pairing-address")
        }
    }
}

private struct Countdown: View {
    let expiry: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(expiry.timeIntervalSince(context.date).rounded(.up)))
            Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
