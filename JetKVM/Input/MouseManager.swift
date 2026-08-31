import Foundation
import os

/// Handles mouse/trackpad input and translates to HID reports.
///
/// Absolute positioning: converts view coordinates to 0-32767 HID range,
/// mapping against the visible video content rect (not the full view).
@MainActor
final class MouseManager {
    private let logger = Logger(subsystem: "com.jetkvm.app", category: "Mouse")
    private var hidService: HIDService?
    private var jsonRPCClient: JSONRPCClient?

    /// Aspect ratio of the video stream (set when video size changes)
    var videoAspectRatio: CGFloat = 16.0 / 9.0
    /// The full overlay view bounds — updated on every layout
    var viewBounds: CGRect = .zero {
        didSet { recalcContentRect() }
    }

    /// Computed content rect within the view (accounts for letterboxing/pillarboxing)
    private(set) var contentRect: CGRect = .zero

    private var currentButtons: UInt8 = 0
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0
    private let maxAbsoluteValue: Int32 = 32767

    func attach(to hidService: HIDService, jsonRPCClient: JSONRPCClient) {
        self.hidService = hidService
        self.jsonRPCClient = jsonRPCClient
    }

    /// Called when RTCVideoView reports a new video frame size.
    func updateVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        videoAspectRatio = size.width / size.height
        recalcContentRect()
    }

    private func recalcContentRect() {
        let vw = viewBounds.width
        let vh = viewBounds.height
        guard vw > 0, vh > 0 else { contentRect = .zero; return }

        let viewAspect = vw / vh
        if videoAspectRatio > viewAspect {
            // Letterboxing (bars top/bottom)
            let height = vw / videoAspectRatio
            let y = (vh - height) / 2
            contentRect = CGRect(x: 0, y: y, width: vw, height: height)
        } else {
            // Pillarboxing (bars left/right)
            let width = vh * videoAspectRatio
            let x = (vw - width) / 2
            contentRect = CGRect(x: x, y: 0, width: width, height: vh)
        }
    }

    // MARK: - Absolute Mouse

    /// Send mouse position from a view-relative point.
    func sendMousePosition(viewPoint: CGPoint, buttons: UInt8? = nil) {
        let rect = contentRect.width > 0 ? contentRect : viewBounds
        guard rect.width > 0, rect.height > 0 else { return }

        let relX = (viewPoint.x - rect.minX) / rect.width
        let relY = (viewPoint.y - rect.minY) / rect.height

        let clampedX = max(0, min(1, relX))
        let clampedY = max(0, min(1, relY))

        let absX = Int32(clampedX * Double(maxAbsoluteValue))
        let absY = Int32(clampedY * Double(maxAbsoluteValue))

        let btn = buttons ?? currentButtons
        hidService?.sendAbsoluteMouseReport(x: absX, y: absY, buttons: btn)
    }

    // MARK: - Button State

    func mouseDown(button: MouseButton, at viewPoint: CGPoint) {
        currentButtons |= button.hidBit
        sendMousePosition(viewPoint: viewPoint)
    }

    func mouseUp(button: MouseButton, at viewPoint: CGPoint) {
        currentButtons &= ~button.hidBit
        sendMousePosition(viewPoint: viewPoint)
    }

    // MARK: - Scroll

    func scroll(deltaY: CGFloat, deltaX: CGFloat = 0) {
        // Preserve sub-unit trackpad movement instead of rounding every event
        // to zero. Emit whole HID wheel steps and retain the remainder.
        scrollRemainderY += deltaY
        scrollRemainderX += deltaX
        let wholeY = Int(scrollRemainderY)
        let wholeX = Int(scrollRemainderX)
        let scrollY = Int8(clamping: wholeY)
        let scrollX = Int8(clamping: wholeX)
        guard scrollY != 0 || scrollX != 0 else { return }
        scrollRemainderY -= CGFloat(wholeY)
        scrollRemainderX -= CGFloat(wholeX)
        // JetKVM does not define a binary HID wheel message. Its official web
        // client sends wheelReport over the reliable JSON-RPC data channel.
        jsonRPCClient?.sendWheelReport(wheelY: Int(scrollY), wheelX: Int(scrollX))
    }

    // MARK: - Relative Mouse (optional, for trackpad-as-relative mode)

    func sendRelativeMovement(dx: CGFloat, dy: CGFloat, buttons: UInt8? = nil) {
        let clampedDx = Int8(clamping: Int(dx.rounded()))
        let clampedDy = Int8(clamping: Int(dy.rounded()))
        let btn = buttons ?? currentButtons
        hidService?.sendRelativeMouseReport(dx: clampedDx, dy: clampedDy, buttons: btn)
    }

    func relativeMouseDown(button: MouseButton) {
        currentButtons |= button.hidBit
        sendRelativeMovement(dx: 0, dy: 0)
    }

    func relativeMouseUp(button: MouseButton) {
        currentButtons &= ~button.hidBit
        sendRelativeMovement(dx: 0, dy: 0)
    }
}

enum MouseButton {
    case left, right, middle

    var hidBit: UInt8 {
        switch self {
        case .left: KeyMapping.mouseButtonLeft
        case .right: KeyMapping.mouseButtonRight
        case .middle: KeyMapping.mouseButtonMiddle
        }
    }
}
