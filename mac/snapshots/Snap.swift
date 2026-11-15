// Screenshot mode for the README. Built only by snapshots/shoot.sh (-D SNAPSHOT), never
// into the real app. It runs AccountDeck against a demo home folder and lets the script
// steer it with distributed notifications: which page to show, light or dark, and the menu.
#if SNAPSHOT
import SwiftUI
import AppKit

@main
struct SnapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() { DispatchQueue.main.async { Snap.start() } }
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
enum Snap {
    static var panel: NSWindow?

    static func on(_ name: String, _ run: @escaping @MainActor (String?) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { n in
            let arg = n.object as? String
            MainActor.assumeIsolated { run(arg) }
        }
    }

    static func start() {
        for name in ["snap.select", "snap.tab", "snap.columns"] {
            on(name) {
                panel?.close(); panel = nil
                NSApp.activate(ignoringOtherApps: true)
                MainWindow.shared.window?.makeKeyAndOrderFront(nil)
                NotificationCenter.default.post(name: .init(name), object: $0)
            }
        }
        on("snap.appearance") { NSApp.appearance = NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua) }
        on("snap.size") { arg in
            let p = (arg ?? "").split(separator: ",").compactMap { Double($0) }
            guard p.count == 2, let w = MainWindow.shared.window else { return }
            w.setContentSize(NSSize(width: p[0], height: p[1]))
        }
        on("snap.menu") { _ in showPanel() }
        on("snap.quit") { _ in exit(0) }
    }

    /// The menu bar panel, in a window of its own so it can be captured.
    static func showPanel() {
        panel?.close()
        let host = NSHostingView(rootView: RootView().environmentObject(AppModel.shared))
        host.frame.size = host.fittingSize
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: host.fittingSize))
        fx.material = .popover; fx.state = .active; fx.blendingMode = .withinWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 14; fx.layer?.masksToBounds = true
        fx.addSubview(host)
        let w = NSWindow(contentRect: fx.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.title = "AccountDeck Menu"
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.isReleasedWhenClosed = false
        w.contentView = fx
        w.center()
        w.orderFrontRegardless()
        panel = w
    }
}
#endif
