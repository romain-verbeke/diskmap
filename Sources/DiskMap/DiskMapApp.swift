import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
        model.handleLaunch()
    }

    /// The window is created here rather than by a SwiftUI WindowGroup, which sometimes
    /// launched with no window at all, so the app always opens one.
    private func showMainWindow() {
        let host = NSHostingController(rootView: ContentView(model: model).frame(minWidth: 900, minHeight: 560))
        host.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: host)
        window.title = "DiskMap"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1200, height: 780))
        window.center()
        window.setFrameAutosaveName("DiskMapMain")
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DiskMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Only here to carry the menu commands. The delegate owns the main window.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("New Scan") { delegate.model.startOver() }
                        .keyboardShortcut("n")
                    Button("Scan Folder…") { delegate.model.chooseFolder() }
                        .keyboardShortcut("o")
                }
            }
    }
}
