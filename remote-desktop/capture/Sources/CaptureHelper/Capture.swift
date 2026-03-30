import Foundation
import ScreenCaptureKit
import CoreMedia

@available(macOS 13.0, *)
final class CaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var encoder: H264Encoder?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            fputs("capture: no display found\n", stderr)
            exit(1)
        }

        let encoder = try H264Encoder(width: display.width, height: display.height)
        self.encoder = encoder

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        let captureQueue = DispatchQueue(label: "sdg.capture", qos: .userInteractive)
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream?.startCapture()
        fputs("capture: started \(display.width)x\(display.height) @ 30fps\n", stderr)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        encoder?.encode(buffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("capture: stream stopped: \(error)\n", stderr)
        exit(1)
    }
}
