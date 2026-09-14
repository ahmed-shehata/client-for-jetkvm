import Foundation
@preconcurrency import WebRTC
import os

/// Manages the WebRTC peer connection to a JetKVM device.
///
/// Handles SDP offer/answer, ICE candidates, video track, and data channels.
@MainActor
final class WebRTCClient: NSObject, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.jetkvm.app", category: "WebRTC")
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?

    // Data channels
    private(set) var rpcChannel: RTCDataChannel?
    private(set) var hidChannel: RTCDataChannel?
    private(set) var hidUnreliableOrdered: RTCDataChannel?
    private(set) var hidUnreliableUnordered: RTCDataChannel?

    // Callbacks
    var onVideoTrack: ((RTCVideoTrack) -> Void)?
    var onDataChannelOpen: (() -> Void)?
    var onConnectionStateChange: ((RTCPeerConnectionState) -> Void)?
    var onLocalICECandidate: ((RTCIceCandidate) -> Void)?
    var onLocalSDP: ((RTCSessionDescription) -> Void)?

    override init() {
        RTCInitializeSSL()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        super.init()
    }

    deinit {
        // Cleanup is handled by disconnect() called externally before dealloc
        RTCCleanupSSL()
    }

    // MARK: - Connection

    func createPeerConnection() {
        let config = RTCConfiguration()
        // No ICE servers needed for LAN-only connections
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        guard let pc = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        ) else {
            logger.error("Failed to create peer connection")
            return
        }

        peerConnection = pc
        createDataChannels(pc)
        logger.info("Peer connection created")
    }

    private func createDataChannels(_ pc: RTCPeerConnection) {
        // RPC channel (JSON-RPC 2.0) — reliable ordered
        let rpcConfig = RTCDataChannelConfiguration()
        rpcConfig.isOrdered = true
        rpcChannel = pc.dataChannel(forLabel: "rpc", configuration: rpcConfig)
        rpcChannel?.delegate = self

        // HID channel — reliable ordered
        let hidConfig = RTCDataChannelConfiguration()
        hidConfig.isOrdered = true
        hidChannel = pc.dataChannel(forLabel: "hidrpc", configuration: hidConfig)
        hidChannel?.delegate = self

        // HID unreliable ordered (lower latency for mouse movement)
        let hidUOConfig = RTCDataChannelConfiguration()
        hidUOConfig.isOrdered = true
        hidUOConfig.maxRetransmits = 0
        hidUnreliableOrdered = pc.dataChannel(forLabel: "hidrpc-unreliable-ordered", configuration: hidUOConfig)
        hidUnreliableOrdered?.delegate = self

        // HID unreliable unordered (lowest latency)
        let hidUUConfig = RTCDataChannelConfiguration()
        hidUUConfig.isOrdered = false
        hidUUConfig.maxRetransmits = 0
        hidUnreliableUnordered = pc.dataChannel(forLabel: "hidrpc-unreliable-nonordered", configuration: hidUUConfig)
        hidUnreliableUnordered?.delegate = self
    }

    // MARK: - SDP

    func createOffer() async throws -> RTCSessionDescription {
        guard let pc = peerConnection else {
            throw WebRTCError.noPeerConnection
        }

        // Add transceiver for receiving video
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        guard let transceiver = pc.addTransceiver(of: .video, init: transceiverInit) else {
            throw WebRTCError.noPeerConnection
        }
        // JetKVM supports H.264. Advertise only that codec so firmware cannot
        // select a different format simply because it appears in our offer.
        let codecs = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        let h264 = codecs.filter { $0.name.caseInsensitiveCompare("H264") == .orderedSame }
        guard !h264.isEmpty else {
            throw WebRTCError.connectionFailed("H.264 decoding is unavailable")
        }
        try transceiver.setCodecPreferences(h264)

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveVideo": "true",
                "OfferToReceiveAudio": "false"
            ],
            optionalConstraints: nil
        )

        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        logger.info("Created and set local SDP offer")
        return offer
    }

    func setRemoteAnswer(sdp: String, type: String) async throws {
        guard let pc = peerConnection else {
            throw WebRTCError.noPeerConnection
        }

        let sdpType: RTCSdpType = type == "answer" ? .answer : .offer
        let description = RTCSessionDescription(type: sdpType, sdp: sdp)
        try await pc.setRemoteDescription(description)
        for receiver in pc.receivers {
            if let track = receiver.track as? RTCVideoTrack { onVideoTrack?(track) }
        }
        logger.info("Set remote SDP answer")
    }

    func addICECandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else {
            throw WebRTCError.noPeerConnection
        }
        try await pc.add(candidate)
    }

    /// Encode SDP for JetKVM signaling protocol: base64(JSON({type, sdp}))
    func encodeSDP(_ sdp: RTCSessionDescription) -> String {
        let dict: [String: String] = [
            "type": sdp.type == .offer ? "offer" : "answer",
            "sdp": sdp.sdp
        ]
        let jsonData = try! JSONSerialization.data(withJSONObject: dict)
        return jsonData.base64EncodedString()
    }

    // MARK: - Data

    func sendRPC(_ data: Data) {
        guard let channel = rpcChannel, channel.readyState == .open else { return }
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        channel.sendData(buffer)
    }

    func sendHID(_ data: Data, reliable: Bool = true) {
        let channel: RTCDataChannel?
        if reliable {
            channel = hidChannel
        } else {
            channel = hidUnreliableOrdered ?? hidChannel
        }
        guard let ch = channel, ch.readyState == .open else { return }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        ch.sendData(buffer)
    }

    func disconnect() {
        rpcChannel?.close()
        hidChannel?.close()
        hidUnreliableOrdered?.close()
        hidUnreliableUnordered?.close()
        peerConnection?.close()
        peerConnection = nil
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                   didStartReceivingOn transceiver: RTCRtpTransceiver) {
        Task { @MainActor in
            guard self.peerConnection === peerConnection,
                  let track = transceiver.receiver.track as? RTCVideoTrack else { return }
            onVideoTrack?(track)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                   didAdd rtpReceiver: RTCRtpReceiver,
                                   streams: [RTCMediaStream]) {
        Task { @MainActor in
            guard self.peerConnection === peerConnection,
                  let track = rtpReceiver.track as? RTCVideoTrack else { return }
            onVideoTrack?(track)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor in
            logger.info("Signaling state: \(String(describing: stateChanged))")
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            logger.info("Added stream: \(stream.streamId)")
            guard self.peerConnection === peerConnection else { return }
            if let videoTrack = stream.videoTracks.first {
                onVideoTrack?(videoTrack)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor in
            logger.info("ICE connection state: \(String(describing: newState))")
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            onLocalICECandidate?(candidate)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in
            logger.info("Remote data channel opened: \(dataChannel.label)")
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in
            logger.info("Peer connection state: \(String(describing: newState))")
            onConnectionStateChange?(newState)
        }
    }
}

// MARK: - RTCDataChannelDelegate

extension WebRTCClient: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            logger.info("Data channel '\(dataChannel.label)' state: \(String(describing: dataChannel.readyState))")
            if dataChannel.label == "rpc" && dataChannel.readyState == .open {
                onDataChannelOpen?()
            }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Task { @MainActor in
            if dataChannel.label == "rpc", !buffer.isBinary {
                let text = String(data: buffer.data, encoding: .utf8) ?? ""
                logger.debug("RPC received: \(text.prefix(200))")
            }
        }
    }
}

// MARK: - Errors

enum WebRTCError: LocalizedError {
    case noPeerConnection
    case sdpCreationFailed
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPeerConnection: "No peer connection"
        case .sdpCreationFailed: "Failed to create SDP"
        case .connectionFailed(let msg): "Connection failed: \(msg)"
        }
    }
}
