import Foundation
import os

/// Binary HID protocol encoder for the `hidrpc` WebRTC DataChannel.
///
/// Wire format:
///   [MessageType: 1 byte] [Payload: variable]
///
/// Message types:
///   0x01 = Handshake       [version: 1B]
///   0x02 = KeyboardReport  [modifier: 1B] [key1..key6: 6B]
///   0x03 = PointerReport   [x: 4B BE] [y: 4B BE] [buttons: 1B]
///   0x05 = KeypressReport  [keycode: 1B] [press: 1B]
///   0x06 = MouseReport     [dx: int8] [dy: int8] [buttons: 1B]
@MainActor
final class HIDService {
    private let logger = Logger(subsystem: "com.jetkvm.app", category: "HID")
    private weak var webrtcClient: WebRTCClient?
    private var handshakeSent = false

    // Message type constants
    private enum MessageType: UInt8 {
        case handshake = 0x01
        case keyboardReport = 0x02
        case pointerReport = 0x03
        case keypressReport = 0x05
        case mouseReport = 0x06
        case keyboardMacro = 0x07
        case cancelKeyboardMacro = 0x08
        case keypressKeepAlive = 0x09
    }

    // Current HID protocol version
    private let protocolVersion: UInt8 = 0x01

    init(webrtcClient: WebRTCClient) {
        self.webrtcClient = webrtcClient
    }

    // MARK: - Handshake

    /// Must be called when the hidrpc DataChannel opens.
    func sendHandshake() {
        let data = Data([MessageType.handshake.rawValue, protocolVersion])
        webrtcClient?.sendHID(data, reliable: true)
        handshakeSent = true
        logger.info("HID handshake sent (v\(self.protocolVersion))")
    }

    // MARK: - Keyboard

    /// Send a full keyboard state report (up to 6 simultaneous keys).
    func sendKeyboardReport(modifier: UInt8, keys: [UInt8]) {
        var payload = Data(capacity: 8)
        payload.append(MessageType.keyboardReport.rawValue)
        payload.append(modifier)
        // Pad keys to 6 bytes
        for i in 0..<6 {
            payload.append(i < keys.count ? keys[i] : 0)
        }
        webrtcClient?.sendHID(payload, reliable: true)
    }

    /// Send a single key press or release event.
    func sendKeypress(keycode: UInt8, isDown: Bool) {
        let data = Data([
            MessageType.keypressReport.rawValue,
            keycode,
            isDown ? 0x01 : 0x00
        ])
        webrtcClient?.sendHID(data, reliable: true)
    }

    // MARK: - Mouse (Absolute)

    /// Send absolute mouse position. Coordinates are in range 0...32767.
    func sendAbsoluteMouseReport(x: Int32, y: Int32, buttons: UInt8) {
        var data = Data(capacity: 10)
        data.append(MessageType.pointerReport.rawValue)

        // X coordinate — 4 bytes big-endian
        data.append(UInt8((x >> 24) & 0xFF))
        data.append(UInt8((x >> 16) & 0xFF))
        data.append(UInt8((x >> 8) & 0xFF))
        data.append(UInt8(x & 0xFF))

        // Y coordinate — 4 bytes big-endian
        data.append(UInt8((y >> 24) & 0xFF))
        data.append(UInt8((y >> 16) & 0xFF))
        data.append(UInt8((y >> 8) & 0xFF))
        data.append(UInt8(y & 0xFF))

        // Buttons
        data.append(buttons)

        // Use unreliable channel for lower latency on mouse movement
        webrtcClient?.sendHID(data, reliable: false)
    }

    // MARK: - Mouse (Relative)

    /// Send relative mouse movement.
    func sendRelativeMouseReport(dx: Int8, dy: Int8, buttons: UInt8) {
        let data = Data([
            MessageType.mouseReport.rawValue,
            UInt8(bitPattern: dx),
            UInt8(bitPattern: dy),
            buttons
        ])
        webrtcClient?.sendHID(data, reliable: false)
    }

    // MARK: - Keyboard Macro (Paste)

    /// A single step in a keyboard macro sequence.
    struct MacroStep {
        let modifier: UInt8
        let keys: [UInt8]    // Up to 6 keys (padded with zeros)
        let delay: UInt16    // Delay in milliseconds after this step
    }

    /// Send a keyboard macro to the device for server-side execution.
    ///
    /// The device processes the entire sequence, handling timing internally.
    /// Wire format: `[0x07] [isPaste: 1B] [stepCount: 4B BE] [steps...]`
    /// Each step: `[modifier: 1B] [key1..key6: 6B] [delay: 2B BE]`
    func sendKeyboardMacro(steps: [MacroStep], isPaste: Bool = true) {
        let stepCount = UInt32(steps.count)
        var data = Data(capacity: 1 + 1 + 4 + steps.count * 9)

        data.append(MessageType.keyboardMacro.rawValue)
        data.append(isPaste ? 0x01 : 0x00)

        // Step count — 4 bytes big-endian
        data.append(UInt8((stepCount >> 24) & 0xFF))
        data.append(UInt8((stepCount >> 16) & 0xFF))
        data.append(UInt8((stepCount >> 8) & 0xFF))
        data.append(UInt8(stepCount & 0xFF))

        for step in steps {
            data.append(step.modifier)
            // Pad keys to 6 bytes
            for i in 0..<6 {
                data.append(i < step.keys.count ? step.keys[i] : 0)
            }
            // Delay — 2 bytes big-endian
            data.append(UInt8((step.delay >> 8) & 0xFF))
            data.append(UInt8(step.delay & 0xFF))
        }

        webrtcClient?.sendHID(data, reliable: true)
        logger.info("Keyboard macro sent (\(steps.count) steps, isPaste: \(isPaste))")
    }

    /// Cancel any ongoing keyboard macro execution on the device.
    func sendCancelKeyboardMacro() {
        let data = Data([MessageType.cancelKeyboardMacro.rawValue])
        webrtcClient?.sendHID(data, reliable: true)
        logger.info("Keyboard macro cancel sent")
    }

    // MARK: - Utility

    func sendKeepAlive() {
        let data = Data([MessageType.keypressKeepAlive.rawValue])
        webrtcClient?.sendHID(data, reliable: true)
    }
}
