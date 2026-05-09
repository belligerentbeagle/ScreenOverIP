import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import CoreVideo
import AppKit

/// Wraps ScreenCaptureKit (SCStream) for capturing a chosen display or window
/// and emitting CVPixelBuffer frames to a closure.
@available(macOS 13.0, *)
final class ScreenCapture: NSObject, SCStreamDelegate, SCStreamOutput {

    enum CaptureError: Error {
        case notAuthorized
        case noContent
        case alreadyRunning
        case streamFailure(Error)
    }

    /// What to capture.
    enum Source: Equatable {
        case display(SCDisplay)
        case window(SCWindow)

        static func == (lhs: Source, rhs: Source) -> Bool {
            switch (lhs, rhs) {
            case let (.display(a), .display(b)): return a.displayID == b.displayID
            case let (.window(a), .window(b)): return a.windowID == b.windowID
            default: return false
            }
        }
    }

    /// Caller-supplied frame handler. Called on a background queue.
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Caller-supplied error/lifecycle handler. Called on a background queue.
    var onStop: ((Error?) -> Void)?

    private(set) var isRunning = false
    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.screenoverip.capture.output", qos: .userInteractive)

    /// Lists displays and on-screen windows available for capture.
    static func availableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Begin capture from the given source.
    /// - Parameters:
    ///   - source: display or window to capture
    ///   - frameRate: target frames per second (1...60)
    ///   - maxDimension: longest edge in pixels (frames are downscaled to fit). 0 = native.
    func start(source: Source, frameRate: Int = 30, maxDimension: Int = 1280) async throws {
        if isRunning { throw CaptureError.alreadyRunning }

        let filter: SCContentFilter
        let nativeWidth: Int
        let nativeHeight: Int

        switch source {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
            nativeWidth = display.width
            nativeHeight = display.height
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            nativeWidth = Int(window.frame.width)
            nativeHeight = Int(window.frame.height)
        }

        // Compute output dimensions, preserving aspect ratio.
        let (outW, outH) = Self.fit(width: max(nativeWidth, 1),
                                    height: max(nativeHeight, 1),
                                    maxDimension: maxDimension == 0 ? max(nativeWidth, nativeHeight) : maxDimension)

        let cfg = SCStreamConfiguration()
        cfg.width = outW
        cfg.height = outH
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(60, frameRate))))
        cfg.queueDepth = 5
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        // Note: `scalesToFit` is macOS 14+ only — relying on width/height to
        // size the output buffer. SCStream will scale the source to fit.

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()

        self.stream = stream
        self.isRunning = true
    }

    func stop() async {
        guard let stream = stream else { return }
        do { try await stream.stopCapture() } catch { /* ignore */ }
        self.stream = nil
        self.isRunning = false
        onStop?(nil)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Only deliver "complete" frames.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete else {
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.isRunning = false
        self.stream = nil
        onStop?(error)
    }

    // MARK: - Helpers

    private static func fit(width w: Int, height h: Int, maxDimension: Int) -> (Int, Int) {
        let longest = max(w, h)
        if longest <= maxDimension { return (w, h) }
        let scale = Double(maxDimension) / Double(longest)
        // SCStream prefers even dimensions.
        let outW = max(2, Int((Double(w) * scale).rounded()) & ~1)
        let outH = max(2, Int((Double(h) * scale).rounded()) & ~1)
        return (outW, outH)
    }
}

/// Encodes CVPixelBuffer to JPEG Data using a single shared CIContext.
final class JPEGEncoder {
    static let shared = JPEGEncoder()
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Encode pixel buffer as JPEG. `quality` is 0.0 ... 1.0.
    func encode(_ pixelBuffer: CVPixelBuffer, quality: Double = 0.7) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let opts: [CIImageRepresentationOption: Any] = [
            qualityKey: NSNumber(value: quality)
        ]
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: opts)
    }
}
