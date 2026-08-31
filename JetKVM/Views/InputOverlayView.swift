import SwiftUI
import os

#if os(macOS)
import AppKit

/// A transparent NSView overlay that captures all mouse events for KVM input.
/// Uses NSTrackingArea for hover tracking and overrides mouse event methods.
struct InputOverlayView: NSViewRepresentable {
    let mouseManager: MouseManager
    let keyboardManager: KeyboardManager

    func makeNSView(context: Context) -> KVMInputNSView {
        let view = KVMInputNSView()
        view.mouseManager = mouseManager
        view.keyboardManager = keyboardManager
        return view
    }

    func updateNSView(_ view: KVMInputNSView, context: Context) {
        view.mouseManager = mouseManager
        view.keyboardManager = keyboardManager
    }
}

class KVMInputNSView: NSView {
    var mouseManager: MouseManager?
    var keyboardManager: KeyboardManager?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        // Keep MouseManager informed of view bounds
        Task { @MainActor in
            mouseManager?.viewBounds = CGRect(origin: .zero, size: bounds.size)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    // MARK: - Keyboard (handled via NSEvent monitor in KeyboardManager,
    //          but we override here to prevent system beeps for unhandled keys)

    override func keyDown(with event: NSEvent) {
        // Don't call super — that causes the system beep
    }

    override func keyUp(with event: NSEvent) {
        // Don't call super
    }

    // MARK: - Mouse Movement

    override func mouseMoved(with event: NSEvent) {
        sendPosition(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPosition(from: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPosition(from: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPosition(from: event)
    }

    // MARK: - Mouse Buttons

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convertToViewPoint(event)
        Task { @MainActor in
            mouseManager?.mouseDown(button: .left, at: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convertToViewPoint(event)
        Task { @MainActor in
            mouseManager?.mouseUp(button: .left, at: point)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convertToViewPoint(event)
        Task { @MainActor in
            mouseManager?.mouseDown(button: .right, at: point)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        let point = convertToViewPoint(event)
        Task { @MainActor in
            mouseManager?.mouseUp(button: .right, at: point)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        let point = convertToViewPoint(event)
        Task { @MainActor in
            mouseManager?.mouseDown(button: .middle, at: point)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        let point = convertToViewPoint(event)
        Task { @MainActor in
            mouseManager?.mouseUp(button: .middle, at: point)
        }
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        // Use scrollingDeltaY (continuous trackpad) or deltaY (discrete wheel)
        let dy: CGFloat
        let dx: CGFloat
        if event.hasPreciseScrollingDeltas {
            // Trackpad — scale down the deltas
            dy = -event.scrollingDeltaY / 10.0
            dx = event.scrollingDeltaX / 10.0
        } else {
            // Mouse wheel — use as-is
            dy = -event.scrollingDeltaY
            dx = event.scrollingDeltaX
        }
        Task { @MainActor in
            mouseManager?.scroll(deltaY: dy, deltaX: dx)
        }
    }

    // MARK: - Coordinate Conversion

    private func sendPosition(from event: NSEvent) {
        let point = convertToViewPoint(event)
        Task { @MainActor in
            mouseManager?.sendMousePosition(viewPoint: point)
        }
    }

    /// Convert NSEvent location to view coordinates (origin top-left).
    /// NSView has flipped=false by default, so origin is bottom-left — we flip Y.
    private func convertToViewPoint(_ event: NSEvent) -> CGPoint {
        let localPoint = convert(event.locationInWindow, from: nil)
        return CGPoint(x: localPoint.x, y: bounds.height - localPoint.y)
    }
}
#endif

#if os(iOS)
import UIKit

enum IOSInputMode: String, CaseIterable, Identifiable {
    case trackpad = "Trackpad"
    case absolute = "Absolute"
    case scroll = "Scroll"
    var id: Self { self }
}

/// A transparent UIView overlay that captures all touch/pointer events for KVM input.
struct InputOverlayView: UIViewRepresentable {
    let mouseManager: MouseManager
    let keyboardManager: KeyboardManager
    weak var viewModel: KVMViewModel?
    @Binding var zoomScale: CGFloat
    @Binding var zoomOffset: CGSize

    func makeUIView(context: Context) -> KVMInputUIView {
        let view = KVMInputUIView()
        view.mouseManager = mouseManager
        view.keyboardManager = keyboardManager
        view.viewModel = viewModel
        view.inputMode = viewModel?.inputMode ?? .trackpad
        view.localZoomScale = zoomScale
        view.positionZoomedCursor = { point, viewSize in
            zoomOffset = CGSize(
                width: -(point.x - viewSize.width / 2) * zoomScale,
                height: -(point.y - viewSize.height / 2) * zoomScale
            )
        }
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)

        // Three fingers pan the local video while zoomed.
        let zoomPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleZoomPan(_:)))
        zoomPan.minimumNumberOfTouches = 3
        zoomPan.maximumNumberOfTouches = 3
        view.addGestureRecognizer(zoomPan)

        // Enable pointer interaction for iPad mouse/trackpad support
        let pointerInteraction = UIPointerInteraction(delegate: context.coordinator)
        view.addInteraction(pointerInteraction)

        // Hover gesture for trackpad/mouse cursor tracking
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleHover(_:)))
        view.addGestureRecognizer(hover)

        // Scroll via two-finger pan (trackpad scroll)
        let scroll = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.maximumNumberOfTouches = 0 // Only trackpad scroll, not finger pans
        view.addGestureRecognizer(scroll)

        context.coordinator.view = view
        context.coordinator.zoomScale = $zoomScale
        context.coordinator.zoomOffset = $zoomOffset
        // Register with view model so it can toggle keyboard
        Task { @MainActor in viewModel?.inputView = view }
        return view
    }

    func updateUIView(_ view: KVMInputUIView, context: Context) {
        view.mouseManager = mouseManager
        view.keyboardManager = keyboardManager
        view.viewModel = viewModel
        view.inputMode = viewModel?.inputMode ?? .trackpad
        view.localZoomScale = zoomScale
        view.positionZoomedCursor = { point, viewSize in
            zoomOffset = CGSize(
                width: -(point.x - viewSize.width / 2) * zoomScale,
                height: -(point.y - viewSize.height / 2) * zoomScale
            )
        }
        context.coordinator.view = view
        context.coordinator.zoomScale = $zoomScale
        context.coordinator.zoomOffset = $zoomOffset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
        weak var view: KVMInputUIView?
        private var lastScrollTranslation: CGPoint = .zero
        private var lastMoveTranslation: CGPoint = .zero
        private var pinchStartScale: CGFloat = 1
        private var panStartOffset: CGSize = .zero
        private var lastDragPoint: CGPoint = .zero
        private var isClickDragging = false
        var zoomScale: Binding<CGFloat>?
        var zoomOffset: Binding<CGSize>?

        @objc func handleTrackpadMove(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? KVMInputUIView else { return }
            guard !isClickDragging else { return }
            if gesture.state == .began { lastMoveTranslation = .zero }
            if gesture.state == .changed {
                let translation = gesture.translation(in: view)
                let dx = translation.x - lastMoveTranslation.x
                let dy = translation.y - lastMoveTranslation.y
                lastMoveTranslation = translation
                Task { @MainActor in view.mouseManager?.sendRelativeMovement(dx: dx * 1.35, dy: dy * 1.35) }
            }
            if gesture.state == .ended || gesture.state == .cancelled { lastMoveTranslation = .zero }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? KVMInputUIView else { return }
            let button: MouseButton = gesture.numberOfTouches == 2 ? .right : .left
            Task { @MainActor in
                view.mouseManager?.sendRelativeMovement(dx: 0, dy: 0, buttons: button.hidBit)
                try? await Task.sleep(for: .milliseconds(30))
                view.mouseManager?.sendRelativeMovement(dx: 0, dy: 0, buttons: 0)
            }
        }

        @objc func handleClickDrag(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view as? KVMInputUIView else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began:
                isClickDragging = true
                lastDragPoint = point
                Task { @MainActor in view.mouseManager?.relativeMouseDown(button: .left) }
            case .changed:
                let dx = point.x - lastDragPoint.x
                let dy = point.y - lastDragPoint.y
                lastDragPoint = point
                Task { @MainActor in view.mouseManager?.sendRelativeMovement(dx: dx * 1.35, dy: dy * 1.35) }
            case .ended, .cancelled, .failed:
                isClickDragging = false
                Task { @MainActor in view.mouseManager?.relativeMouseUp(button: .left) }
            default:
                break
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scale = zoomScale,
                  let view = gesture.view as? KVMInputUIView else { return }
            if gesture.state == .began {
                pinchStartScale = scale.wrappedValue
                if pinchStartScale <= 1.01 {
                    let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                    view.zoomCursorPoint = center
                    Task { @MainActor in view.mouseManager?.sendMousePosition(viewPoint: center) }
                }
            }
            if gesture.state == .changed {
                scale.wrappedValue = min(4, max(1, pinchStartScale * gesture.scale))
            }
            if gesture.state == .ended, scale.wrappedValue <= 1.01 {
                scale.wrappedValue = 1
                zoomOffset?.wrappedValue = .zero
            }
        }

        @objc func handleTouchScroll(_ gesture: UIPanGestureRecognizer) {
            handleScroll(gesture)
        }

        @objc func handleZoomPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? KVMInputUIView,
                  (zoomScale?.wrappedValue ?? 1) > 1.01 else { return }
            if gesture.state == .began { panStartOffset = zoomOffset?.wrappedValue ?? .zero }
            if gesture.state == .changed {
                let t = gesture.translation(in: view)
                zoomOffset?.wrappedValue = CGSize(
                    width: panStartOffset.width + t.x,
                    height: panStartOffset.height + t.y
                )
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer {
                return true
            }
            let pair = [gestureRecognizer, otherGestureRecognizer]
            return pair.contains { $0 is UILongPressGestureRecognizer }
                && pair.contains { $0 is UIPanGestureRecognizer }
        }

        @objc func handleHover(_ gesture: UIHoverGestureRecognizer) {
            guard let view = gesture.view as? KVMInputUIView else { return }
            let point = gesture.location(in: view)
            switch gesture.state {
            case .began, .changed:
                Task { @MainActor in
                    view.mouseManager?.sendMousePosition(viewPoint: point)
                }
            default:
                break
            }
        }

        @objc func handleScroll(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? KVMInputUIView else { return }
            switch gesture.state {
            case .began:
                lastScrollTranslation = .zero
            case .changed:
                let translation = gesture.translation(in: view)
                let dx = translation.x - lastScrollTranslation.x
                let dy = translation.y - lastScrollTranslation.y
                lastScrollTranslation = translation
                Task { @MainActor in
                    view.mouseManager?.scroll(deltaY: -dy / 10.0, deltaX: dx / 10.0)
                }
            default:
                lastScrollTranslation = .zero
            }
        }

        func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
            return defaultRegion
        }

        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            // Show a small crosshair so the user can see where they're pointing
            let params = UIPointerShape.roundedRect(CGRect(x: -2, y: -2, width: 4, height: 4), radius: 2)
            return UIPointerStyle(shape: params)
        }
    }
}

class KVMInputUIView: UIView, UIKeyInput {
    var mouseManager: MouseManager?
    var keyboardManager: KeyboardManager?
    weak var viewModel: KVMViewModel?
    var inputMode: IOSInputMode = .trackpad
    var localZoomScale: CGFloat = 1
    var positionZoomedCursor: ((CGPoint, CGSize) -> Void)?
    var zoomCursorPoint: CGPoint = .zero
    private var touchStartTime: TimeInterval = 0
    private var touchStartPoint: CGPoint = .zero
    private var lastTouchPoint: CGPoint = .zero
    private var touchMoved = false
    private var clickDragActive = false
    private var gestureFingerCount = 0
    private var rightClickSent = false
    private var lastRightClickTime: TimeInterval = 0
    private var lastCompletedTapTime: TimeInterval = -.infinity
    private var clickDragArmed = false

    private func fingerTouches(from event: UIEvent?) -> [UITouch] {
        (event?.allTouches ?? []).filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }
    }

    private func centroid(_ touches: [UITouch]) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        let total = touches.reduce(CGPoint.zero) { result, touch in
            let point = touch.location(in: self)
            return CGPoint(x: result.x + point.x, y: result.y + point.y)
        }
        return CGPoint(x: total.x / CGFloat(touches.count), y: total.y / CGFloat(touches.count))
    }

