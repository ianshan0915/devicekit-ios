import CoreImage
import CoreMedia
import H264Codec
import Metal
import os

enum H264Error: Error, LocalizedError {
    case captureFailed
    case conversionFailed
    case encoderNotConfigured

    var errorDescription: String? {
        switch self {
        case .captureFailed: return "Screenshot capture failed"
        case .conversionFailed: return "Pixel buffer conversion failed"
        case .encoderNotConfigured: return "Encoder not configured"
        }
    }
}

final class H264FrameProducer: @unchecked Sendable {
    private let captureTimeout: TimeInterval = 0.5

    // Created once per process, and Metal-backed. `CIContext(options:)` with
    // useSoftwareRenderer:false selects an EAGL-backed GL context on iOS 15,
    // whose init dereferences null when the GPU refuses the allocation under
    // memory pressure — an uncatchable SIGSEGV inside Core Image rather than a
    // failure we can handle. Building one per stream also churned a GPU-backed
    // context on every reconnect, which fed the pressure that triggered it.
    private static let sharedCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.highQualityDownsample: false])
        }
        return CIContext(options: [
            .useSoftwareRenderer: true,
            .highQualityDownsample: false
        ])
    }()

    private var encoder: H264Encoder?
    private let ciContext = H264FrameProducer.sharedCIContext
    private var pixelBufferPool: CVPixelBufferPool?
    private var targetSize: CGSize?
    private var isConfigured = false

    private var continuation: AsyncStream<Data>.Continuation?

    // S08 duplicate-frame suppression. A static screen still emits one forced
    // IDR per second (the reviewed runner's keyframe cadence) so late-joining
    // viewers and the bridge's awaiting-idr handoff keep the same recovery
    // semantics. Capture runs at the full configured rate and a changed frame
    // is encoded immediately, so suppression never delays motion or control.
    private let suppressDuplicates: Bool
    private let m06Timing: Bool
    private let emitAccessUnitDelimiter: Bool
    private var referenceData: Data?          // stride-aware copy of last emitted frame
    private var lastEmittedAtNs: UInt64 = 0   // monotonic clock of last encode
    private var lastIDRAtNs: UInt64 = 0       // monotonic clock of last keyframe
    private var captureTick: UInt64 = 0       // capture counter used for timestamps

    private static let forcedFrameIntervalNs: UInt64 = 1_000_000_000  // 1 s floor
    // Defensive epsilon only: captures are byte-deterministic on static screens
    // (JPEG + GPU scale of identical input), so any *visible* change must stream
    // immediately. 0.001% of the scaled buffer is ~7-8 pixels — small enough
    // that every visible UI element (typing caret, thin progress bar, small
    // spinner) exceeds it, while a sub-pixel capture hiccup would not. The
    // earlier 0.05% was too coarse: it could swallow a caret blink for up to a
    // second on the actively-used phone.
    private static let maxChangedByteRatio: Double = 0.00001

    // Periodic on-device counters, logged every interval so a session can see
    // from device logs whether suppression is actually engaging.
    private var emittedFrames: UInt64 = 0
    private var suppressedFrames: UInt64 = 0
    private var forcedKeyframes: UInt64 = 0
    private var lastCountersLogAtNs: UInt64 = 0
    private static let countersLogIntervalNs: UInt64 = 10_000_000_000

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "devicekit-ios",
        category: "H264FrameProducer"
    )

    init() {
        self.suppressDuplicates = true
        self.m06Timing = false
        self.emitAccessUnitDelimiter = false
    }

    init(suppressDuplicates: Bool) {
        self.suppressDuplicates = suppressDuplicates
        self.m06Timing = false
        self.emitAccessUnitDelimiter = false
    }

    init(
        suppressDuplicates: Bool,
        m06Timing: Bool,
        emitAccessUnitDelimiter: Bool = false
    ) {
        self.suppressDuplicates = suppressDuplicates
        self.m06Timing = m06Timing
        self.emitAccessUnitDelimiter = emitAccessUnitDelimiter
    }

    func makeNALUnitStream() -> AsyncStream<Data> {
        if m06Timing {
            M06ControlTimingState.shared.instrumentedStreamStarted()
        }
        return AsyncStream { continuation in
            self.continuation = continuation

            continuation.onTermination = { [weak self, m06Timing] _ in
                if m06Timing {
                    M06ControlTimingState.shared.instrumentedStreamStopped()
                }
                self?.invalidateEncoder()
            }
        }
    }

    func invalidateEncoder() {
        encoder?.invalidateCompressionSession()
        // Drop the per-stream media buffers with the session. `isConfigured`
        // deliberately stays true: an in-flight @MainActor capture then hits the
        // `encoder` guard and throws encoderNotConfigured instead of racing into
        // a reconfigure — this type is @unchecked Sendable and invalidation can
        // run off the main actor, so the dead state has to stay dead.
        encoder = nil
        pixelBufferPool = nil
        referenceData = nil
        continuation?.finish()
        continuation = nil
    }

    @MainActor
    func captureAndEncodeFrame(
        fps: Int,
        bitrate: Int,
        quality: Float,
        scale: Float,
        frameInterval: UInt64
    ) async throws {
        let frameStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)

        if m06Timing {
            M06ControlTimingState.shared.screenshotStarted(at: frameStart)
        }
        let capturedImage = try? FBScreenshot.captureUIImage(
            withQuality: 0.9,
            timeout: captureTimeout
        )
        if m06Timing {
            M06ControlTimingState.shared.screenshotFinished(
                at: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            )
        }
        guard let uiImage = capturedImage, let cgImage = uiImage.cgImage else {
            throw H264Error.captureFailed
        }

        if !isConfigured {
            try configureEncoder(
                for: cgImage,
                fps: fps,
                bitrate: bitrate,
                quality: quality,
                scale: scale
            )
        }

        guard let targetSize = targetSize,
              let encoder = encoder else {
            throw H264Error.encoderNotConfigured
        }

        guard let pixelBuffer = cgImage.toPixelBuffer(
            context: ciContext,
            targetSize: targetSize,
            pool: pixelBufferPool
        ) else {
            throw H264Error.conversionFailed
        }

        // Timestamps count capture slots, not encoded frames, so a suppressed
        // static run still presents frames at wall-clock time (1 s of silence =
        // fps ticks at this timescale), which keeps RTP/decoder timing honest.
        let timestamp = CMTime(
            value: CMTimeValue(captureTick),
            timescale: CMTimeScale(fps)
        )
        captureTick += 1

        if suppressDuplicates && !frameChanged(pixelBuffer) {
            // Screen unchanged since the last emitted frame.
            if frameStart - lastEmittedAtNs >= Self.forcedFrameIntervalNs {
                // Static for >= 1 s: emit one forced IDR to keep the pipeline
                // warm and the recovery/late-join keyframe cadence unchanged.
                encoder.encode(pixelBuffer: pixelBuffer, timestamp: timestamp, forceKeyframe: true)
                remember(pixelBuffer)
                lastEmittedAtNs = frameStart
                lastIDRAtNs = frameStart
                emittedFrames += 1
                forcedKeyframes += 1
            } else {
                // Recently emitted (or nothing visible to show) — skip encode
                // and let the USB/bridge/browser path rest.
                suppressedFrames += 1
            }
        } else {
            // Content changed (or suppression off / first frame).
            let forceKeyframe = frameStart - lastIDRAtNs >= Self.forcedFrameIntervalNs
            encoder.encode(pixelBuffer: pixelBuffer, timestamp: timestamp, forceKeyframe: forceKeyframe)
            remember(pixelBuffer)
            lastEmittedAtNs = frameStart
            if forceKeyframe { lastIDRAtNs = frameStart }
            emittedFrames += 1
        }

        logCountersIfDue(frameStart)

        let elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - frameStart
        if elapsed < frameInterval {
            try await Task.sleep(nanoseconds: frameInterval - elapsed)
        }
    }

    /// True when the scaled encoder input differs from the last emitted frame.
    /// Byte-identical captures (JPEG screenshots are deterministic) short-circuit
    /// through memcmp; a bounded tolerance scan absorbs imperceptible noise such
    /// as a status-bar clock digit without treating it as motion.
    private func frameChanged(_ buffer: CVPixelBuffer) -> Bool {
        guard let reference = referenceData else { return true }

        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            return true
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let size = bytesPerRow * CVPixelBufferGetHeight(buffer)
        guard reference.count == size else { return true }

        return reference.withUnsafeBytes { ref in
            let refBytes = ref.bindMemory(to: UInt8.self)
            guard let refBase = refBytes.baseAddress else { return true }
            let src = base.assumingMemoryBound(to: UInt8.self)

            if memcmp(src, refBase, size) == 0 {
                return false
            }

            let maxDiff = Int(Double(size) * Self.maxChangedByteRatio)
            var diff = 0
            for i in 0..<size {
                if src[i] != refBase[i] {
                    diff += 1
                    if diff > maxDiff {
                        return true
                    }
                }
            }
            return false
        }
    }

    /// Retain a stride-aware copy of an emitted frame as the comparison basis.
    private func remember(_ buffer: CVPixelBuffer) {
        let status = CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard status == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else {
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let size = bytesPerRow * CVPixelBufferGetHeight(buffer)
        if referenceData == nil || referenceData!.count != size {
            referenceData = Data(count: size)
        }
        referenceData?.withUnsafeMutableBytes { dst in
            if let dstBase = dst.baseAddress {
                dstBase.copyMemory(from: base, byteCount: size)
            }
        }
    }

    private func logCountersIfDue(_ now: UInt64) {
        guard now - lastCountersLogAtNs >= Self.countersLogIntervalNs else { return }
        lastCountersLogAtNs = now
        logger.info(
            "S08 suppression: emitted=\(self.emittedFrames) skipped=\(self.suppressedFrames) forcedIDR=\(self.forcedKeyframes) mode=\(self.suppressDuplicates ? "on" : "off")"
        )
    }

    private func configureEncoder(
        for cgImage: CGImage,
        fps: Int,
        bitrate: Int,
        quality: Float,
        scale: Float
    ) throws {
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)

        var scaledWidth = Int(originalWidth * CGFloat(scale))
        var scaledHeight = Int(originalHeight * CGFloat(scale))
        scaledWidth = scaledWidth - (scaledWidth % 2)
        scaledHeight = scaledHeight - (scaledHeight % 2)
        scaledWidth = max(64, scaledWidth)
        scaledHeight = max(64, scaledHeight)

        targetSize = CGSize(width: scaledWidth, height: scaledHeight)

        logger.info("Encoder: \(scaledWidth)x\(scaledHeight) @ \(fps)fps, \(bitrate/1_000_000)Mbps")

        pixelBufferPool = CGImage.createPixelBufferPool(
            size: targetSize!,
            minimumBufferCount: 3
        )

        let enc = H264Encoder()
        try enc.configureCompressSession(H264EncoderConfig(
            width: Int32(scaledWidth),
            height: Int32(scaledHeight),
            isRealTime: true,
            expectedFrameRate: fps,
            averageBitRate: bitrate,
            quality: quality,
            emitAccessUnitDelimiter: emitAccessUnitDelimiter
        ))

        enc.naluHandling = { [weak self] data in
            self?.continuation?.yield(data)
        }

        encoder = enc
        isConfigured = true
    }
}
