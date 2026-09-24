import SwiftUI
import AppKit

// The column of tabs, folded away with ⌘S or automatically.
//
// When folded, moving the mouse to the left edge smoothly slides out
// the column over the page. While open, moving the pointer outside starts a
// grace period before it retreats. If the pointer moves back toward the
// column while it is retreating or during the grace period, it catches the
// column mid-flight and glides it back open without any jitter.

extension Browser {
    /// ⌘S. The column, or the strip across the top, out of the way, or back.
    func toggleFold() {
        peeking = false
        withAnimation(Motion.glide) { folded.toggle() }
    }

    /// The folded column out over the page, or back in.
    func peek(_ out: Bool) {
        guard peeking != out else { return }
        withAnimation(Motion.glide) { peeking = out }
    }
}

/// Tracks pointer coordinates across the window using an AppKit event monitor,
/// providing instantaneous and glitch-free edge detection, hover tracking,
/// and mid-flight catch mechanics for the folded sidebar and top tab bar.
@MainActor
final class FoldTracker: ObservableObject {
    private weak var browser: Browser?
    private weak var prefs: Preferences?
    private var monitor: Any?
    private var retreatWorkItem: DispatchWorkItem?

    /// Active until this date: during retreat animation (~0.6s), entering
    /// the full active width immediately catches the retreating bar.
    private var retreatingUntil: Date = .distantPast

    /// Generous left edge reveal trigger zone (in window points).
    static let leftEdgeTrigger: CGFloat = 18
    /// Top edge reveal trigger zone (in window points).
    static let topEdgeTrigger: CGFloat = 14
    /// Comfortable margin beyond sidebar width where hover is considered active.
    static let sidebarBuffer: CGFloat = 24
    /// Grace duration before initiating retreat when cursor leaves.
    static let retreatGrace: TimeInterval = 0.25

    func start(browser: Browser, prefs: Preferences) {
        self.browser = browser
        self.prefs = prefs
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    func update(browser: Browser, prefs: Preferences) {
        self.browser = browser
        self.prefs = prefs
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        cancelRetreat()
    }

    private func cancelRetreat() {
        retreatWorkItem?.cancel()
        retreatWorkItem = nil
    }

    func handle(_ event: NSEvent) {
        guard let browser, let prefs else { return }
        guard browser.folded, browser.active?.immersed != true else {
            cancelRetreat()
            return
        }

        guard let window = Links.window ?? event.window, event.window === window else { return }

        let loc = event.locationInWindow
        let windowHeight = window.frame.height
        let windowWidth = window.frame.width

        // Clicking outside the peeking bar dismisses it immediately
        if event.type == .leftMouseDown {
            if browser.peeking, browser.editingTab == nil {
                let islandMargin: CGFloat = prefs.cardWindow ? 3 : 0
                if prefs.sidebar {
                    let inIslandX = loc.x >= islandMargin && loc.x <= prefs.sideWidth + islandMargin
                    let inIslandY = loc.y >= islandMargin && loc.y <= windowHeight - islandMargin
                    if !(inIslandX && inIslandY) {
                        cancelRetreat()
                        retreatingUntil = Date().addingTimeInterval(0.6)
                        browser.peek(false)
                    }
                } else if !prefs.sidebar, (windowHeight - loc.y) > Metrics.strip {
                    cancelRetreat()
                    retreatingUntil = Date().addingTimeInterval(0.6)
                    browser.peek(false)
                }
            }
            return
        }

        // Pointer outside window bounds
        guard loc.y >= 0, loc.y <= windowHeight, loc.x >= 0, loc.x <= windowWidth else {
            if browser.peeking { scheduleRetreat(browser: browser) }
            return
        }

        // While editing a tab title/address, don't retreat
        if browser.editingTab != nil { return }

        if prefs.sidebar {
            handleSidebar(loc: loc, browser: browser, prefs: prefs)
        } else {
            handleTopBar(loc: loc, windowHeight: windowHeight, browser: browser, prefs: prefs)
        }
    }

    private func handleSidebar(loc: CGPoint, browser: Browser, prefs: Preferences) {
        let islandMargin: CGFloat = prefs.cardWindow ? 3 : 0
        let activeWidth = prefs.sideWidth + islandMargin + Self.sidebarBuffer

        if loc.x <= activeWidth {
            // Inside active zone or edge trigger zone
            cancelRetreat()

            if browser.peeking {
                return
            }

            // Not currently peeking:
            // 1. If currently retreating (returning to the left), catch IMMEDIATELY!
            if Date() < retreatingUntil {
                retreatingUntil = .distantPast
                browser.peek(true)
                return
            }

            // 2. If at left edge trigger zone, reveal
            if loc.x <= Self.leftEdgeTrigger {
                browser.peek(true)
            }
        } else {
            // Beyond sidebar
            if browser.peeking {
                scheduleRetreat(browser: browser)
            }
        }
    }

    private func handleTopBar(loc: CGPoint, windowHeight: CGFloat, browser: Browser, prefs: Preferences) {
        let topDist = windowHeight - loc.y
        let activeHeight = Metrics.strip + 20

        if topDist <= activeHeight {
            cancelRetreat()

            if browser.peeking {
                return
            }

            // Catch mid-retreat immediately
            if Date() < retreatingUntil {
                retreatingUntil = .distantPast
                browser.peek(true)
                return
            }

            // Top edge trigger
            if topDist <= Self.topEdgeTrigger {
                browser.peek(true)
            }
        } else {
            if browser.peeking {
                scheduleRetreat(browser: browser)
            }
        }
    }

    private func scheduleRetreat(browser: Browser) {
        guard retreatWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self, weak browser] in
            guard let browser, browser.editingTab == nil else { return }
            self?.retreatingUntil = Date().addingTimeInterval(0.6)
            browser.peek(false)
            self?.retreatWorkItem = nil
        }
        retreatWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retreatGrace, execute: work)
    }

    func checkMousePosition() {
        guard let browser, let prefs, browser.folded, browser.active?.immersed != true else { return }
        guard let window = Links.window else { return }
        let loc = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let windowHeight = window.frame.height
        let windowWidth = window.frame.width

        let isInsideWindow = loc.x >= 0 && loc.x <= windowWidth && loc.y >= 0 && loc.y <= windowHeight
        if !isInsideWindow {
            if browser.peeking { scheduleRetreat(browser: browser) }
            return
        }

        let islandMargin: CGFloat = (prefs.sidebar && prefs.cardWindow) ? 3 : 0
        if prefs.sidebar {
            let activeWidth = prefs.sideWidth + islandMargin + Self.sidebarBuffer
            if loc.x > activeWidth && browser.peeking {
                scheduleRetreat(browser: browser)
            }
        } else {
            let topDist = windowHeight - loc.y
            let activeHeight = Metrics.strip + 20
            if topDist > activeHeight && browser.peeking {
                scheduleRetreat(browser: browser)
            }
        }
    }
}

