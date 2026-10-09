import AppKit
import SwiftUI

/// ChatGPT-style floating menu panel.
///
/// NSPopover always draws its own chrome (arrow beak, fixed corner radius,
/// denser material), which is why the menu never matched other menu-bar apps.
/// This controller instead uses a borderless, non-activating NSPanel whose
/// whole surface is real Liquid Glass (`NSGlassEffectView` on macOS 26+,
/// `NSVisualEffectView` earlier): big corner radius, floating below the status
/// item, no arrow, backdrop refraction.
///
/// Because the panel never takes focus, transient-dismissal doesn't apply;
/// mouse-downs outside the panel (but not on the status button that toggles
/// it, so the icon still works as a switch) close it via event monitors.
@MainActor
final class MenuPanelController: NSObject {
    /// Panels refuse key status by default; without it every control renders
    /// in the "window inactive" style — the switch track stays gray instead
    /// of the accent color. Overriding `canBecomeKey` lets the panel take key
    /// without activating the app (the point of `.nonactivatingPanel`).
    private final class KeyablePanel: NSPanel {
        /// Esc is the muscle-memory dismissal for any floating panel.
        var onEscape: (() -> Void)?

        override var canBecomeKey: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {  // Esc
                onEscape?()
                return
            }
            super.keyDown(with: event)
        }
    }

    private let panel: KeyablePanel
    private let hostingController: NSHostingController<AwakeKitPanelView>
    private weak var statusButton: NSStatusBarButton?
    private var monitors: [Any] = []
    /// Bumped by every show/close; a fade-out's completion handler only hides
    /// the panel when no newer show/close superseded it in the meantime.
    private var fadeEpoch = 0
    /// True between close() and the fade-out's completion; lets toggle() treat
    /// a fading-out panel as closed so a quick re-click reopens it.
    private var isFadingOut = false

    private let cornerRadius: CGFloat = 20
    private let gapBelowStatusBar: CGFloat = 8

    init(content: AwakeKitPanelView) {
        hostingController = NSHostingController(rootView: content)
        let surface = Self.makeSurface(cornerRadius: cornerRadius)
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.initialHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let container = NSView()
        container.addSubview(surface)
        container.addSubview(hostingController.view)
        panel.contentView = container

        // NSGlassEffectView keeps painting its square frame outside its own
        // cornerRadius, leaving translucent square stubs at the four corners,
        // and the window shadow follows that square content. Clip the whole
        // container to the panel outline so corners and shadow round off.
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true

        surface.autoresizingMask = [.width, .height]
        hostingController.view.autoresizingMask = [.width, .height]
        surface.frame = container.bounds
        hostingController.view.frame = container.bounds

        panel.onEscape = { [weak self] in self?.close() }
    }

    /// The glass surface; kept behind the SwiftUI content view.
    private static func makeSurface(cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            return glass
        }
        let vibrancy = NSVisualEffectView()
        vibrancy.material = .popover
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = cornerRadius
        vibrancy.layer?.masksToBounds = true
        return vibrancy
    }

    // MARK: Show / hide

    func toggle(_ statusItem: NSStatusItem) {
        if panel.isVisible, !isFadingOut {
            close()
        } else {
            show(statusItem)
        }
    }

    func show(_ statusItem: NSStatusItem) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        statusButton = button
        fadeEpoch += 1
        isFadingOut = false

        hostingController.rootView.panelIsVisible = true

        updateSize(animated: false)

        // Center the panel horizontally on the status icon, floating a few
        // points under the menu bar.
        let buttonFrameInScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        var frame = panel.frame
        frame.origin.x = buttonFrameInScreen.midX - frame.width / 2
        frame.origin.y = buttonFrameInScreen.minY - frame.height - gapBelowStatusBar
        if let screen = buttonWindow.screen {
            frame.origin.x = max(
                screen.visibleFrame.minX + 4,
                min(frame.origin.x, screen.visibleFrame.maxX - frame.width - 4)
            )
        }
        panel.setFrame(frame, display: false)

        button.cell?.isHighlighted = true
        startMonitors()
        // Reset the fade in a zero-duration group first: it cancels any
        // fade-out still in flight from a rapid previous toggle, which would
        // otherwise fight this fade-in and skip the animation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 0
        }
        // Key (not just front) so controls render in their active style.
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Fades the panel out, then orders it off. `fadeEpoch` guards the
    /// completion handler: a show() (or another close()) that happened while
    /// the fade was in flight supersedes it, so the panel never gets hidden
    /// out from under a newer animation.
    func close() {
        guard panel.isVisible else { return }
        stopMonitors()
        statusButton?.cell?.isHighlighted = false

        // Drop stale hover highlights before the fade: the pointer's
        // mouse-exited event may never reach SwiftUI once the window is off
        // screen, so the views would keep their old `hovering` state.
        hostingController.rootView.panelIsVisible = false

        isFadingOut = true
        fadeEpoch += 1
        let epoch = fadeEpoch
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // NSAnimationContext completions always run on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.fadeEpoch == epoch else { return }
                self.isFadingOut = false
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    /// Refits the panel to the SwiftUI content's intrinsic height, keeping the
    /// top edge anchored under the menu bar so it grows downward.
    func updateSize(animated: Bool = true) {
        let view = hostingController.view
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }

        let newHeight = ceil(fitting.height)
        let oldFrame = panel.frame
        guard abs(oldFrame.height - newHeight) > 0.5 else { return }

        var frame = oldFrame
        frame.size.height = newHeight
        frame.origin.y = oldFrame.maxY - newHeight

        if animated, panel.isVisible {
            panel.animator().setFrame(frame, display: true)
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: Click-outside dismissal

    private func startMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // Clicks anywhere outside our own process.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            monitors.append(monitor)
        }

        // Clicks inside our process but outside the panel. The status button
        // is exempt: its own action toggles the panel, and closing here first
        // would make the toggle reopen it.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window === self.panel { return }
                if event.window === self.statusButton?.window { return }
                self.close()
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func stopMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }
}
