import SwiftUI
@preconcurrency import WebRTC

/// Wraps RTCMTLVideoView for use in SwiftUI.
/// Reports video frame size changes so MouseManager can compute the content rect.
#if os(iOS)
enum VideoDisplayMode: String, CaseIterable {
    case metal = "Metal"
    case cpu = "CPU grayscale preview"
    case test = "Layout test pattern"
}

final class VideoDiagnosticUIView: UIView {
    let metal = RTCMTLVideoView()
    let preview = UIImageView()
    let pattern = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metal.videoContentMode = .scaleAspectFit
        preview.contentMode = .scaleAspectFit
        pattern.text = "VIDEO DISPLAY AREA\nIf you can read this, layout is visible."
        pattern.numberOfLines = 0
        pattern.textAlignment = .center
        pattern.backgroundColor = .systemBlue
        pattern.textColor = .white
        for child in [metal, preview, pattern] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct VideoView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack?
    var onVideoSizeChange: ((CGSize) -> Void)?
    var mode: VideoDisplayMode = .metal
    var onDiagnostic: ((String) -> Void)?

    func makeUIView(context: Context) -> VideoDiagnosticUIView {
        let view = VideoDiagnosticUIView()
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: VideoDiagnosticUIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onVideoSizeChange = onVideoSizeChange
        coordinator.onDiagnostic = onDiagnostic
        view.metal.isHidden = mode != .metal
        view.preview.isHidden = mode != .cpu
        view.pattern.isHidden = mode != .test
        if coordinator.track !== videoTrack {
            coordinator.track?.remove(view.metal)
            coordinator.track?.remove(coordinator)
            coordinator.track = videoTrack
            videoTrack?.add(view.metal)
            videoTrack?.add(coordinator)
        }
    }

    static func dismantleUIView(_ view: VideoDiagnosticUIView, coordinator: Coordinator) {
        coordinator.track?.remove(view.metal)
        coordinator.track?.remove(coordinator)
        coordinator.track = nil
        coordinator.view = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, RTCVideoRenderer, @unchecked Sendable {
        var track: RTCVideoTrack?
        weak var view: VideoDiagnosticUIView?
        var onVideoSizeChange: ((CGSize) -> Void)?
        var onDiagnostic: ((String) -> Void)?
        private let lock = NSLock()
        private var lastSample: TimeInterval = 0
        private var received = 0

        nonisolated func setSize(_ size: CGSize) {}

        // A small grayscale image uses decoded luminance directly, bypassing
        // the WebRTC Metal renderer and its colour conversion entirely.
        nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame else { return }
            lock.lock()
            received += 1
            let count = received
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastSample >= 0.5 else { lock.unlock(); return }
            lastSample = now
            lock.unlock()
            let buffer = frame.buffer.toI420()
            let width = Int(buffer.width), height = Int(buffer.height)
            guard width > 0, height > 0 else { return }
            let step = max(1, max(width, height) / 480)
            let outWidth = max(1, width / step), outHeight = max(1, height / step)
            var pixels = [UInt8](repeating: 0, count: outWidth * outHeight)
            var darkest: UInt8 = 255, brightest: UInt8 = 0
            for y in 0..<outHeight {
                for x in 0..<outWidth {
                    let value = buffer.dataY[y * step * Int(buffer.strideY) + x * step]
                    pixels[y * outWidth + x] = value
                    darkest = min(darkest, value)
                    brightest = max(brightest, value)
                }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: outWidth, height: outHeight,
                    bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: outWidth,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return }
            let report = "Renderer callbacks: \(count) · frame \(width)×\(height) · luma \(darkest)–\(brightest)"
            Task { @MainActor [weak self] in
                guard let self, let view = self.view else { return }
                view.preview.image = UIImage(cgImage: image)
                self.onVideoSizeChange?(CGSize(width: width, height: height))
                self.onDiagnostic?("\(report) · view \(Int(view.bounds.width))×\(Int(view.bounds.height))")
            }
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