/// Over the window's left edge while the column is folded, or its top edge
/// while the strip is: the band of edge that brings it out, and the column or
/// the strip itself while it is out.
struct Fold: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @StateObject private var tracker = FoldTracker()
    @Environment(\.colorScheme) private var colorScheme

    private var isIsland: Bool {
        prefs.cardWindow
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // In the column's mode the page reaches the window's top edge —
            // beside the column, and everywhere once it is folded away — and
            // there was nowhere there to drag the window from, or to
            // double-click to fill the screen: only the column's own corner,
            // gone when folded. A band too thin to be in a page's way stands
            // in for the title bar along the whole top; the column lies over
            // it with its own.
            if prefs.sidebar, browser.active?.immersed != true {
                DragStrip()
                    .frame(height: Metrics.cardInset)
                    .frame(maxWidth: .infinity)
            }

            // Top TabBar when folded
            if folding, !prefs.sidebar {
                TabBar(browser: browser)
                    .shadow(color: .black.opacity(0.14), radius: 20, y: 4)
                    .offset(y: browser.peeking ? 0 : -Metrics.strip - 25)
                    .allowsHitTesting(browser.peeking)
                    .animation(Motion.glide, value: browser.peeking)
            }

            // Sidebar when folded: floats as an island when cardWindow is enabled
            ZStack(alignment: .leading) {
                if folding, prefs.sidebar {
                    SideBar(browser: browser, prefs: prefs)
                        .clipShape(RoundedRectangle(cornerRadius: isIsland ? Metrics.cardRadius : 0, style: .continuous))
                        .overlay {
                            if isIsland {
                                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                                    .strokeBorder(Palette.hairline, lineWidth: 1)
                            }
                        }
                        .shadow(
                            color: Color.black.opacity(isIsland ? (colorScheme == .dark ? 0.35 : 0.16) : 0.14),
                            radius: isIsland ? 16 : 20,
                            x: isIsland ? 2 : 4,
                            y: isIsland ? 2 : 0
                        )
                        .padding(.leading, isIsland ? 3 : 0)
                        .padding(.vertical, isIsland ? 3 : 0)
                        .offset(x: browser.peeking ? 0 : -prefs.sideWidth - 35)
                        .allowsHitTesting(browser.peeking)
                        .animation(Motion.glide, value: browser.peeking)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear {
            tracker.start(browser: browser, prefs: prefs)
            hideLights()
        }
        .onDisappear {
            tracker.stop()
        }
        .background(WindowSetup { window in
            window.standardWindowButton(.closeButton)?.superview?.isHidden = lightsOff
        })
        .onChange(of: lightsOff) { _, _ in hideLights() }
        .onChange(of: prefs.sidebar) { _, _ in
            browser.folded = prefs.sidebar && prefs.sideHides
            browser.peeking = false
            tracker.update(browser: browser, prefs: prefs)
        }
        .onChange(of: prefs.sideHides) { _, hides in
            guard prefs.sidebar else { return }
            browser.peeking = false
            withAnimation(Motion.glide) { browser.folded = hides }
        }
        .onChange(of: prefs.sideWidth) { _, _ in
            tracker.update(browser: browser, prefs: prefs)
        }
        .onChange(of: browser.editingTab) { _, editing in
            if editing == nil, browser.peeking {
                tracker.checkMousePosition()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            tracker.checkMousePosition()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            tracker.checkMousePosition()
        }
    }

    /// Folded, and not taken over by a page filling the screen.
    private var folding: Bool {
        browser.folded && browser.active?.immersed != true
    }

    private var lightsOff: Bool {
        browser.folded && !browser.peeking
    }

    /// The title bar's own view holds the three buttons and the resting
    /// circles drawn over them while the app is behind (see RestingLights),
    /// so hiding it hides both, and hidden buttons take no clicks.
    private func hideLights() {
        guard let bar = Fold.titlebar else { return }
        if prefs.sidebar {
            Fold.slide(bar, off: lightsOff, by: prefs.sideWidth)
        } else {
            Fold.slide(bar, off: lightsOff, by: Metrics.strip, up: true)
        }
    }

    static var titlebar: NSView? {
        Links.window?.standardWindowButton(.closeButton)?.superview
    }

    /// Bumped by every slide, so one that was overtaken doesn't hide the
    /// lights on its way out.
    private static var slides = 0

    /// The lights ride with the column, as everything else in its corner
    /// does. Shown or hidden at once, they stood in their place while the
    /// column was still sliding in under them, and vanished before it had
    /// gone. So they come in from the left edge and go back off it, on the
    /// column's own spring (Motion.glide, in Core Animation's terms) — from
    /// wherever they are, when the pointer turns back halfway. `up`: off the
    /// top edge with the strip rather than off the left edge with the column.
    static func slide(_ bar: NSView, off: Bool, by width: CGFloat, up: Bool = false) {
        slides += 1
        let turn = slides
        guard let layer = bar.layer else {
            bar.isHidden = off
            return
        }
        // Up is +y in a superview that isn't flipped, -y in one that is.
        let path = up ? "transform.translation.y" : "transform.translation.x"
        let gone: CGFloat = up ? ((bar.superview?.isFlipped ?? false) ? -width : width) : -width
        let other = up ? "transform.translation.x" : "transform.translation.y"
        let moving = layer.animation(forKey: "fold") != nil
        // A slide still running on the other axis — the layout was switched
        // halfway — is simply let go.
        if moving, (layer.animation(forKey: "fold") as? CABasicAnimation)?.keyPath == other {
            layer.removeAnimation(forKey: "fold")
        }
        let still = layer.animation(forKey: "fold") != nil
        let from = still
            ? (layer.presentation()?.value(forKeyPath: path) as? CGFloat ?? 0)
            : (bar.isHidden ? gone : 0)
        let to: CGFloat = off ? gone : 0
        guard from != to else {
            layer.removeAnimation(forKey: "fold")
            bar.isHidden = off
            return
        }
        let spring = CASpringAnimation(keyPath: path)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.32, 2)
        spring.damping = 4 * .pi * 0.94 / 0.32
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        bar.isHidden = false
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard turn == slides else { return }
                layer.removeAnimation(forKey: "fold")
                bar.isHidden = off
            }
        }
        layer.add(spring, forKey: "fold")
        CATransaction.commit()
    }
}
