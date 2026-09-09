import AppKit
import SwiftUI
import RecorderCore
import RecorderUI

@main
@MainActor
enum SystemAudioRecorderApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = RecorderAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class RecorderAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: RecorderModel?
    private var window: NSWindow?
    private var quitting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        let window = PlaybackWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "System Audio Recorder"
        window.minSize = NSSize(width: 620, height: 668)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("RecorderWindow")
        do {
            let model = RecorderModel(store: try SessionStore())
            self.model = model
            window.recorder = model
            window.contentView = NSHostingView(rootView: ContentView(model: model))
        } catch {
            window.contentView = NSHostingView(rootView:
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                    Text("Recording storage is unavailable").font(.title2)
                    Text(error.localizedDescription).multilineTextAlignment(.center).textSelection(.enabled)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    // Ask before the window disappears: cancelling Quit keeps recording controls visible.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !quitting else { return .terminateLater }
        if [.recording, .paused, .pausing, .resuming].contains(model.phase) {
            let alert = NSAlert()
            alert.messageText = "Stop and save before quitting?"
            alert.informativeText = "The recording will be stopped and saved. If saving fails, its source audio will remain available for recovery."
            alert.addButton(withTitle: "Stop, Save and Quit")
            alert.addButton(withTitle: "Keep Recording")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        quitting = true
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    @objc private func openRecordings() { model?.openStorage() }
    private func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About System Audio Recorder", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let folder = appMenu.addItem(withTitle: "Open Recordings Folder", action: #selector(openRecordings), keyEquivalent: "")
        folder.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide System Audio Recorder", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit System Audio Recorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (name, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windows = NSMenu(title: "Window"); windowItem.submenu = windows
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }
}