    private func debug(_ message: String) {
        Task { @MainActor in viewModel?.inputDebugMessage = message }
    }

    // Empty view returned as inputView to suppress the software keyboard
    private let emptyInputView = UIView(frame: .zero)
    private var latchedModifiers: UInt8 = 0
    private var modifierButtons: [UInt8: UIButton] = [:]
    private lazy var specialKeyAccessory: UIView = makeSpecialKeyAccessory()

    var showSoftwareKeyboard = false {
        didSet {
            // Stay first responder always — just toggle the keyboard visibility
            reloadInputViews()
            if !isFirstResponder { becomeFirstResponder() }
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    // Return nil (show keyboard) or empty view (hide keyboard)
    override var inputView: UIView? {
        showSoftwareKeyboard ? nil : emptyInputView
    }

    override var inputAccessoryView: UIView? {
        showSoftwareKeyboard ? specialKeyAccessory : nil
    }

    private func makeSpecialKeyAccessory() -> UIView {
        let accessory = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        accessory.allowsSelfSizing = false

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let keys: [(String, UInt8?, UInt8?)] = [
            ("Esc", 0x29, nil), ("Tab", 0x2B, nil),
            ("Ctrl", nil, KeyMapping.modLeftControl),
            ("Alt", nil, KeyMapping.modLeftAlt),
            ("Cmd", nil, KeyMapping.modLeftGUI),
            ("←", 0x50, nil), ("↑", 0x52, nil),
            ("↓", 0x51, nil), ("→", 0x4F, nil),
            ("Del", 0x4C, nil)
        ]
        for (title, keycode, modifier) in keys {
            var configuration = UIButton.Configuration.gray()
            configuration.title = title
            configuration.cornerStyle = .small
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 12, weight: .medium)
                return attributes
            }
            let button = UIButton(configuration: configuration)
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.75
            button.titleLabel?.lineBreakMode = .byClipping
            button.widthAnchor.constraint(equalToConstant: title.count > 3 ? 58 : 48).isActive = true
            if let modifier {
                button.tag = 0x100 + Int(modifier)
                modifierButtons[modifier] = button
            } else if let keycode {
                button.tag = Int(keycode)
            }
            button.addTarget(self, action: #selector(handleSpecialKey(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: accessory.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -8)
        ])
        return accessory
    }

