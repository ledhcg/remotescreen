import AppKit
import SwiftUI

@main
struct ScreonHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = HelperModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(Text("Screon Helper"))
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showNotification = Notification.Name("app.screon.helper.show")

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0 != me && !$0.isTerminated }
        }
        // A relaunch started by the old instance: wait for it to quit instead of treating it as a second copy.
        if CommandLine.arguments.contains("--relaunch") {
            let deadline = Date().addingTimeInterval(5)
            while !others().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        }
        if let running = others().first {
            // Single instance: ask the running copy to show its setup window, then leave.
            DistributedNotificationCenter.default().postNotificationName(Self.showNotification, object: nil, userInfo: nil, deliverImmediately: true)
            running.activate()
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HelperModel.shared.showOnboarding() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await HelperModel.shared.launch() }
    }

    /// Quitting stops the service first, which puts every window the stage moved or resized back.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await HelperModel.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        // Do not hang forever if the service cannot stop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
