import AppKit
import SwiftUI

@MainActor
final class JBenchAppDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (() async -> String)?
    private var isTerminating = false
    private var snapshotWindow: NSWindow?
    private var snapshotStore: JBenchAppStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        prepareSnapshotWindowIfRequested()
    }

    private func prepareSnapshotWindowIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--snapshot"),
              arguments.indices.contains(flagIndex + 1) else { return }
        let destination = URL(fileURLWithPath: arguments[flagIndex + 1])

        let snapshotAppearance = snapshotAppearance(from: arguments)
        let store = JBenchAppStore(automaticallyRunsDemo: false, appearanceOverride: snapshotAppearance)
        let controller = NSHostingController(rootView: NewRunView(store: store).preferredColorScheme(snapshotAppearance.preferredColorScheme))
        let window = NSWindow(contentViewController: controller)
        window.title = "JBench"
        window.appearance = snapshotAppearance.nsAppearance
        window.setContentSize(NSSize(width: 1_420, height: 920))
        window.center()
        window.makeKeyAndOrderFront(nil)
        snapshotStore = store
        snapshotWindow = window

        Task { @MainActor in
            store.loadProviderFreeDemo()
            store.start(prompt: store.prompt, directory: store.directory, mode: store.executionMode, configurations: store.configurations)
            var requestedSnapshotJudging = false
            for _ in 0..<50 {
                let candidatesFinished = !store.lanes.isEmpty && !store.isBackgroundRunActive
                if candidatesFinished,
                   !store.judgeConfigurations.isEmpty,
                   store.judgeVotes.isEmpty,
                   !store.isJudgingActive,
                   !requestedSnapshotJudging {
                    requestedSnapshotJudging = true
                    store.rerunJudges()
                }
                let judgingFinished = store.judgeConfigurations.isEmpty || (!store.isJudgingActive && !store.judgeVotes.isEmpty)
                if candidatesFinished && judgingFinished { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            capture(window: window, to: destination)
        }
    }

    private func snapshotAppearance(from arguments: [String]) -> AppAppearance {
        guard let flagIndex = arguments.firstIndex(of: "--snapshot-appearance"),
              arguments.indices.contains(flagIndex + 1),
              let appearance = AppAppearance(rawValue: arguments[flagIndex + 1]) else { return .dark }
        return appearance
    }

    private func capture(window: NSWindow, to destination: URL) {
        guard let contentView = window.contentView,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            FileHandle.standardError.write(Data("Could not capture the JBench window.\n".utf8))
            NSApp.terminate(nil)
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Could not encode the JBench snapshot.\n".utf8))
            NSApp.terminate(nil)
            return
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Could not save the JBench snapshot: \(error)\n".utf8))
        }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if snapshotWindow != nil { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        guard let shutdownHandler else { return .terminateNow }
        isTerminating = true
        Task {
            _ = await shutdownHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct JBenchApp: App {
    @NSApplicationDelegateAdaptor(JBenchAppDelegate.self) private var appDelegate
    @State private var store = JBenchAppStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("JBench", id: "main") {
            ContentView(store: store)
                .preferredColorScheme(store.appearance.preferredColorScheme)
                .onAppear {
                    store.applyAppearanceToApplication()
                    appDelegate.shutdownHandler = { await store.shutdownForTermination() }
                }
        }
        .defaultSize(width: 1_420, height: 920)
        .commands {
            CommandMenu("Run") {
                Button("Start Run") { store.start(prompt: store.prompt, directory: store.directory, mode: store.executionMode, configurations: store.configurations) }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!store.canRun)
                Button("New Run") { store.section = .newRun }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView(store: store)
                .preferredColorScheme(store.appearance.preferredColorScheme)
        }

        MenuBarExtra("JBench · \(store.menuBarLabel)", systemImage: store.menuBarIcon) {
            Text(store.menuBarLabel)
                .fontWeight(.semibold)
            Text(store.statusMessage)
                .foregroundStyle(.secondary)
            Divider()
            Button("Open JBench") { openWindow(id: "main") }
            Button("New Run") { openWindow(id: "main"); store.section = .newRun }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
