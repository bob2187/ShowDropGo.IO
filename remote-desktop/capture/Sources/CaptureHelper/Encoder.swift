import Foundation
import VideoToolbox
import CoreMedia

/// Encodes CVPixelBuffer frames to H.264 Annex B and writes them to stdout.
///
/// Wire format per frame (stdout):
///   [4 bytes big-endian length][1 byte flags: 0x01=keyframe][Annex B bytes]
final class H264Encoder {
    private var session: VTCompressionSession?
    private let stdout = FileHandle.standardOutput

    init(width: Int, height: Int, bitrateBps: Int = 1_500_000) throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encoderOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &s
        )
        guard status == noErr, let s else {
            throw EncoderError.sessionFailed(status)
        }
        self.session = s

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime,               value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering,   value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,         value: bitrateBps as CFTypeRef)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,    value: 60 as CFTypeRef)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Main_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: imageBuffer,
            presentationTimeStamp: pts, duration: .invalid,
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil
        )
    }

    // Called on the VT output queue — must be thread-safe (stdout writes are serialised here).
    fileprivate func handleEncodedSample(_ sample: CMSampleBuffer) {
        let isKey = isKeyframe(sample)

        var annexB = Data()

        if isKey, let params = extractParameterSets(from: sample) {
            annexB.append(params)
        }

        if let block = CMSampleBufferGetDataBuffer(sample) {
            annexB.append(avccToAnnexB(block))
        }

        guard !annexB.isEmpty else { return }

        var len = UInt32(annexB.count).bigEndian
        var flags: UInt8 = isKey ? 0x01 : 0x00
        stdout.write(Data(bytes: &len, count: 4))
        stdout.write(Data(bytes: &flags, count: 1))
        stdout.write(annexB)
    }

    // MARK: - Helpers

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    private func extractParameterSets(from sample: CMSampleBuffer) -> Data? {
        guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        var result = Data()
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if let ptr {
                result.append(contentsOf: startCode)
                result.append(Data(bytes: ptr, count: size))
            }
        }
        return result.isEmpty ? nil : result
    }

    private func avccToAnnexB(_ block: CMBlockBuffer) -> Data {
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        var totalLen = 0
        var rawPtr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &rawPtr)
        guard let rawPtr else { return Data() }

        var result = Data()
        var offset = 0
        while offset + 4 <= totalLen {
            let nalLen = Int(UInt32(bigEndian: rawPtr.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }))
            offset += 4
            guard offset + nalLen <= totalLen else { break }
            result.append(contentsOf: startCode)
            result.append(Data(bytes: rawPtr.advanced(by: offset), count: nalLen))
            offset += nalLen
        }
        return result
    }
}

enum EncoderError: Error {
    case sessionFailed(OSStatus)
}

// C-compatible callback — must be a free function.
private func encoderOutputCallback(
    refCon: UnsafeMutableRawPointer?,
    _: UnsafeMutableRawPointer?,
    status: OSStatus,
    _: VTEncodeInfoFlags,
    sample: CMSampleBuffer?
) {
    guard status == noErr, let sample, let refCon else { return }
    Unmanaged<H264Encoder>.fromOpaque(refCon).takeUnretainedValue().handleEncodedSample(sample)
}
