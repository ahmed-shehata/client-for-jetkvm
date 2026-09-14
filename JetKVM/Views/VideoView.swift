import SwiftUI
@preconcurrency import WebRTC
#if os(iOS)
import CoreImage
import CoreVideo
#endif

/// Wraps RTCMTLVideoView for use in SwiftUI.
/// Reports video frame size changes so MouseManager can compute the content rect.
#if os(iOS)
enum VideoDisplayMode: String, CaseIterable {
    case color = "CPU colour · full resolution"
    case metal = "Metal"
    case cpu = "CPU grayscale · full resolution"
    case test = "Layout test pattern"
}

final class VideoDiagnosticUIView: UIView {
    var metal: RTCMTLVideoView?
    let preview = UIImageView()
    let pattern = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        preview.contentMode = .scaleAspectFit
        pattern.text = "VIDEO DISPLAY AREA\nIf you can read this, layout is visible."
        pattern.numberOfLines = 0
        pattern.textAlignment = .center
        pattern.backgroundColor = .systemBlue
        pattern.textColor = .white
        for child in [preview, pattern] {
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

    func installMetal() -> RTCMTLVideoView {
        if let metal { return metal }
        let renderer = RTCMTLVideoView()
        renderer.videoContentMode = .scaleAspectFit
        renderer.frame = bounds
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(renderer, at: 0)
        metal = renderer
        return renderer
    }
}

struct VideoView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack?
    var onVideoSizeChange: ((CGSize) -> Void)?
    var mode: VideoDisplayMode = .color
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
        view.preview.isHidden = mode != .cpu && mode != .color
        view.pattern.isHidden = mode != .test
        if coordinator.track !== videoTrack || coordinator.displayMode != mode {
            if let metal = view.metal {
                coordinator.track?.remove(metal)
                metal.removeFromSuperview()
                view.metal = nil
            }
            coordinator.track?.remove(coordinator)
            coordinator.configure(mode)
            coordinator.track = videoTrack
            if mode == .metal { videoTrack?.add(view.installMetal()) }
            videoTrack?.add(coordinator)
        }
    }

    static func dismantleUIView(_ view: VideoDiagnosticUIView, coordinator: Coordinator) {
        if let metal = view.metal { coordinator.track?.remove(metal) }
        coordinator.track?.remove(coordinator)
        coordinator.configure(.test)
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
        private var busy = false
        private var generation = 0
        private(set) var displayMode: VideoDisplayMode = .color
        private var lastSize = CGSize.zero
        private var lastReport: TimeInterval = 0
        private let imageContext = CIContext(options: [.useSoftwareRenderer: true])

        func configure(_ mode: VideoDisplayMode) {
            lock.lock()
            displayMode = mode
            generation += 1
            lastSample = 0
            lock.unlock()
            lastSize = .zero
            lastReport = 0
        }

        nonisolated func setSize(_ size: CGSize) {}

        // Full-size CPU display bypasses WebRTC Metal. Bound work to one frame
        // in flight and 15 fps; never queue old frames or resize source pixels.
        nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
            guard let frame else { return }
            lock.lock()
            received += 1
            let count = received
            let now = ProcessInfo.processInfo.systemUptime
            let mode = displayMode
            let token = generation
            let interval = (mode == .color || mode == .cpu) ? 1.0 / 15.0 : 0.5
            guard !busy, now - lastSample >= interval else { lock.unlock(); return }
            busy = true
            lastSample = now
            lock.unlock()
            var handedOff = false
            defer {
                if !handedOff { lock.lock(); busy = false; lock.unlock() }
            }
            let buffer = frame.buffer.toI420()
            let width = Int(buffer.width), height = Int(buffer.height)
            guard width > 0, height > 0 else { return }
            var image: CGImage?
            if mode == .color {
                if let native = frame.buffer as? RTCCVPixelBuffer {
                    let source = CIImage(cvPixelBuffer: native.pixelBuffer)
                    image = imageContext.createCGImage(source, from: source.extent)
                } else {
                    // Convert planar I420 to full-size NV12, preserving row strides.
                    var pixelBuffer: CVPixelBuffer?
                    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixelBuffer) == kCVReturnSuccess,
                        let pixelBuffer else { return }
                    guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return }
                    if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                       let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
                        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                        for y in 0..<height {
                            memcpy(yBase.advanced(by: y * yStride), buffer.dataY.advanced(by: y * Int(buffer.strideY)), width)
                        }
                        let uv = uvBase.assumingMemoryBound(to: UInt8.self)
                        for y in 0..<((height + 1) / 2) {
                            for x in 0..<((width + 1) / 2) {
                                uv[y * uvStride + 2 * x] = buffer.dataU[y * Int(buffer.strideU) + x]
                                uv[y * uvStride + 2 * x + 1] = buffer.dataV[y * Int(buffer.strideV) + x]
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                    let source = CIImage(cvPixelBuffer: pixelBuffer)
                    image = imageContext.createCGImage(source, from: source.extent)
                }
            } else if mode == .cpu {
                var pixels = [UInt8](repeating: 0, count: width * height)
                pixels.withUnsafeMutableBytes { destination in
                    guard let base = destination.baseAddress else { return }
                    for y in 0..<height {
                        memcpy(base.advanced(by: y * width), buffer.dataY.advanced(by: y * Int(buffer.strideY)), width)
                    }
                }
                if let provider = CGDataProvider(data: Data(pixels) as CFData) {
                    image = CGImage(width: width, height: height, bitsPerComponent: 8,
                        bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                        shouldInterpolate: true, intent: .defaultIntent)
                }
            }
            let renderedImage = image
            let rotation = frame.rotation
            let report = "Renderer callbacks: \(count) · source \(width)×\(height) · output \(image?.width ?? 0)×\(image?.height ?? 0)"
            handedOff = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishFrame() }
                guard self.isCurrent(token), let view = self.view else { return }
                if let renderedImage {
                    let orientation: UIImage.Orientation
                    switch rotation {
                    case ._90: orientation = .right
                    case ._180: orientation = .down
                    case ._270: orientation = .left
                    default: orientation = .up
                    }
                    view.preview.image = UIImage(cgImage: renderedImage, scale: 1, orientation: orientation)
                }
                let rotated = rotation == ._90 || rotation == ._270
                let size = CGSize(width: rotated ? height : width, height: rotated ? width : height)
                if self.lastSize != size {
                    self.lastSize = size
                    self.onVideoSizeChange?(size)
                }
                if now - self.lastReport >= 1 {
                    self.lastReport = now
                    self.onDiagnostic?("\(report) · view \(Int(view.bounds.width))×\(Int(view.bounds.height))")
                }
            }
        }

        private func isCurrent(_ token: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return generation == token
        }

        private func finishFrame() {
            lock.lock(); busy = false; lock.unlock()
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