    @objc private func handleSpecialKey(_ sender: UIButton) {
        if sender.tag >= 0x100 {
            let modifier = UInt8(sender.tag - 0x100)
            latchedModifiers ^= modifier
            sender.isSelected = latchedModifiers & modifier != 0
            sender.configuration?.baseBackgroundColor = sender.isSelected ? .systemBlue : nil
            return
        }
        sendSpecialKey(UInt8(sender.tag))
    }

    private func sendSpecialKey(_ keycode: UInt8) {
        let modifiers = latchedModifiers
        clearLatchedModifiers()
        Task { @MainActor in
            keyboardManager?.hidService?.sendKeyboardReport(modifier: modifiers, keys: [keycode])
            try? await Task.sleep(for: .milliseconds(35))
            keyboardManager?.hidService?.sendKeyboardReport(modifier: 0, keys: [])
        }
    }

    private func clearLatchedModifiers() {
        latchedModifiers = 0
        for button in modifierButtons.values {
            button.isSelected = false
            button.configuration?.baseBackgroundColor = nil
        }
    }

    // UIKeyInput conformance — needed so the system shows the software keyboard
    var hasText: Bool { false }
    func insertText(_ text: String) {
        // The software keyboard gives us the resulting character, not separate
        // Shift events. Translate each character into its HID key + modifier.
        guard let keyboardManager else { return }
        let extraModifiers = latchedModifiers
        clearLatchedModifiers()
        Task { @MainActor in
            for (index, char) in text.enumerated() {
                if let info = KeyMapping.hidInfo(for: char) {
                    keyboardManager.hidService?.sendKeyboardReport(
                        modifier: info.modifier | (index == 0 ? extraModifiers : 0),
                        keys: [info.keycode]
                    )
                    try? await Task.sleep(for: .milliseconds(20))
                    keyboardManager.hidService?.sendKeyboardReport(modifier: 0, keys: [])
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }
    func deleteBackward() {
        sendSpecialKey(0x2A)
    }

    /// Map a physical-key input to its USB HID key code.
    private func hidKeyForCharacter(_ char: Character) -> UInt8? {
        switch char {
        case "a"..."z":
            return UInt8(char.asciiValue! - 0x61 + 0x04) // a=0x04 .. z=0x1D
        case "A"..."Z":
            return UInt8(char.asciiValue! - 0x41 + 0x04)
        case "1": return 0x1E
        case "2": return 0x1F
        case "3": return 0x20
        case "4": return 0x21
        case "5": return 0x22
        case "6": return 0x23
        case "7": return 0x24
        case "8": return 0x25
        case "9": return 0x26
        case "0": return 0x27
        case "\n", "\r": return 0x28 // Return
        case "\t": return 0x2B       // Tab
        case " ": return 0x2C        // Space
        case "-": return 0x2D
        case "=": return 0x2E
        case "[": return 0x2F
        case "]": return 0x30
        case "\\": return 0x31
        case ";": return 0x33
        case "'": return 0x34
        case "`": return 0x35
        case ",": return 0x36
        case ".": return 0x37
        case "/": return 0x38
        default: return nil
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponder()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        Task { @MainActor in
            mouseManager?.viewBounds = CGRect(origin: .zero, size: bounds.size)
        }
    }

    // MARK: - Touch Events (for direct touch and trackpad clicks)

    /// Determine button from event — secondary buttonMask = right-click (trackpad)
    private func mouseButton(for event: UIEvent?) -> MouseButton {
        event?.buttonMask.contains(.secondary) == true ? .right : .left
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if event?.buttonMask.isEmpty != false {
            let fingers = fingerTouches(from: event)
            if fingers.count == 1 && gestureFingerCount == 0 {
                rightClickSent = false
                let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
                clickDragArmed = now - lastCompletedTapTime <= 0.4
            }
            touchStartTime = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
            touchStartPoint = centroid(fingers)
            lastTouchPoint = touchStartPoint
            touchMoved = false
            gestureFingerCount = max(gestureFingerCount, fingers.count)
            debug("began: \(fingers.count) finger(s) · \(inputMode.rawValue)")
            return
        }
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let button = mouseButton(for: event)
        Task { @MainActor in
            mouseManager?.mouseDown(button: button, at: point)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if event?.buttonMask.isEmpty != false {
            let fingers = fingerTouches(from: event)
            guard fingers.count == 1 || fingers.count == 2 else { return }
            gestureFingerCount = max(gestureFingerCount, fingers.count)
            let point = centroid(fingers)
            let dx = point.x - lastTouchPoint.x
            let dy = point.y - lastTouchPoint.y
            let totalDistance = hypot(point.x - touchStartPoint.x, point.y - touchStartPoint.y)
            let elapsed = (event?.timestamp ?? ProcessInfo.processInfo.systemUptime) - touchStartTime
            touchMoved = touchMoved || totalDistance > 18

            Task { @MainActor in
                if inputMode == .scroll || fingers.count == 2 {
                    mouseManager?.scroll(deltaY: -dy / 3, deltaX: dx / 3)
                } else if inputMode == .absolute {
                    mouseManager?.sendMousePosition(viewPoint: point)
                } else {
                    if clickDragArmed && !clickDragActive && elapsed >= 0.18 && totalDistance < 24 {
                        clickDragActive = true
                        mouseManager?.relativeMouseDown(button: .left)
                    }
                    if localZoomScale > 1.01 {
                        let rect = mouseManager?.contentRect ?? bounds
                        let usableRect = rect.isEmpty ? bounds : rect
                        if zoomCursorPoint == .zero {
                            zoomCursorPoint = CGPoint(x: usableRect.midX, y: usableRect.midY)
                        }
                        zoomCursorPoint.x = min(usableRect.maxX, max(usableRect.minX, zoomCursorPoint.x + dx * 1.35))
                        zoomCursorPoint.y = min(usableRect.maxY, max(usableRect.minY, zoomCursorPoint.y + dy * 1.35))
                        mouseManager?.sendMousePosition(viewPoint: zoomCursorPoint)
                        positionZoomedCursor?(zoomCursorPoint, bounds.size)
                    } else {
                        mouseManager?.sendRelativeMovement(dx: dx * 1.35, dy: dy * 1.35)
                    }
                }
            }
            debug("move: \(fingers.count) finger(s) dx \(Int(dx)) dy \(Int(dy)) · \(inputMode.rawValue)")
            lastTouchPoint = point
            return
        }
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        Task { @MainActor in
            mouseManager?.sendMousePosition(viewPoint: point)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if event?.buttonMask.isEmpty != false {
            let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
            if gestureFingerCount >= 2 && !touchMoved && !rightClickSent && now - lastRightClickTime > 0.4 {
                rightClickSent = true
                lastRightClickTime = now
                Task { @MainActor in
                    mouseManager?.sendRelativeMovement(dx: 0, dy: 0, buttons: MouseButton.right.hidBit)
                    try? await Task.sleep(for: .milliseconds(40))
                    mouseManager?.sendRelativeMovement(dx: 0, dy: 0, buttons: 0)
                }
            }
            guard fingerTouches(from: event).isEmpty else { return }
            let wasDragging = clickDragActive
            clickDragActive = false
            let completedTap = !touchMoved && !rightClickSent && inputMode != .scroll
            if wasDragging {
                lastCompletedTapTime = -.infinity
            } else if completedTap {
                lastCompletedTapTime = now
            }
            clickDragArmed = false
            Task { @MainActor in
                if wasDragging {
                    mouseManager?.relativeMouseUp(button: .left)
                } else if completedTap {
                    mouseManager?.sendRelativeMovement(dx: 0, dy: 0, buttons: MouseButton.left.hidBit)
                    try? await Task.sleep(for: .milliseconds(30))
                    mouseManager?.sendRelativeMovement(dx: 0, dy: 0, buttons: 0)
                }
            }
            debug("ended · moved=\(touchMoved) · \(inputMode.rawValue)")
            gestureFingerCount = 0
            return
        }
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let button = mouseButton(for: event)
        Task { @MainActor in
            mouseManager?.mouseUp(button: button, at: point)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if event?.buttonMask.isEmpty != false {
            let wasDragging = clickDragActive
            clickDragActive = false
            clickDragArmed = false
            gestureFingerCount = 0
            rightClickSent = false
            if wasDragging {
                Task { @MainActor in mouseManager?.relativeMouseUp(button: .left) }
            }
            return
        }
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        let button = mouseButton(for: event)
        Task { @MainActor in
            mouseManager?.mouseUp(button: button, at: point)
        }
    }

    // MARK: - Key Commands (claim modifier shortcuts from iPadOS)

    private static let capturedKeyCommands: [UIKeyCommand] = {
        let letters = "abcdefghijklmnopqrstuvwxyz"
        let modifiers: [UIKeyModifierFlags] = [.command, .control, .alternate,
                                                [.command, .shift], [.command, .alternate],
                                                [.control, .shift], [.control, .alternate]]
        var commands: [UIKeyCommand] = []
        for mod in modifiers {
            for char in letters {
                let cmd = UIKeyCommand(input: String(char), modifierFlags: mod, action: #selector(handleKeyCommand(_:)))
                cmd.wantsPriorityOverSystemBehavior = true
                commands.append(cmd)
            }
            // Numbers
            for num in 0...9 {
                let cmd = UIKeyCommand(input: "\(num)", modifierFlags: mod, action: #selector(handleKeyCommand(_:)))
                cmd.wantsPriorityOverSystemBehavior = true
                commands.append(cmd)
            }
        }
        // Cmd+Space
        let cmdSpace = UIKeyCommand(input: " ", modifierFlags: .command, action: #selector(handleKeyCommand(_:)))
        cmdSpace.wantsPriorityOverSystemBehavior = true
        commands.append(cmdSpace)
        return commands
    }()

    override var keyCommands: [UIKeyCommand]? {
        Self.capturedKeyCommands
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input, let keyboardManager else { return }
        // Map the input character to HID keycode
        let hidKey: UInt8?
        if let char = input.first {
            hidKey = hidKeyForCharacter(char)
        } else {
            hidKey = nil
        }
        guard let keycode = hidKey else { return }

        let modifier = keyboardManager.modifierByte(from: command.modifierFlags)
        Task { @MainActor in
            keyboardManager.hidService?.sendKeyboardReport(modifier: modifier, keys: [keycode])
            try? await Task.sleep(for: .milliseconds(30))
            keyboardManager.hidService?.sendKeyboardReport(modifier: 0, keys: [])
        }
    }

    // MARK: - Key Events (iPad hardware keyboard)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if press.key != nil {
                handled = true
                Task { @MainActor in
                    keyboardManager?.handleKeyDown(press)
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if press.key != nil {
                handled = true
                Task { @MainActor in
                    keyboardManager?.handleKeyUp(press)
                }
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }
}
#endif
