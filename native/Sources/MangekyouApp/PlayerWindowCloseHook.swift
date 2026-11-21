import AppKit
import CoreFoundation
import SwiftUI

@MainActor
final class PlayerApplicationExit: NSObject, NSApplicationDelegate {
    private let windows = NSHashTable<PlayerWindowCloseHook.WindowView>.weakObjects()
    private var awaitingCleanup = false

    func register(_ view: PlayerWindowCloseHook.WindowView) { windows.add(view) }
    func unregister(_ view: PlayerWindowCloseHook.WindowView) { windows.remove(view) }

    func sharesSaveDirectory(_ view: PlayerWindowCloseHook.WindowView) -> Bool {
        guard let root = view.managedSaveRoot else { return false }
        return windows.allObjects.contains { $0 !== view && $0.managedSaveRoot == root }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if awaitingCleanup { return .terminateLater }
        let tasks = windows.allObjects.compactMap { view -> Task<Void, Never>? in
            if let cleanup = view.closeCleanup { return cleanup }
            guard view.managedSaveRoot != nil, !sharesSaveDirectory(view) else { return nil }
            return view.prepareClose?(.applicationQuit)
        }
        guard !tasks.isEmpty else { return .terminateNow }
        awaitingCleanup = true
        Task.detached(priority: .userInitiated) {
            for task in tasks { await task.value }
            // .terminateLater runs AppKit in modal-panel mode, which can
            // leave ordinary main-actor tasks waiting.
            let runLoop = CFRunLoopGetMain()
            let modes = [RunLoop.Mode.modalPanel.rawValue, RunLoop.Mode.common.rawValue] as CFArray
            CFRunLoopPerformBlock(runLoop, modes) {
                MainActor.assumeIsolated {
                    self.awaitingCleanup = false
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
            CFRunLoopWakeUp(runLoop)
        }
        return .terminateLater
    }
}

struct PlayerWindowCloseHook: NSViewRepresentable {
    enum Origin: String {
        case windowClose = "window_close"
        case applicationQuit = "application_quit"
    }

    let applicationExit: PlayerApplicationExit
    let managedSaveRoot: String?
    let probeClose: Bool
    let probeApplicationQuit: Bool
    let prepareClose: (Origin) -> Task<Void, Never>?

    func makeNSView(context: Context) -> WindowView {
        WindowView(frame: .zero)
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.applicationExit = applicationExit
        view.managedSaveRoot = managedSaveRoot
        view.prepareClose = prepareClose
        view.probeClose = probeClose
        view.probeApplicationQuit = probeApplicationQuit
        view.install()
    }

    static func dismantleNSView(_ view: WindowView, coordinator: ()) {
        view.prepareClose = nil
        view.detach()
    }

    final class WindowView: NSView, NSWindowDelegate {
        // Objective-C forwarding returns this on the same main thread.
        private struct ForwardedTarget: @unchecked Sendable {
            let delegate: any NSWindowDelegate
        }

        weak var applicationExit: PlayerApplicationExit?
        var managedSaveRoot: String?
        var prepareClose: ((Origin) -> Task<Void, Never>?)?
        var probeClose = false
        var probeApplicationQuit = false
        private(set) var closeCleanup: Task<Void, Never>?
        private weak var attachedWindow: NSWindow?
        private weak var previousDelegate: (any NSWindowDelegate)?
        private var didProbe = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        func install() {
            if attachedWindow !== window { detach() }
            guard let window else { return }
            applicationExit?.register(self)
            if window.delegate !== self {
                previousDelegate = window.delegate
                attachedWindow = window
                window.delegate = self
            }
            if (probeClose || probeApplicationQuit), !didProbe {
                didProbe = true
                Task { [weak self, weak window] in
                    guard let self else { return }
                    guard let window, attachedWindow === window, probeClose || probeApplicationQuit else {
                        didProbe = false
                        return
                    }
                    if probeApplicationQuit {
                        FileHandle.standardError.write(Data("player_application_quit_requested=1\n".utf8))
                        NSApp.terminate(nil)
                    } else {
                        window.performClose(nil)
                    }
                }
            }
        }

        func detach() {
            applicationExit?.unregister(self)
            if let attachedWindow, attachedWindow.delegate === self {
                attachedWindow.delegate = previousDelegate
            }
            attachedWindow = nil
            previousDelegate = nil
            closeCleanup = nil
            didProbe = false
        }

        override nonisolated func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (Thread.isMainThread && MainActor.assumeIsolated {
                previousDelegate?.responds(to: selector) == true
            })
        }

        override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
            guard Thread.isMainThread else { return super.forwardingTarget(for: selector) }
            let target = MainActor.assumeIsolated {
                previousDelegate.flatMap { delegate in
                    delegate.responds(to: selector) ? ForwardedTarget(delegate: delegate) : nil
                }
            }
            return target?.delegate ?? super.forwardingTarget(for: selector)
        }

        func windowShouldClose(_ window: NSWindow) -> Bool {
            guard closeCleanup == nil, previousDelegate?.windowShouldClose?(window) != false else { return false }
            guard applicationExit?.sharesSaveDirectory(self) != true,
                  let cleanup = prepareClose?(.windowClose) else { return true }
            closeCleanup = cleanup
            Task { [weak self, weak window] in
                await cleanup.value
                guard let self, let window, attachedWindow === window else { return }
                // The previous delegate has already authorized this close.
                window.close()
            }
            return false
        }

        func windowWillClose(_ notification: Notification) {
            if didProbe {
                FileHandle.standardError.write(Data("player_window_close_observed=1\n".utf8))
            }
            previousDelegate?.windowWillClose?(notification)
        }
    }
}
