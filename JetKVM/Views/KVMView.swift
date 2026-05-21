import SwiftUI
@preconcurrency import WebRTC
import os
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Main KVM session view — shows video, handles input, manages the WebRTC connection.
struct KVMView: View {
    let device: KVMDevice
    @Environment(AppState.self) private var appState

    @State private var viewModel = KVMViewModel()

    private var toolbarLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    private var toolbarTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    var body: some View {
        ZStack {
            #if os(iOS)
            Color(uiColor: .systemBackground).ignoresSafeArea()
            #else
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            #endif

            switch viewModel.state {
            case .disconnected:
                connectPrompt

            case .authenticating:
                LoginView(device: device) {
                    viewModel.didAuthenticate()
                }

            case .connecting, .signaling, .discovering:
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text(viewModel.state.label)
                        .foregroundStyle(.primary)
                }

            case .connected:
                videoContent

            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.state.isActive ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(device.name)
                        .font(.headline)
                }
            }

            ToolbarItemGroup(placement: toolbarLeading) {
                #if os(iOS)
                Button {
                    viewModel.softwareKeyboardVisible.toggle()
                } label: {
                    Image(systemName: viewModel.softwareKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .disabled(!viewModel.state.isActive)
                #endif

                if viewModel.isPasting {
                    Button {
                        viewModel.cancelPaste()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                } else {
                    Button {
                        viewModel.pasteFromClipboard()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .font(.caption)
                    }
                    .disabled(!viewModel.state.isActive)
                }

                ForEach(device.shortcuts) { shortcut in
                    Button {
                        viewModel.sendShortcut(shortcut)
                    } label: {
                        Text(shortcut.label)
                            .font(.caption)
                    }
                    .disabled(!viewModel.state.isActive)
                }
            }

            ToolbarItem(placement: toolbarTrailing) {
                Button {
                    viewModel.disconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .disabled(!viewModel.state.isActive)
            }
        }
        .onAppear {
            viewModel.connect(to: device)
        }
        .onDisappear {
            viewModel.disconnect()
        }
        .onChange(of: appState.keyboardCaptureEnabled) { _, enabled in
            viewModel.keyboardManager.isCaptureSuspended = !enabled
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.keyboardManager.isWindowFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            viewModel.keyboardManager.isWindowFocused = false
        }
        #endif
    }

    // MARK: - Subviews

    private var connectPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Button("Connect") {
                viewModel.connect(to: device)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var videoContent: some View {
        ZStack {
            VideoView(
                videoTrack: viewModel.videoTrack,
                onVideoSizeChange: { size in
                    viewModel.mouseManager.updateVideoSize(size)
                }
            )

            // Transparent overlay captures all mouse/touch/keyboard input
            #if os(iOS)
            InputOverlayView(
                mouseManager: viewModel.mouseManager,
                keyboardManager: viewModel.keyboardManager,
                viewModel: viewModel
            )
            #else
            InputOverlayView(
                mouseManager: viewModel.mouseManager,
                keyboardManager: viewModel.keyboardManager
            )
            #endif


        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text(message)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                viewModel.connect(to: device)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

}

// MARK: - View Model

@Observable
@MainActor
final class KVMViewModel {
    private let logger = Logger(subsystem: "com.jetkvm.app", category: "KVMViewModel")

    var state: ConnectionState = .disconnected
    var videoTrack: RTCVideoTrack?
    var isPasting = false
    var softwareKeyboardVisible = false {
        didSet {
            #if os(iOS)
            inputView?.showSoftwareKeyboard = softwareKeyboardVisible
            #endif
        }
    }

    #if os(iOS)
    weak var inputView: KVMInputUIView?
    #endif

    private var device: KVMDevice?
    private let authService = AuthService()
    private let signalingClient = SignalingClient()
    private let webrtcClient = WebRTCClient()
    private var jsonRPC: JSONRPCClient?
    private var hidService: HIDService?

    let keyboardManager = KeyboardManager()
    let mouseManager = MouseManager()

    // MARK: - Connection Flow

    func connect(to device: KVMDevice) {
        self.device = device
        state = .connecting

        Task {
            do {
                // Step 1: Check device status
                let status = try await authService.checkDeviceStatus(device: device)
                if !status.isSetup {
                    state = .error("Device is not set up. Please configure it via the web interface first.")
                    return
                }

                // Step 2: Try to get device info (may require auth)
                do {
                    _ = try await authService.getDeviceInfo(device: device)
                    // No auth required or already authenticated
                    await startSignaling(device: device)
                } catch {
                    // Probably needs authentication
                    state = .authenticating
                }
            } catch {
                state = .error("Cannot reach device: \(error.localizedDescription)")
            }
        }
    }

    func didAuthenticate() {
        guard let device else { return }
        Task {
            await startSignaling(device: device)
        }
    }

    func disconnect() {
        stopKeyboardCapture()
        webrtcClient.disconnect()
        Task { await signalingClient.disconnect() }
        videoTrack = nil
        state = .disconnected
    }

    /// Send a shortcut key combo (press modifier+key, release after brief delay)
    func sendShortcut(_ shortcut: KVMShortcut) {
        guard let hidService else { return }
        let keys: [UInt8] = shortcut.keycode != 0 ? [shortcut.keycode] : []
        Task {
            hidService.sendKeyboardReport(modifier: shortcut.modifiers, keys: keys)
            try? await Task.sleep(for: .milliseconds(50))
            hidService.sendKeyboardReport(modifier: 0, keys: [])
        }
    }

    /// Paste text from the host clipboard into the guest by sending a keyboard macro.
    func pasteFromClipboard() {
        guard let hidService else { return }

        let text: String?
        #if os(iOS)
        text = UIPasteboard.general.string
        #else
        text = NSPasteboard.general.string(forType: .string)
        #endif

        guard let text, !text.isEmpty else {
            logger.info("Paste: clipboard is empty")
            return
        }

        // Convert text to keyboard macro steps
        var steps: [HIDService.MacroStep] = []
        let interKeyDelay: UInt16 = 20

        for char in text {
            guard let info = KeyMapping.hidInfo(for: char) else {
                continue // Skip unsupported characters
            }

            // Key press step
            steps.append(HIDService.MacroStep(
                modifier: info.modifier,
                keys: [info.keycode],
                delay: interKeyDelay
            ))

            // Key release step
            steps.append(HIDService.MacroStep(
                modifier: 0,
                keys: [],
                delay: interKeyDelay
            ))
        }

        guard !steps.isEmpty else {
            logger.info("Paste: no supported characters in clipboard text")
            return
        }

        isPasting = true
        hidService.sendKeyboardMacro(steps: steps, isPaste: true)

        // Auto-clear isPasting after a conservative timeout based on step count
        // The device should send back a KeyboardMacroState message, but as a fallback:
        let stepCount = steps.count
        Task {
            try? await Task.sleep(for: .milliseconds(Int(interKeyDelay) * stepCount + 500))
            isPasting = false
        }
    }

    /// Cancel an in-progress paste operation.
    func cancelPaste() {
        hidService?.sendCancelKeyboardMacro()
        isPasting = false
    }

    // MARK: - Signaling

    private func startSignaling(device: KVMDevice) async {
        state = .signaling

        do {
            let cookieHeader = await authService.cookieHeader(for: device.baseURL)

            await signalingClient.setCallbacks(
                onDeviceMetadata: { [weak self] version in
                    Task { @MainActor in
                        self?.logger.info("Connected to JetKVM v\(version)")
                        await self?.startWebRTC()
                    }
                },
                onAnswer: { [weak self] sdp, type in
                    Task { @MainActor in
                        do {
                            try await self?.webrtcClient.setRemoteAnswer(sdp: sdp, type: type)
                        } catch {
                            self?.state = .error("Failed to set remote SDP: \(error.localizedDescription)")
                        }
                    }
                },
                onICECandidate: { [weak self] candidate, sdpMid, sdpMLineIndex in
                    Task { @MainActor in
                        let iceCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
                        try? await self?.webrtcClient.addICECandidate(iceCandidate)
                    }
                },
                onDisconnect: { [weak self] in
                    Task { @MainActor in
                        if self?.state.isActive == true {
                            self?.state = .error("Signaling connection lost")
                        }
                    }
                }
            )

            try await signalingClient.connect(to: device, cookieHeader: cookieHeader)
        } catch {
            state = .error("Signaling failed: \(error.localizedDescription)")
        }
    }

    private func startWebRTC() async {
        state = .connecting

        // Set up WebRTC callbacks
        webrtcClient.onVideoTrack = { [weak self] track in
            self?.videoTrack = track
            self?.logger.info("Video track received")
        }

        webrtcClient.onConnectionStateChange = { [weak self] newState in
            switch newState {
            case .connected:
                self?.state = .connected
                self?.logger.info("WebRTC connected!")
            case .disconnected, .failed:
                self?.state = .error("WebRTC connection lost")
            default:
                break
            }
        }

        webrtcClient.onDataChannelOpen = { [weak self] in
            self?.setupInputServices()
        }

        webrtcClient.onLocalICECandidate = { [weak self] candidate in
            Task {
                try? await self?.signalingClient.sendICECandidate([
                    "candidate": candidate.sdp,
                    "sdpMid": candidate.sdpMid ?? "",
                    "sdpMLineIndex": candidate.sdpMLineIndex
                ])
            }
        }

        // Create peer connection and generate offer
        webrtcClient.createPeerConnection()

        do {
            let offer = try await webrtcClient.createOffer()
            let encodedSDP = webrtcClient.encodeSDP(offer)
            try await signalingClient.sendOffer(encodedSDP: encodedSDP)
        } catch {
            state = .error("WebRTC setup failed: \(error.localizedDescription)")
        }
    }

    private func setupInputServices() {
        let hid = HIDService(webrtcClient: webrtcClient)
        hid.sendHandshake()
        self.hidService = hid

        jsonRPC = JSONRPCClient(webrtcClient: webrtcClient)

        keyboardManager.attach(to: hid)
        mouseManager.attach(to: hid)

        // Start keyboard capture now that input services are ready
        keyboardManager.startCapturing()

        logger.info("Input services ready")
    }

    // MARK: - Input Capture

    func startKeyboardCapture() {
        keyboardManager.startCapturing()
    }

    func stopKeyboardCapture() {
        keyboardManager.stopCapturing()
    }
}
