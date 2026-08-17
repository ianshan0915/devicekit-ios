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
    private let actionCaptureMode: Int
    private var referenceData: Data?          // stride-aware copy of last emitted frame
    private var lastEmittedAtNs: UInt64 = 0   // monotonic clock of last encode
    private var lastIDRAtNs: UInt64 = 0       // monotonic clock of last keyframe
    private var captureTick: UInt64 = 0       // capture counter used for timestamps

    private static let forcedFrameIntervalNs: UInt64 = 1_000_000_000  // 1 s floor
    // B04: B01's 250 ms window improved the median but ended before the slow
    // post-action transitions that dominate p95. Keep the first 300 ms hot,
    // then continue at a 60 fps ceiling through the measured tail. Both a hard
    // deadline and an attempt cap bound a static-screen action; the first
    // material pixel change still ends the window immediately.
    private static let actionCaptureFastWindowNs: UInt64 = 300_000_000
    private static let actionCaptureWindowNs: UInt64 = 1_750_000_000
    private static let aggressiveCaptureIntervalNs: UInt64 = 10_000_000
    private static let tailCaptureIntervalNs: UInt64 = 16_666_667
    private static let maxActionCaptureAttemptsV2: UInt64 = 96
    // B05 guarded successor. Limit *extra* captures rather than total frames:
    // the configured normal cadence must continue for the full observation
    // window, especially on a focused 60 fps phone. Once this budget is spent,
    // the action window observes at the ordinary cadence and adds no more load.
    private static let maxGuardedActionCaptureAttempts: UInt64 = 128
    private static let maxGuardedExtraCaptureAttempts: UInt64 = 24
    private static let guardedSlowCaptureNs: UInt64 = 250_000_000
    private static let guardedCooldownNs: UInt64 = 30_000_000_000
    private static let guardedTimeoutsBeforeCooldown: UInt64 = 2
    private let streamCreatedAtNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    private var lastActionHintGeneration: UInt64 = 0
    private var actionCaptureStartedAtNs: UInt64 = 0
    private var actionCaptureUntilNs: UInt64 = 0
    private var actionCaptureAttempts: UInt64 = 0
    private var guardedExtraCaptureAttempts: UInt64 = 0
    private var guardedBudgetLimitedThisWindow = false
    private var consecutiveActionTimeouts: UInt64 = 0
    private var actionCaptureCooldownUntilNs: UInt64 = 0
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
    private var actionHints: UInt64 = 0
    private var aggressiveCaptures: UInt64 = 0
    private var tailCaptures: UInt64 = 0
    private var actionChanges: UInt64 = 0
    private var actionTimeouts: UInt64 = 0
    private var staleActionHints: UInt64 = 0
    private var guardedBudgetStops: UInt64 = 0
    private var guardedSlowStops: UInt64 = 0
    private var guardedCooldowns: UInt64 = 0
    private var guardedHintsSkipped: UInt64 = 0
    private var guardedExpiredHints: UInt64 = 0
    private var lastCountersLogAtNs: UInt64 = 0
    private static let countersLogIntervalNs: UInt64 = 10_000_000_000

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "devicekit-ios",
        category: "H264FrameProducer"
    )

    init() {
        self.suppressDuplicates = true
        self.actionCaptureMode = 0
    }

    init(suppressDuplicates: Bool) {
        self.suppressDuplicates = suppressDuplicates
        self.actionCaptureMode = 0
    }

    init(suppressDuplicates: Bool, actionCaptureMode: Int) {
        self.suppressDuplicates = suppressDuplicates
        self.actionCaptureMode = actionCaptureMode
    }

    func makeNALUnitStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation

            continuation.onTermination = { [weak self] _ in
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
        beginActionCaptureWindowIfNeeded(frameStart)

        guard let uiImage = try? FBScreenshot.captureUIImage(
            withQuality: 0.9,
            timeout: captureTimeout
        ), let cgImage = uiImage.cgImage else {
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

        // Compute actual pixel change even when duplicate suppression is off so
        // the B01 A/B knob can end an action window on the same visual event.
        let contentChanged = frameChanged(pixelBuffer)

        if suppressDuplicates && !contentChanged {
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

        let frameFinished = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let actionCaptureInterval = nextActionCaptureInterval(
            now: frameFinished,
            contentChanged: contentChanged,
            captureElapsed: frameFinished - frameStart,
            frameInterval: frameInterval
        )
        logCountersIfDue(frameStart)

        let elapsed = frameFinished - frameStart
        let targetInterval: UInt64
        if let requested = actionCaptureInterval, actionCaptureMode == 2 {
            // Allow extra captures only while they are cheap. Sleeping for at
            // least the capture's own duration caps experimental screenshot
            // duty at 50%; the ordinary frame interval remains the upper bound
            // so the guard can never make the configured stream slower.
            let elapsed = frameFinished - frameStart
            let (doubleElapsed, overflow) = elapsed.multipliedReportingOverflow(by: 2)
            let dutyLimited = overflow ? UInt64.max : doubleElapsed
            targetInterval = min(frameInterval, max(requested, dutyLimited))
        } else {
            targetInterval = actionCaptureInterval ?? frameInterval
        }
        if elapsed < targetInterval {
            try await Task.sleep(nanoseconds: targetInterval - elapsed)
        } else if actionCaptureInterval != nil {
            // Screenshot capture may already exceed the fairness floor. Yield
            // once so an action/RPC task cannot be starved by the bounded burst.
            await Task.yield()
        }
    }

    @MainActor
    private func beginActionCaptureWindowIfNeeded(_ now: UInt64) {
        guard actionCaptureMode != 0 else { return }
        let hint = ActionCaptureHints.snapshot()
        guard hint.generation != lastActionHintGeneration else { return }

        lastActionHintGeneration = hint.generation
        actionHints += 1
        // A newly-created stream must not replay an action completed before it
        // existed. The longer p95 window makes this boundary load-bearing.
        guard hint.requestedAtNs >= streamCreatedAtNs else {
            staleActionHints += 1
            return
        }
        if actionCaptureMode == 2, now < actionCaptureCooldownUntilNs {
            guardedHintsSkipped += 1
            return
        }
        actionCaptureStartedAtNs = hint.requestedAtNs
        actionCaptureAttempts = 0
        guardedExtraCaptureAttempts = 0
        guardedBudgetLimitedThisWindow = false
        let (deadline, overflow) = hint.requestedAtNs.addingReportingOverflow(
            Self.actionCaptureWindowNs
        )
        actionCaptureUntilNs = overflow ? UInt64.max : deadline

        // The action may have expired while another main-actor task was busy.
        if now >= actionCaptureUntilNs {
            clearActionCaptureWindow()
            actionTimeouts += 1
            if actionCaptureMode == 2 {
                guardedExpiredHints += 1
                enterGuardedCooldown(now)
            }
        }
    }

    private func nextActionCaptureInterval(
        now: UInt64,
        contentChanged: Bool,
        captureElapsed: UInt64,
        frameInterval: UInt64
    ) -> UInt64? {
        guard actionCaptureMode != 0, actionCaptureUntilNs != 0 else { return nil }
        if contentChanged {
            clearActionCaptureWindow()
            consecutiveActionTimeouts = 0
            actionChanges += 1
            return nil
        }
        if actionCaptureMode == 2, captureElapsed >= Self.guardedSlowCaptureNs {
            clearActionCaptureWindow()
            guardedSlowStops += 1
            enterGuardedCooldown(now)
            return nil
        }
        let attemptLimit = actionCaptureMode == 2
            ? Self.maxGuardedActionCaptureAttempts
            : Self.maxActionCaptureAttemptsV2
        if now >= actionCaptureUntilNs || actionCaptureAttempts >= attemptLimit {
            let exhaustedBudget = actionCaptureAttempts >= attemptLimit
            clearActionCaptureWindow()
            actionTimeouts += 1
            if actionCaptureMode == 2 {
                consecutiveActionTimeouts += 1
                if exhaustedBudget { guardedBudgetStops += 1 }
                if consecutiveActionTimeouts >= Self.guardedTimeoutsBeforeCooldown {
                    enterGuardedCooldown(now)
                }
            }
            return nil
        }
        actionCaptureAttempts += 1
        let age = now >= actionCaptureStartedAtNs ? now - actionCaptureStartedAtNs : 0
        let requested: UInt64
        if age < Self.actionCaptureFastWindowNs {
            aggressiveCaptures += 1
            requested = Self.aggressiveCaptureIntervalNs
        } else {
            tailCaptures += 1
            requested = Self.tailCaptureIntervalNs
        }
        if actionCaptureMode == 2, requested < frameInterval {
            if guardedExtraCaptureAttempts >= Self.maxGuardedExtraCaptureAttempts {
                if !guardedBudgetLimitedThisWindow {
                    guardedBudgetLimitedThisWindow = true
                    guardedBudgetStops += 1
                }
                return frameInterval
            }
            guardedExtraCaptureAttempts += 1
        }
        return requested
    }

    private func clearActionCaptureWindow() {
        actionCaptureStartedAtNs = 0
        actionCaptureUntilNs = 0
        actionCaptureAttempts = 0
        guardedExtraCaptureAttempts = 0
    }

    private func enterGuardedCooldown(_ now: UInt64) {
        let (until, overflow) = now.addingReportingOverflow(Self.guardedCooldownNs)
        actionCaptureCooldownUntilNs = overflow ? UInt64.max : until
        consecutiveActionTimeouts = 0
        guardedCooldowns += 1
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
            "H264 counters: emitted=\(self.emittedFrames) skipped=\(self.suppressedFrames) forcedIDR=\(self.forcedKeyframes) dup=\(self.suppressDuplicates ? "on" : "off") actionCaptureMode=\(self.actionCaptureMode) hints=\(self.actionHints) aggressive=\(self.aggressiveCaptures) tail=\(self.tailCaptures) changed=\(self.actionChanges) timedOut=\(self.actionTimeouts) stale=\(self.staleActionHints) budgetStops=\(self.guardedBudgetStops) slowStops=\(self.guardedSlowStops) cooldowns=\(self.guardedCooldowns) hintsSkipped=\(self.guardedHintsSkipped) expiredHints=\(self.guardedExpiredHints)"
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
            quality: quality
        ))

        enc.naluHandling = { [weak self] data in
            self?.continuation?.yield(data)
        }

        encoder = enc
        isConfigured = true
    }
}
