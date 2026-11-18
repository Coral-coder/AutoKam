#if os(iOS)
import AVFoundation
import UniformTypeIdentifiers

/// Encodes one take as fragmented MP4 (HLS-style 1 s segments). Each segment is appended to
/// the local file and handed to `onSegment` the moment it's ready, so the Mac receives the
/// take while it's still being recorded. All append calls come from the capture queue.
final class TakeWriter: NSObject, AVAssetWriterDelegate {
    struct Config {
        var hevc: Bool
        /// Wait (briefly) for frames in this orientation before starting, so a rotation
        /// change that is still being applied doesn't end up in the take.
        var expectPortrait: Bool?
    }

    private let config: Config
    private let onSegment: (Data, Int64) -> Void
    private var fileHandle: FileHandle?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var dimensions: CMVideoDimensions?
    private var startPTS = CMTime.invalid
    private var lastPTS = CMTime.invalid
    private var skippedFrames = 0
    private var failed = false

    private let lock = NSLock()
    private var bytes: Int64 = 0

    init(fileURL: URL, config: Config, onSegment: @escaping (Data, Int64) -> Void) {
        self.config = config
        self.onSegment = onSegment
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        super.init()
    }

    var bytesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !failed, let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            if let wantPortrait = config.expectPortrait, (dims.height > dims.width) != wantPortrait, skippedFrames < 20 {
                skippedFrames += 1
                return
            }
            guard setUp(dimensions: dims, start: pts) else {
                failed = true
                return
            }
        }
        guard let writer, writer.status == .writing, let videoInput, let expected = dimensions,
              expected.width == dims.width, expected.height == dims.height else { return }
        guard videoInput.isReadyForMoreMediaData, let shifted = retime(sampleBuffer) else { return }
        if videoInput.append(shifted) {
            lastPTS = pts
        } else if writer.status == .failed {
            failed = true
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !failed, let writer, writer.status == .writing, let audioInput,
              audioInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard CMTimeCompare(pts, startPTS) >= 0, let shifted = retime(sampleBuffer) else { return }
        audioInput.append(shifted)
    }

    /// Calls back with (bytes written, duration in seconds, success).
    func finish(_ completion: @escaping (Int64, Double, Bool) -> Void) {
        guard let writer, writer.status == .writing else {
            closeFile()
            completion(bytesWritten, 0, false)
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        var duration = 0.0
        if startPTS.isValid && lastPTS.isValid {
            duration = CMTimeGetSeconds(CMTimeSubtract(lastPTS, startPTS)) + 1.0 / 30.0
        }
        writer.finishWriting { [self] in
            let ok = writer.status == .completed
            self.closeFile()
            completion(self.bytesWritten, duration, ok)
        }
    }

    // MARK: - AVAssetWriterDelegate

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock()
        let offset = bytes
        try? fileHandle?.write(contentsOf: segmentData)
        bytes += Int64(segmentData.count)
        lock.unlock()
        onSegment(segmentData, offset)
    }

    // MARK: - Private

    private func setUp(dimensions dims: CMVideoDimensions, start: CMTime) -> Bool {
        guard let contentType = UTType(AVFileType.mp4.rawValue) else { return false }
        let writer = AVAssetWriter(contentType: contentType)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = self

        let uhd = Int(dims.width) * Int(dims.height) > 3_000_000
        let bitrate: Int
        if config.hevc {
            bitrate = uhd ? 40_000_000 : 14_000_000
        } else {
            bitrate = uhd ? 60_000_000 : 20_000_000
        }
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            AVVideoExpectedSourceFrameRateKey: 30,
        ]
        if !config.hevc {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: config.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return false }
        writer.add(video)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) {
            writer.add(audio)
            audioInput = audio
        }

        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.videoInput = video
        self.dimensions = dims
        self.startPTS = start
        return true
    }

    /// Shifts timestamps so every take starts at 0.
    private func retime(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in 0 ..< count {
            timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, startPTS)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, startPTS)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timings,
                                              sampleBufferOut: &out)
        return out
    }

    private func closeFile() {
        lock.lock()
        try? fileHandle?.close()
        fileHandle = nil
        lock.unlock()
    }
}
#endif
