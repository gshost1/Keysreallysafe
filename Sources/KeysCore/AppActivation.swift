import AppKit
import WebKit

/// The app's Dock activation policy as one state machine. `.accessory` is the
/// resting state: the app owns long-lived services whether or not a window
/// exists, so activation follows window visibility, never process life. The
/// policy applier is injected, so tests record the transition sequence without
/// a window server.
@MainActor
final class AppActivation {
    enum Policy: Equatable {
        case accessory
        case regular
    }

    /// Every policy the app applied, in order; the seam tests read this.
    private(set) var applied: [Policy] = []
    private(set) var current: Policy
    private let apply: (Policy) -> Void

    /// A launch must apply its resting policy for real: NSApplication's own
    /// default is `.regular`, so headless launch cannot rely on the default.
    init(initial: Policy = .accessory, apply: ((Policy) -> Void)? = nil) {
        current = initial
        self.apply = apply ?? Self.applyPolicy
        applied = [initial]
        self.apply(initial)
    }

    /// The dashboard window became visible: Dock icon, menu bar, a normal app.
    func windowShown() {
        perform(.regular)
    }

    /// No window is visible any more: back to headless, services untouched.
    func windowHidden() {
        perform(.accessory)
    }

    private func perform(_ next: Policy) {
        guard next != current else { return }
        current = next
        applied.append(next)
        apply(next)
    }

    nonisolated static func applyPolicy(_ policy: Policy) {
        runOnMainActor { NSApplication.shared.setActivationPolicy(policy == .accessory ? .accessory : .regular) }
    }
}

/// The AppKit window behind the dashboard, behind a seam so the headless
/// lifecycle tests drive show and close with a fake — no real NSWindow is
/// created, ordered front or focused while the suite runs.
@MainActor
protocol DashboardWindow: AnyObject {
    /// Order the dashboard front (creating the window and its web view on
    /// first use) and focus the app.
    func orderFront()
    /// Runs when the person closes the window. Closing hides; it is not Quit.
    var onClosed: (() -> Void)? { get set }
    /// The AppKit window, for sheet modals; nil before first use or in a fake.
    var nsWindow: NSWindow? { get }
}

/// The real window: one WKWebView loading the loopback dashboard in a titled
/// NSWindow, created once on the first show and re-ordered front afterwards.
@MainActor
final class AppKitDashboardWindow: NSObject, DashboardWindow, NSWindowDelegate {
    private let url: URL
    /// Wiring the web view's delegates to its window controller, set by the
    /// controller after it is fully initialized.
    var configure: ((WKWebView) -> Void)?
    private var window: NSWindow?
    var onClosed: (() -> Void)?

    init(url: URL) {
        self.url = url
    }

    var nsWindow: NSWindow? { window }

    func orderFront() {
        if window == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let web = WKWebView(frame: .zero, configuration: configuration)
            configure?(web)
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "Keysrs"
            created.minSize = NSSize(width: 760, height: 560)
            created.isReleasedWhenClosed = false
            created.contentView = web
            created.center()
            created.delegate = self
            window = created
            web.load(URLRequest(url: url))
        }
        // A hidden app's windows stay hidden; the show path is also the unhide path.
        if NSApp.isHidden { NSApp.unhide(nil) }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClosed?()
    }
}
