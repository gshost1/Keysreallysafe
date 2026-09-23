import AppKit

/// AppKit can leave a status item's remote scene disconnected after a display/session
/// transition even while isVisible remains true. Re-register the item after those
/// transitions; merely changing its title does not establish a fresh scene.
@MainActor
final class MenubarItemController {
    private(set) var item: NSStatusItem
    private let statusBar: NSStatusBar
    private let recoveryDelay: Duration
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var recoveryTask: Task<Void, Never>?
    private var pendingReason: String?
    private var stopped = false
    var menuIsOpen = false

    init(statusBar: NSStatusBar = .system,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         appCenter: NotificationCenter = .default,
         recoveryDelay: Duration = .seconds(2)) {
        self.statusBar = statusBar
        self.recoveryDelay = recoveryDelay
        item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Keysreallysafe.usage"
        item.button?.imagePosition = .noImage
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(name, center: workspaceCenter)
        }
        observe(NSApplication.didChangeScreenParametersNotification, center: appCenter)
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestRecovery(reason: name.rawValue)
            }
        }
        observers.append((center, token))
    }

    func checkVisibility() {
        // Do not infer failure from an offscreen frame: auto-hide, full screen, and
        // menu bar crowding can all hide a healthy item temporarily.
        if !item.isVisible || item.button == nil || item.button?.window == nil {
            requestRecovery(reason: "missing status item")
        }
    }

    func requestRecovery(reason: String) {
        guard !stopped else { return }
        pendingReason = reason
        recoveryTask?.cancel()
        let delay = recoveryDelay
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.recoverIfNeeded()
        }
    }

    func menuDidClose() {
        menuIsOpen = false
        if let reason = pendingReason { requestRecovery(reason: reason) }
    }

    private func recoverIfNeeded() {
        guard !stopped, !menuIsOpen, let reason = pendingReason else { return }
        pendingReason = nil
        let oldItem = item
        let menu = oldItem.menu
        let title = oldItem.button?.title ?? "Keysreallysafe"
        let tooltip = oldItem.button?.toolTip
        oldItem.menu = nil
        statusBar.removeStatusItem(oldItem)
        item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Keysreallysafe.usage"
        item.button?.imagePosition = .noImage
        item.button?.title = title
        item.button?.toolTip = tooltip
        item.menu = menu
        item.isVisible = true
        FileHandle.standardError.write(Data("menubar item recovered: \(reason)\n".utf8))
    }

    func stop() {
        stopped = true
        recoveryTask?.cancel()
        recoveryTask = nil
        pendingReason = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        item.menu = nil
        statusBar.removeStatusItem(item)
    }
}
