import AppKit
import SwiftUI
import WidgetKit
import Combine

/// Borderless panel that can still take key focus so SwiftUI buttons work.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let model = PanelModel()
    private lazy var hosting = NSHostingController(rootView: UsagePanelView(model: model))
    private var panel: KeyablePanel!
    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var history = UsageHistory.load()

    private static let refreshInterval: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✳ …"
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        model.snapshot = Snapshot.load()
        model.history = history
        model.onRefresh = { [weak self] in self?.refresh() }
        model.onAdd = { [weak self] id in self?.captureAccount(providerID: id) }
        model.onRemove = { [weak self] key in self?.removeAccount(key: key) }
        model.onQuit = { NSApp.terminate(nil) }

        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 344, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting

        // Re-anchor the panel's top edge whenever its content height changes
        // (expanding a ring, or fresh data) so it grows downward, not up.
        model.$selectedKey.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutPanel() }
        }.store(in: &cancellables)
        model.$snapshot.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { if self?.panel.isVisible == true { self?.layoutPanel() } }
        }.store(in: &cancellables)

        updateStatusTitle()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Always nudge the widget to re-render on launch (picks up new views
        // even when the data itself is fresh).
        WidgetCenter.shared.reloadAllTimelines()
        // Only fetch on launch if the persisted snapshot is missing or stale,
        // so relaunching doesn't hammer the rate-limited usage endpoints.
        if model.snapshot == nil || Date().timeIntervalSince(model.snapshot!.updatedAt) > 120 {
            refresh()
        }
    }

    // MARK: URL open (widget tap → panel)

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "claudeusage" }) else { return }
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "account" })?.value
        DispatchQueue.main.async {
            if let key { self.model.selectedKey = key }
            if !self.panel.isVisible { self.openPanel() } else { self.layoutPanel() }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Panel

    @objc private func togglePanel() {
        panel.isVisible ? closePanel() : openPanel()
    }

    private func openPanel() {
        layoutPanel()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.layoutPanel() } // second pass after SwiftUI lays out
        installClickMonitor()
        if let snap = model.snapshot, Date().timeIntervalSince(snap.updatedAt) > 60 { refresh() }
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    private func layoutPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        hosting.view.layoutSubtreeIfNeeded()
        var size = hosting.view.fittingSize
        size.width = 344
        let x = min(anchor.minX, (button.window?.screen?.visibleFrame.maxX ?? anchor.maxX) - size.width - 8)
        let y = anchor.minY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let point = NSEvent.mouseLocation
            let onButton = self.statusButtonScreenRect()?.contains(point) ?? false
            if !self.panel.frame.contains(point) && !onButton { self.closePanel() }
            return event
        }
        // Clicks in other apps dismiss it too.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func statusButtonScreenRect() -> NSRect? {
        guard let button = statusItem.button, let w = button.window else { return nil }
        return w.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: Refresh

    private var refreshing = false

    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        model.refreshing = true
        Task {
            let snap = await UsageService.fetchAll()
            await MainActor.run {
                self.refreshing = false
                self.model.refreshing = false
                self.model.snapshot = snap
                self.history.record(snap)
                self.model.history = self.history
                UsageAlerts.evaluate(snap, history: self.history)
                self.updateStatusTitle()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    private func updateStatusTitle() {
        let worst = (model.snapshot?.accounts ?? [])
            .compactMap(\.headlineMetric)
            .max { $0.percent < $1.percent }
        guard let worst else {
            statusItem.button?.title = "✳ –"
            return
        }
        let color: NSColor = worst.percent >= 85 ? .systemRed
            : worst.percent >= 60 ? .systemOrange : .labelColor
        statusItem.button?.attributedTitle = NSAttributedString(
            string: "✳ \(Int(worst.percent))%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
            ]
        )
    }

    // MARK: Account management

    func captureAccount(providerID: String) {
        guard let provider = Providers.by(id: providerID) else { return }
        closePanel()
        Task {
            do {
                let before = Set(Keychain.savedAccountKeys())
                let accounts = try await provider.captureLiveAccounts()
                let new = accounts.filter { !before.contains($0.key) }
                let message: String
                if new.isEmpty {
                    message = "Refreshed \(accounts.count) existing account\(accounts.count == 1 ? "" : "s")"
                } else {
                    message = "Added \(new.map(\.email).joined(separator: ", "))"
                }
                await MainActor.run { self.notify(message) }
                self.refresh()
            } catch {
                await MainActor.run {
                    self.notify("Couldn’t add a \(provider.displayName) account — \(provider.captureHint) needed.")
                }
            }
        }
    }

    func removeAccount(key: String) {
        Keychain.deleteAccount(key: key)
        if model.selectedKey == key { model.selectedKey = nil }
        refresh()
    }

    private func notify(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
