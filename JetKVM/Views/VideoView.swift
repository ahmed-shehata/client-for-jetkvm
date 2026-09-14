import SwiftUI
@preconcurrency import WebRTC

/// Wraps RTCMTLVideoView for use in SwiftUI.
/// Reports video frame size changes so MouseManager can compute the content rect.
#if os(iOS)
struct VideoView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack?
    var onVideoSizeChange: ((CGSize) -> Void)?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        view.delegate = context.coordinator
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        context.coordinator.onVideoSizeChange = onVideoSizeChange
        if context.coordinator.track !== videoTrack {
            context.coordinator.track?.remove(view)
            context.coordinator.track = videoTrack
            videoTrack?.add(view)
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, RTCVideoViewDelegate, @unchecked Sendable {
        var track: RTCVideoTrack?
        var onVideoSizeChange: ((CGSize) -> Void)?

        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            let callback = self.onVideoSizeChange
            Task { @MainActor in callback?(size) }
        }
    }
}
#endif

#if os(macOS)
struct VideoView: NSViewRepresentable {
    let videoTrack: RTCVideoTrack?
    var onVideoSizeChange: ((CGSize) -> Void)?

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        let view = RTCMTLNSVideoView()
        view.delegate = context.coordinator
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: RTCMTLNSVideoView, context: Context) {
        context.coordinator.onVideoSizeChange = onVideoSizeChange
        if context.coordinator.track !== videoTrack {
            context.coordinator.track?.remove(view)
            context.coordinator.track = videoTrack
            videoTrack?.add(view)
        }
    }

    static func dismantleNSView(_ view: RTCMTLNSVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, RTCVideoViewDelegate, @unchecked Sendable {
        var track: RTCVideoTrack?
        var onVideoSizeChange: ((CGSize) -> Void)?

        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            let callback = self.onVideoSizeChange
            Task { @MainActor in callback?(size) }
        }
    }
}
#endif
