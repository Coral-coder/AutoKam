#if os(iOS)
import AVFoundation

/// Writes one take as a regular QuickTime movie (HEVC/H.264 video + AAC audio) on the phone.
/// The finished file is sent to the Mac the moment the take stops. All calls come from the
/// capture queue.
final class TakeWriter {
    struct Config {
        var hevc: Bool
        /// Clockwise degrees to show the sensor frames upright; stored in the file.
        var rotation: CGFloat
        var fps: Int
        /// Average video bitrate in bits per second.
        var bitrate: Int
    }

    struct Result {
        var bytes: Int64
        var duration: Double
        var ok: Bool
        /// How many audio buffers made it into the file; 0 means a silent take.
        var audioBuffers: Int
    }

    private let fileURL: URL
    private let config: Config
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    /// The microphone's format, picked up from audio that arrives before the first frame.
    private var audioFormat: CMFormatDescription?
    private var dimensions: CMVideoDimensions?
    private var startPTS = CMTime.invalid
    private var lastPTS = CMTime.invalid
    private var audioBuffers = 0
    private var failed = false

    init(fileURL: URL, config: Config) {
        self.fileURL = fileURL
        self.config = config
        // AVAssetWriter refuses to write over an existing file.
        try? FileManager.default.removeItem(at: fileURL)
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !failed, let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer == nil {
            guard setUp(dimensions: dims, start: pts) else {
                failed = true
                return
            }
        }
        guard let writer, writer.status == .writing, let videoInput, let expected = dimensions,
              expected.width == dims.width, expected.height == dims.height else { return }
        guard videoInput.isReadyForMoreMediaData else { return }
        if videoInput.append(sampleBuffer) {
            lastPTS = pts
        } else if writer.status == .failed {
            failed = true
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !failed else { return }
        guard let writer else {
            // Not started yet: remember the mic's format so the audio track matches it.
            audioFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
            return
        }
        guard writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let end = CMTimeAdd(pts, CMSampleBufferGetDuration(sampleBuffer))
        guard CMTimeCompare(end, startPTS) > 0 else { return } // entirely before the take
        if audioInput.append(sampleBuffer) {
            audioBuffers += 1
        }
    }

    func finish(_ completion: @escaping (Result) -> Void) {
        guard let writer, writer.status == .writing else {
            writer?.cancelWriting()
            completion(Result(bytes: 0, duration: 0, ok: false, audioBuffers: 0))
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        var duration = 0.0
        if startPTS.isValid && lastPTS.isValid {
            duration = CMTimeGetSeconds(CMTimeSubtract(lastPTS, startPTS)) + 1.0 / Double(max(config.fps, 1))
        }
        let url = fileURL
        let buffers = audioBuffers
        writer.finishWriting {
            let ok = writer.status == .completed
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            completion(Result(bytes: ok ? size : 0, duration: duration, ok: ok, audioBuffers: buffers))
        }
    }

    // MARK: - Private

    private func setUp(dimensions dims: CMVideoDimensions, start: CMTime) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: fileURL, fileType: .mov) else { return false }
        writer.shouldOptimizeForNetworkUse = false

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: config.bitrate,
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            AVVideoExpectedSourceFrameRateKey: config.fps,
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
        video.transform = CGAffineTransform(rotationAngle: config.rotation * .pi / 180)
        guard writer.canAdd(video) else { return false }
        writer.add(video)

        // Match the microphone: its sample rate (AAC tops out at 48 kHz) and mono or stereo.
        var sampleRate = 48_000.0
        var channels = 1
        if let format = audioFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            if asbd.mSampleRate >= 22_050 && asbd.mSampleRate <= 48_000 { sampleRate = asbd.mSampleRate }
            channels = asbd.mChannelsPerFrame >= 2 ? 2 : 1
        }
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 2 ? 192_000 : 128_000,
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) {
            writer.add(audio)
            audioInput = audio
        }

        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: start) // the file's timeline starts at 0 here
        self.writer = writer
        self.videoInput = video
        self.dimensions = dims
        self.startPTS = start
        return true
    }
}
#endif
