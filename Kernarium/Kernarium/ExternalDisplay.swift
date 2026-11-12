// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import SwiftUI
import UIKit

/// The guest on an external screen, such as an AirPlay receiver. While one is
/// connected the guest display fills it and draws a cursor, and the phone
/// becomes the touchpad and keyboard that drive that cursor.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()

    @Published private(set) var isConnected = false

    private var window: UIWindow?
    private weak var home: GuestDisplayViewController?
    private let cursorView = UIImageView(
        image: UIImage(systemName: "cursorarrow")?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
    )
    private var cursor = CGPoint.zero

    private init() {
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorView.layer.shadowOpacity = 0.8
        cursorView.layer.shadowRadius = 1.5
        cursorView.layer.shadowOffset = .zero
        GuestDisplayViewController.didLoad = { controller in
            ExternalDisplay.shared.adopt(controller)
        }
    }

    func connect(_ window: UIWindow) {
        self.window = window
        isConnected = true
        moveDisplay()
    }

    func disconnect(_ window: UIWindow) {
        guard self.window === window else { return }
        self.window = nil
        isConnected = false
        cursorView.removeFromSuperview()
        home?.hostMetalView(in: nil)
    }

    private func adopt(_ controller: GuestDisplayViewController) {
        home = controller
        moveDisplay()
    }

    private func moveDisplay() {
        guard let window, let home,
              let container = window.rootViewController?.view else { return }
        home.hostMetalView(in: container)
        container.addSubview(cursorView)
        cursor = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        placeCursor()
    }

    // MARK: Touchpad

    /// Moves the cursor by a touchpad delta in phone points, scaled up to the
    /// larger screen and kept on it.
    func moveCursor(by delta: CGVector) {
        guard let bounds = home?.metalView.bounds, !bounds.isEmpty else { return }
        let speed: CGFloat = 1.6
        cursor.x = min(max(cursor.x + delta.dx * speed, bounds.minX), bounds.maxX - 1)
        cursor.y = min(max(cursor.y + delta.dy * speed, bounds.minY), bounds.maxY - 1)
        placeCursor()
    }

    /// A press at the cursor, which the guest reads as a touch there.
    func press(_ phase: GuestPointerPhase, offset: CGVector = .zero) {
        let point = CGPoint(x: cursor.x + offset.dx, y: cursor.y + offset.dy)
        home?.metalView.sendPointer(phase, at: point)
    }

    func click() {
        press(.began)
        press(.ended)
    }

    private func placeCursor() {
        let size = cursorView.image?.size ?? CGSize(width: 16, height: 22)
        // The arrow's tip is the hot spot, at the image's top-left.
        cursorView.frame = CGRect(
            x: cursor.x - size.width * 0.3, y: cursor.y - size.height * 0.15,
            width: size.width * 1.4, height: size.height * 1.4)
        cursorView.superview?.bringSubviewToFront(cursorView)
    }
}

/// The scene iOS gives the application for an external screen. It shows the
/// guest display there, and mirrors nothing.
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        window.isHidden = false
        self.window = window
        MainActor.assumeIsolated { ExternalDisplay.shared.connect(window) }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let window else { return }
        MainActor.assumeIsolated { ExternalDisplay.shared.disconnect(window) }
        self.window = nil
    }
}

/// Hands iOS the external-screen scene; the phone's own scene stays SwiftUI's.
final class KellyLinuxAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let role = connectingSceneSession.role
        let configuration = UISceneConfiguration(name: nil, sessionRole: role)
        if role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return configuration
    }
}

/// The phone's screen while the guest is on an external one: one finger
/// moves the cursor, a tap clicks, two fingers drag at the cursor to scroll,
/// and a tap followed by a held finger drags. It also takes the keyboard.
struct TouchpadView: UIViewRepresentable {
    let keyboardVisible: Bool

    func makeUIView(context: Context) -> TouchpadSurface {
        let surface = TouchpadSurface()
        surface.backgroundColor = UIColor(white: 0.08, alpha: 1)
        surface.isMultipleTouchEnabled = true
        return surface
    }

    func updateUIView(_ surface: TouchpadSurface, context: Context) {
        if keyboardVisible {
            surface.becomeFirstResponder()
        } else {
            surface.resignFirstResponder()
        }
    }
}

final class TouchpadSurface: UIView, UIKeyInput {
    private enum Mode {
        case idle
        case pointing
        case dragging
        case scrolling
    }

    private var mode = Mode.idle
    private var lastPoint = CGPoint.zero
    private var travel: CGFloat = 0
    private var startTime = Date.distantPast
    private var lastTapTime = Date.distantPast
    private var scrollOffset = CGVector.zero

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartDashesType: UITextSmartDashesType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    func insertText(_ text: String) { GuestKeyboardInput.type(text) }
    func deleteBackward() { GuestKeyboardInput.backspace() }

    private var display: ExternalDisplay {
        MainActor.assumeIsolated { ExternalDisplay.shared }
    }

    private func centroid(of touches: Set<UITouch>) -> CGPoint {
        let points = touches.map { $0.location(in: self) }
        let sum = points.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        return CGPoint(x: sum.x / CGFloat(max(points.count, 1)),
                       y: sum.y / CGFloat(max(points.count, 1)))
    }

    private func activeTouches(_ event: UIEvent?) -> Set<UITouch> {
        (event?.touches(for: self) ?? []).filter {
            $0.phase != .ended && $0.phase != .cancelled
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = activeTouches(event)
        lastPoint = centroid(of: active)
        if active.count >= 2 {
            if mode == .dragging { display.press(.ended) }
            mode = .scrolling
            scrollOffset = .zero
            display.press(.began)
            return
        }
        travel = 0
        startTime = Date()
        // A finger that lands soon after a tap holds the press and drags.
        if Date().timeIntervalSince(lastTapTime) < 0.3 {
            mode = .dragging
            display.press(.began)
        } else {
            mode = .pointing
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = activeTouches(event)
        let point = centroid(of: active)
        let delta = CGVector(dx: point.x - lastPoint.x, dy: point.y - lastPoint.y)
        lastPoint = point
        travel += hypot(delta.dx, delta.dy)
        switch mode {
        case .pointing:
            display.moveCursor(by: delta)
        case .dragging:
            display.moveCursor(by: delta)
            display.press(.moved)
        case .scrolling:
            // Content follows the fingers, as it does under a touch.
            scrollOffset.dx += delta.dx * 2
            scrollOffset.dy += delta.dy * 2
            display.press(.moved, offset: scrollOffset)
        case .idle:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(remaining: activeTouches(event).count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(remaining: activeTouches(event).count)
    }

    private func finish(remaining: Int) {
        guard remaining == 0 else { return }
        switch mode {
        case .pointing:
            if travel < 8, Date().timeIntervalSince(startTime) < 0.25 {
                display.click()
                lastTapTime = Date()
            }
        case .dragging:
            display.press(.ended)
            lastTapTime = .distantPast
        case .scrolling:
            display.press(.ended, offset: scrollOffset)
        case .idle:
            break
        }
        mode = .idle
    }
}
