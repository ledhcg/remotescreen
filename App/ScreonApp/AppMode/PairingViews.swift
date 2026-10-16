import AVFoundation
import ConnectionKit
import SwiftUI
import UIKit

/// Where a pairing stands.
@available(iOS 26, *)
enum PairingStep: Equatable {
    case choose
    /// Talking to the Mac; the person at the Mac may have to approve.
    case working
    /// Compare these six digits with the ones on the Mac.
    case confirmCode(String)
    case failed(String)
}

@available(iOS 26, *)
@MainActor
@Observable
final class PairingFlowModel {
    private(set) var step: PairingStep = .choose
    let computer: SavedConnection
    private let finish: @MainActor (PairingOutcome) -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var codeAnswer: CheckedContinuation<Bool, Never>?

    init(computer: SavedConnection, finish: @escaping @MainActor (PairingOutcome) -> Void) {
        self.computer = computer
        self.finish = finish
    }

    func pair(qrText: String, addressOverride: (host: String, port: UInt16?)? = nil) {
        run { [computer] in
            try await LinkPairing.pair(qrText: qrText, computerID: computer.id, addressOverride: addressOverride)
        }
    }

    func pairWithCode(host: String, port: UInt16) {
        run { [computer, flow = self] in
            try await LinkPairing.pairWithCode(host: host, port: port, computerID: computer.id) { code in
                await flow.askToCompare(code)
            }
        }
    }

    /// The person says whether the Mac shows the same digits.
    func answerCode(matches: Bool) {
        codeAnswer?.resume(returning: matches)
        codeAnswer = nil
        if !matches { step = .working }
    }

    func cancel() {
        task?.cancel()
        codeAnswer?.resume(returning: false)
        codeAnswer = nil
    }

    func backToStart() { step = .choose }

    private func askToCompare(_ code: String) async -> Bool {
        step = .confirmCode(code)
        return await withCheckedContinuation { codeAnswer = $0 }
    }

    private func run(_ work: @escaping @MainActor () async throws -> PairingOutcome) {
        guard step != .working else { return }
        step = .working
        task = Task {
            do {
                let outcome = try await work()
                finish(outcome)
            } catch {
                if !Task.isCancelled { step = .failed(LinkPairing.message(for: error)) }
            }
        }
    }
}

/// Set up App Mode for a saved computer: scan the code the Mac shows, paste its link, or compare six digits.
@available(iOS 26, *)
struct AppModePairingView: View {
    let computer: SavedConnection
    let model: ConnectionsModel
    let onDone: () -> Void

    @State private var flow: PairingFlowModel
    @State private var method = Method.scan
    @State private var pastedLink = ""
    @State private var host = ""
    @State private var port = ""
    @State private var scannerUnavailable = false

    enum Method: Hashable { case scan, link, code }

    init(computer: SavedConnection, model: ConnectionsModel, onDone: @escaping () -> Void) {
        self.computer = computer
        self.model = model
        self.onDone = onDone
        _flow = State(initialValue: PairingFlowModel(computer: computer) { outcome in
            var updated = computer
            updated.helper = outcome.helperEndpoint
            do { try model.save(updated, password: nil) } catch { model.lastError = error.localizedDescription }
            onDone()
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                switch flow.step {
                case .choose: chooser
                case .working: working
                case .confirmCode(let code): confirm(code)
                case .failed(let message): failure(message)
                }
            }
            .navigationTitle("Set up App Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        flow.cancel()
                        onDone()
                    }
                }
            }
        }
        .interactiveDismissDisabled(flow.step == .working)
    }

    // MARK: Steps

    @ViewBuilder private var chooser: some View {
        Section {
            Text("Open Screon Helper on “\(computer.name)” and choose Pair a Device. Then scan the code it shows, or use the other ways below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        Section {
            Picker("Method", selection: $method) {
                Text("Scan code").tag(Method.scan)
                Text("Paste link").tag(Method.link)
                Text("Pair with code").tag(Method.code)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pairing-method")
        }
        switch method {
        case .scan:
            Section {
                if scannerUnavailable {
                    Label("The camera is not available. Allow it in Settings, or paste the link instead.", systemImage: "camera.fill")
                        .foregroundStyle(.secondary)
                } else {
                    QRScannerView(onCode: { flow.pair(qrText: $0) }, onUnavailable: { scannerUnavailable = true })
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Camera for the pairing code")
                }
            }
        case .link:
            Section {
                TextField("screon-pair:…", text: $pastedLink, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(3...6)
                    .accessibilityIdentifier("pairing-link")
                Button("Pair") { flow.pair(qrText: pastedLink) }
                    .disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("Copy the pairing link from Screon Helper and paste it here.")
            }
        case .code:
            Section {
                TextField("Mac address", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("pairing-host")
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("pairing-port")
                Button("Show code") {
                    if let number = UInt16(port.trimmingCharacters(in: .whitespaces)), number > 0 {
                        flow.pairWithCode(host: host.trimmingCharacters(in: .whitespaces), port: number)
                    }
                }
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || UInt16(port.trimmingCharacters(in: .whitespaces)) == nil)
            } footer: {
                Text("Screon Helper shows the address and port. Both devices then show six digits to compare.")
            }
        }
    }

    private var working: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("Waiting for approval on the Mac…")
            }
            .accessibilityIdentifier("pairing-working")
        } footer: {
            Text("Approve this device on the Mac with Touch ID or the account password.")
        }
    }

    private func confirm(_ code: String) -> some View {
        Section {
            Text(code)
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("pairing-code")
            Button("The codes match") { flow.answerCode(matches: true) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pairing-match")
            Button("They are different", role: .destructive) { flow.answerCode(matches: false) }
        } header: {
            Text("Compare with the Mac")
        } footer: {
            Text("Pair only if the Mac shows exactly the same six digits.")
        }
    }

    private func failure(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityIdentifier("pairing-error")
            Button("Try again") { flow.backToStart() }
        }
    }
}

// MARK: - QR scanner

private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Camera preview that reports the first QR code carrying a Screon pairing link.
@available(iOS 26, *)
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {}
}

@available(iOS 26, *)
final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { [weak self] in
                    if granted { self?.configure() } else { self?.onUnavailable?() }
                }
            }
        default: onUnavailable?()
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return onUnavailable?() ?? () }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return onUnavailable?() ?? () }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        let box = Unchecked(value: session)
        DispatchQueue.global(qos: .userInitiated).async { box.value.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let box = Unchecked(value: session)
        DispatchQueue.global(qos: .userInitiated).async { if box.value.isRunning { box.value.stopRunning() } }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection
    ) {
        let text = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            .first { $0.hasPrefix("screon-pair:") }
        guard let text else { return }
        MainActor.assumeIsolated {
            guard !delivered else { return }
            delivered = true
            onCode?(text)
        }
    }
}

/// Presents the App Mode pairing sheet for a computer (iOS 26 and later; on older systems the sheet never appears).
struct AppModePairingSheet: ViewModifier {
    @Binding var computer: SavedConnection?
    let model: ConnectionsModel

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.sheet(item: $computer) { computer in
                AppModePairingView(computer: computer, model: model) { self.computer = nil }
            }
        } else {
            content
        }
    }
}
