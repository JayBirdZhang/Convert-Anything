import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Audio and video with macOS's own frameworks. Video uses the Mac's hardware encoder; audio is decoded
/// to plain samples and re-encoded by Core Audio, or by the bundled LAME library for MP3.
nonisolated enum MediaConversion {
    static func convert(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch (request.to.kind, request.to) {
        case (.audio, .m4b):
            try await Audiobook.make(request, output: output, progress: progress)
        case (.audio, _):
            try await AudioConversion.convert(request, output: output, progress: progress)
        case (.video, _) where request.from == .gif:
            try await GIFVideo.makeVideo(from: request.input, output: output, fileType: fileType(request.to), progress: progress)
        case (.video, _):
            try await VideoExport.export(request, output: output, progress: progress)
        case (.image, .gif):
            try await GIFVideo.makeGIF(from: request.input, output: output, quality: request.quality, progress: progress)
        case (.image, _):
            try await firstFrame(request, output: output)
        default:
            throw ConversionError.unsupported(request.from, request.to)
        }
    }

    static func fileType(_ format: Format) -> AVFileType {
        switch format {
        case .mov: .mov
        case .m4v: .m4v
        default: .mp4
        }
    }

    /// A video renamed to an image format becomes a picture of its first frame.
    private static func firstFrame(_ request: Converter.Request, output: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: request.input))
        generator.appliesPreferredTrackTransform = true
        if #available(macOS 15, *) { generator.dynamicRangePolicy = .forceSDR }   // HDR video → normal colors
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let image: CGImage
        do {
            image = try await generator.image(at: .zero).image
        } catch {
            throw ConversionError.failed("Couldn't read a frame from this video.")
        }
        if request.to == .webp {
            try WebP.write(image, to: output, quality: request.quality)
        } else {
            try ImageConversion.write(image, to: output, format: request.to,
                                      properties: [kCGImageDestinationLossyCompressionQuality: request.quality.imageQuality])
        }
    }
}

// MARK: - Video

nonisolated enum VideoExport {
    static func export(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: request.input)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), let video = tracks.first else {
            throw ConversionError.failed("This file has no video macOS can read.")
        }
        // Copying the streams as-is is instant and lossless, but keeps the original size,
        // so it's skipped when smaller files are wanted.
        var presets: [String] = []
        if request.quality != .small, await canCopy(video, into: request.to) {
            presets.append(AVAssetExportPresetPassthrough)
        }
        presets.append(request.quality == .small ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHighestQuality)

        for (index, preset) in presets.enumerated() {
            do {
                try await run(asset: asset, preset: preset, output: output, fileType: MediaConversion.fileType(request.to), progress: progress)
                return
            } catch let error as ConversionError where error.isCancellation {
                throw error
            } catch {
                try? FileManager.default.removeItem(at: output)
                if index == presets.count - 1 { throw error }
            }
        }
    }

    /// H.264 and HEVC can go into any of the MP4 family as-is; QuickTime also takes ProRes and others.
    private static func canCopy(_ track: AVAssetTrack, into format: Format) async -> Bool {
        guard let description = try? await track.load(.formatDescriptions).first else { return false }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        let mp4Codecs: [CMVideoCodecType] = [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha]
        return format == .mov || mp4Codecs.contains(codec)
    }

    private static func run(asset: AVAsset, preset: String, output: URL, fileType: AVFileType,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.failed("This video can't be converted.")
        }
        session.shouldOptimizeForNetworkUse = fileType != .mov
        let box = SessionBox(session)
        try await withTaskCancellationHandler {
            if #available(macOS 15, *) {
                let watcher = Task {
                    for await state in session.states(updateInterval: 0.25) {
                        if case .exporting(let p) = state { progress(p.fractionCompleted) }
                    }
                }
                defer { watcher.cancel() }
                try await session.export(to: output, as: fileType)
            } else {
                session.outputURL = output
                session.outputFileType = fileType
                let watcher = Task {
                    while !Task.isCancelled {
                        progress(Double(box.session.progress))
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { watcher.cancel() }
                await session.export()
                if let error = session.error { throw error }
                guard session.status == .completed else { throw ConversionError.failed("The video export didn't finish.") }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        if Task.isCancelled { throw ConversionError.cancelled }
    }
}

nonisolated private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}

extension ConversionError {
    nonisolated var isCancellation: Bool { if case .cancelled = self { true } else { false } }
}

// MARK: - GIF

