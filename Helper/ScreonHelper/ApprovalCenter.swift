import AppKit
import LinkTransport
import LocalAuthentication
import Observation
import os
import SwiftUI

/// What the approval window shows and does. The user must (1) look at the request, (2) press Approve, and (3) pass the Mac's
/// own authentication (Touch ID, Apple Watch or password). Anything else, including a timeout, a cancelled authentication or
/// a Mac that cannot authenticate, denies.
@MainActor @Observable
final class ApprovalViewModel {
    enum Phase { case asking, authenticating }

    let request: PairingApprovalRequest
    let deadline: Date
    var phase: Phase = .asking
    @ObservationIgnored var approve: () -> Void = {}
    @ObservationIgnored var deny: () -> Void = {}

    init(request: PairingApprovalRequest, deadline: Date) {
        self.request = request
        self.deadline = deadline
    }
}

@MainActor
final class ApprovalCenter {
    static let timeout: TimeInterval = 100  // below the link server's own 120 s approval timeout

    /// One approval on screen. Resolves its continuation exactly once.
    @MainActor private final class Active {
        let panel: NSPanel
        private var continuation: CheckedContinuation<Bool, Never>?
        private var timeout: Task<Void, Never>?
        var onFinish: () -> Void = {}

        init(panel: NSPanel, continuation: CheckedContinuation<Bool, Never>) {
            self.panel = panel
            self.continuation = continuation
        }

        func startTimeout() {
            timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(ApprovalCenter.timeout))
                guard !Task.isCancelled else { return }
                self?.resolve(false)
            }
        }

        func resolve(_ allowed: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            panel.orderOut(nil)
            onFinish()
            continuation.resume(returning: allowed)
        }
    }

    private var active: Active?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var busy = false
    private let log = Logger(subsystem: "app.screon.helper", category: "approval")

    /// Asks the person at the Mac. Requests are shown one at a time.
    func request(_ request: PairingApprovalRequest) async -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["SCREON_HELPER_AUTO_APPROVE"] == "1" {
            log.fault("SCREON_HELPER_AUTO_APPROVE=1: approving a pairing request WITHOUT asking (debug build only)")
            return true
        }
#endif
        await acquire()
        defer { release() }
        guard !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                present(request, continuation: continuation)
            }
        } onCancel: {
            // The link server cancels the handler when pairing is closed or the device goes away.
            Task { @MainActor in self.active?.resolve(false) }
        }
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private func present(_ request: PairingApprovalRequest, continuation: CheckedContinuation<Bool, Never>) {
        let model = ApprovalViewModel(request: request, deadline: Date().addingTimeInterval(Self.timeout))
        let hosting = NSHostingController(rootView: ApprovalView(model: model))
        let panel = NSPanel(contentViewController: hosting)
        panel.title = String(localized: "Screon Helper")
        panel.styleMask = [.titled]
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.center()

        let session = Active(panel: panel, continuation: continuation)
        session.onFinish = { [weak self] in self?.active = nil }
        model.deny = { [weak session] in session?.resolve(false) }
        model.approve = { [weak self, weak session] in
            guard let self, let session, model.phase == .asking else { return }
            model.phase = .authenticating
            let reason = Self.authenticationReason(request)
            Task { @MainActor in
                let ok = await self.authenticate(reason: reason)
                if !ok { self.log.notice("local authentication did not succeed; denied") }
                session.resolve(ok)
            }
        }
        session.startTimeout()
        active = session
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private static func authenticationReason(_ request: PairingApprovalRequest) -> String {
        switch request.reason {
        case .newPairing: String(format: String(localized: "pair with “%@”"), request.deviceName)
        case .session: String(format: String(localized: "let “%@” control this Mac"), request.deviceName)
        }
    }

    /// `.deviceOwnerAuthentication`: biometrics or Apple Watch, with the account password as the fallback.
    private func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        NSApp.activate()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            // LAError.userCancel, .systemCancel, .appCancel, .authenticationFailed, ...: all deny.
            return false
        }
    }
}

struct ApprovalView: View {
    @Bindable var model: ApprovalViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: model.request.sasCode == nil ? "ipad.and.arrow.forward" : "number.circle")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            title
            if let code = model.request.sasCode {
                Text(Self.grouped(code))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .textSelection(.disabled)
                    .accessibilityLabel(Text(code.map(String.init).joined(separator: " ")))
                Text("Do these digits match the iPad?")
                    .font(.headline)
            }
            Text("Approving lets this iPad see and control windows on this Mac. You will be asked to confirm with Touch ID or your password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(model.deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("Denied automatically in \(remaining) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Button("Deny", role: .cancel) { model.deny() }
                    .keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey(model.request.sasCode == nil ? "Approve…" : "They Match…")) { model.approve() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase != .asking)
            }
            if model.phase == .authenticating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    @ViewBuilder private var title: some View {
        let name = model.request.deviceName
        switch model.request.reason {
        case .newPairing: Text("Pair “\(name)” with this Mac?").font(.title3.bold()).multilineTextAlignment(.center)
        case .session: Text("Allow “\(name)” to connect?").font(.title3.bold()).multilineTextAlignment(.center)
        }
    }

    /// "123456" -> "123 456"
    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }
}