nonisolated enum GIFVideo {
    /// Samples the video at the quality's frame rate (or its own, if lower) and writes a looping GIF,
    /// encoding each frame as it arrives (see GIFEncoder). Runs off the main thread: it's heavy work.
    @concurrent
    static func makeGIF(from input: URL, output: URL, quality: Quality, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration > 0, let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.failed("Couldn't read this video.")
        }
        let settings = quality.gifSettings
        let videoRate = Double((try? await track.load(.nominalFrameRate)) ?? 0)
        let fps = videoRate > 0 ? min(Double(settings.fps), videoRate) : Double(settings.fps)
        let count = max(1, Int((duration * fps).rounded()))
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: settings.width, height: settings.width)   // Longest side; never enlarges
        // iPhone videos are often HDR; tone-map them so the GIF's colors aren't washed out.
        if #available(macOS 15, *) { generator.dynamicRangePolicy = .forceSDR }
        let display = await displaySpace(of: track)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var encoder: GIFEncoder?
        var done = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            // Each frame lasts until the next one is due, and the last one until the video ends.
            let end = done + 1 < count ? Double(done + 1) / fps : duration
            let frameDuration = end - Double(done) / fps
            done += 1
            if var image = try? result.image {
                if let space = image.colorSpace, !CGColorSpaceUsesITUR_2100TF(space), let shown = image.copy(colorSpace: display) {
                    image = shown
                }
                if encoder == nil {
                    encoder = try GIFEncoder(url: output, width: image.width, height: image.height, noise: settings.noise)
                }
                try encoder?.addFrame(image, duration: frameDuration)
            } else {
                encoder?.extend(by: frameDuration)
            }
            progress(Double(done) / Double(count))
        }
        guard let encoder else { throw ConversionError.failed("Couldn't read frames from this video.") }
        try encoder.finish()
    }

    /// The space a video's frames are shown in. Video is tagged with the camera's curve (BT.709), but players show
    /// the stored values almost as they are, as sRGB-like display values; converting through the camera curve
    /// instead lifts the midtones and dulls every color. So the frames keep their primaries and get sRGB's curve.
    /// For screen recordings that's exactly what was on screen.
    private static func displaySpace(of track: AVAssetTrack) async -> CGColorSpace {
        let description = (try? await track.load(.formatDescriptions))?.first
        let primaries = description.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        }
        if primaries == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String {
            return CGColorSpace(name: CGColorSpace.itur_2020_sRGBGamma)!
        }
        if primaries == kCMFormatDescriptionColorPrimaries_P3_D65 as String {
            return CGColorSpace(name: CGColorSpace.displayP3)!
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!   // BT.709 and SD video, whose primaries are about the same
    }

    /// An animated GIF becomes an H.264 video, each frame shown for its own delay.
    static func makeVideo(from input: URL, output: URL, fileType: AVFileType, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.failed("Couldn't read this GIF.")
        }
        let count = CGImageSourceGetCount(source)
        // Video encoders need even dimensions.
        let width = first.width / 2 * 2, height = first.height / 2 * 2
        guard width > 0, height > 0 else { throw ConversionError.failed("This GIF is too small to become a video.") }

        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ConversionError.failed("Couldn't write the video.") }
        writer.startSession(atSourceTime: .zero)

        var time = CMTime.zero
        for index in 0..<count {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            draw(image, into: buffer, width: width, height: height)
            adaptor.append(buffer, withPresentationTime: time)
            time = time + CMTime(seconds: GIFEncoder.frameDelay(source, index) ?? 0.1, preferredTimescale: 600)
            progress(Double(index + 1) / Double(count))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: time)
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ConversionError.failed("Couldn't write the video.") }
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

// MARK: - Audio

nonisolated enum AudioConversion {
    static func convert(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await background {
            let source = try await openPCMSource(request.input, isVideo: request.from.kind == .video)
            let sink: PCMSink = request.to == .mp3
                ? try MP3Sink(url: output, format: source.format, quality: request.quality)
                : try CoreAudioSink(url: output, to: request.to, format: source.format, bitDepth: source.bitDepth, quality: request.quality)
            var written: AVAudioFramePosition = 0
            while let buffer = try source.read() {
                try Task.checkCancellation()
                try sink.write(buffer)
                written += AVAudioFramePosition(buffer.frameLength)
                if source.length > 0 { progress(min(1, Double(written) / Double(source.length))) }
            }
            guard written > 0 else { throw ConversionError.failed("This file has no audio.") }
            try sink.finish()
        }
    }
}

/// Decoded audio as 32-bit float, one channel per buffer plane.
nonisolated private protocol PCMSource {
    var format: AVAudioFormat { get }
    var length: AVAudioFramePosition { get }    // Estimated frames, for progress
    var bitDepth: UInt32 { get }                // Of the source file; 0 when compressed
    func read() throws -> AVAudioPCMBuffer?
}

/// Core Audio reads audio files directly (including FLAC and Ogg); videos go through AVFoundation.
nonisolated private func openPCMSource(_ url: URL, isVideo: Bool) async throws -> PCMSource {
    if !isVideo, let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) {
        return FileSource(file: file)
    }
    return try await TrackSource.open(url)
}

nonisolated private final class FileSource: PCMSource {
    let file: AVAudioFile
    init(file: AVAudioFile) { self.file = file }
    var format: AVAudioFormat { file.processingFormat }
    var length: AVAudioFramePosition { file.length }
    var bitDepth: UInt32 { file.fileFormat.streamDescription.pointee.mBitsPerChannel }

    func read() throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { return nil }
        try file.read(into: buffer)
        return buffer.frameLength > 0 ? buffer : nil
    }
}

/// The audio track of a video (or any file AVFoundation can open), decoded with AVAssetReader.
nonisolated private final class TrackSource: PCMSource {
    let format: AVAudioFormat
    let length: AVAudioFramePosition
    let bitDepth: UInt32 = 0
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    static func open(_ url: URL) async throws -> TrackSource {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.failed("This file has no audio track.")
        }
        guard let description = try? await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw ConversionError.failed("Couldn't read this file's audio.")
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        return try TrackSource(asset: asset, track: track, basic: basic, duration: duration)
    }

    private init(asset: AVAsset, track: AVAssetTrack, basic: AudioStreamBasicDescription, duration: Double) throws {
        let channels = AVAudioChannelCount(max(1, min(basic.mChannelsPerFrame, 8)))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: basic.mSampleRate, channels: channels, interleaved: false) else {
            throw ConversionError.failed("Couldn't read this file's audio.")
        }
        self.format = format
        length = AVAudioFramePosition(duration * basic.mSampleRate)
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: basic.mSampleRate, AVNumberOfChannelsKey: channels,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ConversionError.failed("Couldn't read this file's audio.") }
    }

    func read() throws -> AVAudioPCMBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            if status == noErr { return buffer }
        }
        if reader.status == .failed { throw reader.error ?? ConversionError.failed("Couldn't read this file's audio.") }
        return nil
    }
}

nonisolated private protocol PCMSink {
    func write(_ buffer: AVAudioPCMBuffer) throws
    func finish() throws
}

/// WAV, AIFF, FLAC and AAC/M4A, written by Core Audio (which also converts the sample rate when needed).
nonisolated private final class CoreAudioSink: PCMSink {
    private var file: AVAudioFile?

    /// `bitDepth` is the source's (0 for compressed audio), so lossless output doesn't grow for nothing.
    init(url: URL, to format: Format, format source: AVAudioFormat, bitDepth: UInt32, quality: Quality) throws {
        let channels = min(source.channelCount, format == .flac || format == .wav || format == .aiff ? 8 : 2)
        var rate = source.sampleRate
        var settings: [String: Any] = [AVNumberOfChannelsKey: channels]
        switch format {
        case .wav, .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = bitDepth >= 24 ? 24 : 16
        case .m4a, .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = quality.aacBitrate
            rate = min(rate, 48_000)
        default:
            throw ConversionError.failed("Can't write \(format.displayName) audio.")
        }
        settings[AVSampleRateKey] = rate
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch where settings[AVEncoderBitRateKey] != nil {
            // Low sample rates (speech recordings, 22 kHz mono) can't take a music bitrate; let the encoder pick.
            settings[AVEncoderBitRateKey] = nil
            file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {}
        guard file != nil else {
            throw ConversionError.failed("This Mac can't write \(format.displayName) audio.")
        }
        if channels < source.channelCount {
            throw ConversionError.failed("\(format.displayName) supports at most \(channels) channels.")
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws { try file?.write(from: buffer) }
    func finish() throws { file = nil }   // Releasing the file finishes it
}

/// MP3 through the LAME encoder, which is built into the app.
nonisolated private final class MP3Sink: PCMSink {
    private let lame: OpaquePointer
    private let handle: FileHandle
    private let channels: Int
    private var mp3 = [UInt8](repeating: 0, count: 1 << 18)

    init(url: URL, format: AVAudioFormat, quality: Quality) throws {
        guard let lame = lame_init() else { throw ConversionError.failed("Couldn't start the MP3 encoder.") }
        self.lame = lame
        channels = min(Int(format.channelCount), 2)
        lame_set_in_samplerate(lame, Int32(format.sampleRate))
        lame_set_num_channels(lame, Int32(channels))
        lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_VBR(lame, vbr_default)
        lame_set_VBR_quality(lame, Float(quality.mp3VBR))
        guard lame_init_params(lame) >= 0 else {
            lame_close(lame)
            throw ConversionError.failed("MP3 can't use this audio's sample rate.")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { lame_close(lame) }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let data = buffer.floatChannelData else { return }
        let left = data[0], right = channels == 2 ? data[1] : data[0]
        let count = lame_encode_buffer_ieee_float(lame, left, right, Int32(buffer.frameLength), &mp3, Int32(mp3.count))
        guard count >= 0 else { throw ConversionError.failed("The MP3 encoder failed.") }
        try handle.write(contentsOf: mp3[0..<Int(count)])
    }

    func finish() throws {
        let count = lame_encode_flush(lame, &mp3, Int32(mp3.count))
        if count > 0 { try handle.write(contentsOf: mp3[0..<Int(count)]) }
        // The header frame at the start of a VBR file lets players show the right duration.
        let tagSize = lame_get_lametag_frame(lame, &mp3, mp3.count)
        if tagSize > 0 && tagSize <= mp3.count {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: mp3[0..<tagSize])
        }
        try handle.close()
    }
}
