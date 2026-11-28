import AudioToolbox
import AVFoundation

/// Audiobooks (.m4b): AAC audio in an MPEG-4 file with a chapter list, the QuickTime chapter track that Apple Books,
/// QuickTime Player, Music and ffmpeg all read. A file renamed to .m4b becomes a book of one chapter; several renamed
/// together are then joined into one book (see `AppModel.combine`), a chapter per file in name order.
///
/// AAC audio is never re-encoded when it can be copied: a single AAC file is remuxed, and joining copies every part's
/// packets one after the other. Only parts whose sample rate or channel count differ from the rest are encoded again.
nonisolated enum Audiobook {
    /// One file renamed to .m4b.
    static func make(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await background {
            let asset = AVURLAsset(url: request.input)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let layout = await Layout(of: track) else {
                throw ConversionError.failed("This file has no audio.")
            }
            // An M4A that already has chapters is an audiobook in all but name: keep it exactly as it is.
            if request.from == .m4a, layout.isAAC, (try? await asset.load(.availableChapterLocales))?.isEmpty == false {
                try FileManager.default.copyItem(at: request.input, to: output)
                markAsAudiobook(output)
                return
            }
            let tags = await Tags(of: asset)
            let title = tags.title ?? request.title
            let duration = (try? await track.load(.timeRange).duration) ?? .zero
            // Raw .aac files frame every packet with a header MPEG-4 files don't have, so they're encoded too.
            let copies = layout.isAAC && request.from != .aac
            let book = try BookWriter(output: output, encodeTo: copies ? nil : layout.canonical(quality: request.quality),
                                      hint: layout.description,
                                      chapters: [Chapter(title: title, start: .zero, duration: duration)],
                                      metadata: tags.items(title: title))
            if copies {
                try await book.copy([(asset, track)], total: duration, progress: progress)
            } else {
                try await book.encode(asset, track, total: duration, progress: progress)
            }
            markAsAudiobook(output)
        }
    }

    /// Joins audiobooks (each a file the batch turned into .m4b) into one, a chapter per part, named after each
    /// part's title. The book is named after the album, and takes the first artist and cover art it finds.
    static func combine(_ parts: [URL], into output: URL, title fallback: String, quality: Quality,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        try await background {
            let temporary = FileManager.default.temporaryDirectory.appending(path: "ConvertAnything/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }

            var pieces: [Piece] = []
            for url in parts {
                guard let piece = await Piece(url) else { throw ConversionError.failed("Couldn't read \(url.lastPathComponent).") }
                pieces.append(piece)
            }
            // Copying packets needs one sample rate and channel count throughout. The layout most of the book is in
            // wins, and the other parts are encoded to match.
            var seconds: [Layout: Double] = [:]
            for piece in pieces { seconds[piece.layout, default: 0] += piece.duration.seconds }
            guard let target = seconds.max(by: { $0.value < $1.value })?.key else { return }
            // Progress counts encoding a second of audio as about ten times the work of copying one.
            let total = seconds.values.reduce(0, +)
            let work = total + 10 * (total - seconds[target, default: 0])
            var done = 0.0
            for index in pieces.indices where pieces[index].layout != target {
                let piece = pieces[index]
                let converted = temporary.appending(path: "\(index).m4a")
                let writer = try BookWriter(output: converted, encodeTo: target.settings(quality: quality),
                                            hint: piece.layout.description, chapters: [], metadata: [])
                let start = done, length = piece.duration.seconds
                try await writer.encode(piece.asset, piece.track, total: piece.duration) { fraction in
                    progress((start + 10 * fraction * length) / work)
                }
                done += 10 * length
                guard var redone = await Piece(converted) else { throw ConversionError.failed("Couldn't convert \(piece.name).") }
                redone.tags = piece.tags
                redone.name = piece.name
                pieces[index] = redone
            }

            var chapters: [Chapter] = []
            var start = CMTime.zero
            for piece in pieces {
                chapters.append(Chapter(title: piece.tags.title ?? piece.name, start: start, duration: piece.duration))
                start = start + piece.duration
            }
            var tags = Tags()
            tags.album = pieces.lazy.compactMap(\.tags.album).first
            tags.artist = pieces.lazy.compactMap(\.tags.artist).first
            tags.artwork = pieces.lazy.compactMap(\.tags.artwork).first
            let title = tags.album ?? fallback

            let book = temporary.appending(path: "book.m4a")
            let writer = try BookWriter(output: book, encodeTo: nil, hint: pieces[0].layout.description,
                                        chapters: chapters, metadata: tags.items(title: title))
            let copied = done
            try await writer.copy(pieces.map { ($0.asset, $0.track) }, total: start) { fraction in
                progress(min(1, (copied + fraction * total) / work))
            }
            markAsAudiobook(book)
            try FileManager.default.moveItem(at: book, to: output)
        }
    }

    /// The album the files belong to, which names the book.
    static func album(of parts: [URL]) async -> String? {
        for url in parts {
            if let album = await Tags(of: AVURLAsset(url: url)).album { return album }
        }
        return nil
    }

    /// AVFoundation writes MPEG-4 audio with the "M4A " brand. Apple's own audiobooks say "M4B ", which is how
    /// Convert Anything (and some players) tell them apart from music.
    private static func markAsAudiobook(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12,
              head[4..<12].elementsEqual(Array("ftypM4A ".utf8)) else { return }
        try? handle.seek(toOffset: 8)
        try? handle.write(contentsOf: Data("M4B ".utf8))
    }
}

// MARK: - What the parts hold

nonisolated private struct Chapter {
    let title: String
    let start: CMTime
    let duration: CMTime
}

/// Sample rate, channels and codec: what has to match for packets to be copied from one file into another.
nonisolated private struct Layout: Hashable {
    let formatID: AudioFormatID
    let sampleRate: Double
    let channels: UInt32
    let framesPerPacket: UInt32
    let description: CMFormatDescription

    init?(of track: AVAssetTrack) async {
        guard let description = try? await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        formatID = basic.mFormatID
        sampleRate = basic.mSampleRate
        channels = basic.mChannelsPerFrame
        framesPerPacket = basic.mFramesPerPacket
        self.description = description
    }

    var isAAC: Bool {
        [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2].contains(formatID) && framesPerPacket > 0
    }

    static func == (a: Layout, b: Layout) -> Bool {
        a.formatID == b.formatID && a.sampleRate == b.sampleRate && a.channels == b.channels && a.framesPerPacket == b.framesPerPacket
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(formatID)
        hasher.combine(sampleRate)
        hasher.combine(channels)
    }

    /// Audio that isn't AAC yet is encoded at 44.1 kHz, mono or stereo as it was, so files from different sources
    /// still match and can be joined without encoding them twice.
    func canonical(quality: Quality) -> [String: Any] {
        Self.settings(formatID: kAudioFormatMPEG4AAC, sampleRate: 44_100, channels: min(max(channels, 1), 2), quality: quality)
    }

    /// Encoding another file to match this one.
    func settings(quality: Quality) -> [String: Any] {
        Self.settings(formatID: formatID, sampleRate: sampleRate, channels: channels, quality: quality)
    }

    /// Books are speech, so a channel gets less than music would: 64 kbit/s each when balanced.
    private static func settings(formatID: AudioFormatID, sampleRate: Double, channels: UInt32, quality: Quality) -> [String: Any] {
        let perChannel = switch quality { case .best: 96_000; case .balanced: 64_000; case .small: 40_000 }
        var settings: [String: Any] = [
            AVFormatIDKey: formatID, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: perChannel * Int(channels),
        ]
        if channels <= 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        return settings
    }
}

/// The title, album, artist and cover art of a file, from whichever kind of tags it has (MP4, ID3, Vorbis comments…).
nonisolated private struct Tags {
    var title: String?
    var album: String?
    var artist: String?
    var artwork: Data?

    init() {}

    init(of asset: AVAsset) async {
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            switch item.commonKey {
            case .commonKeyTitle where title == nil: title = await Self.text(item)
            case .commonKeyAlbumName where album == nil: album = await Self.text(item)
            case .commonKeyArtist where artist == nil: artist = await Self.text(item)
            case .commonKeyArtwork where artwork == nil: artwork = try? await item.load(.dataValue)
            default: break
            }
        }
    }

    private static func text(_ item: AVMetadataItem) async -> String? {
        guard let text = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return text.isEmpty ? nil : text
    }

    /// The book's own tags. Cover art is kept when it's a JPEG or PNG, the two kinds MP4 files hold.
    func items(title: String) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, type: CFString? = nil) -> AVMetadataItem? {
            guard let value else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if let type { item.dataType = type as String }
            return item
        }
        var artworkType: CFString?
        if let artwork {
            if artwork.starts(with: [0xFF, 0xD8, 0xFF]) { artworkType = kCMMetadataBaseDataType_JPEG }
            if artwork.starts(with: [0x89, 0x50, 0x4E, 0x47]) { artworkType = kCMMetadataBaseDataType_PNG }
        }
        return [
            item(.iTunesMetadataSongName, title as NSString),
            item(.iTunesMetadataAlbum, album as NSString?),
            item(.iTunesMetadataArtist, artist as NSString?),
            item(.iTunesMetadataAlbumArtist, artist as NSString?),
            item(.iTunesMetadataUserGenre, "Audiobook" as NSString),
            artworkType.flatMap { item(.iTunesMetadataCoverArt, artwork as NSData?, type: $0) },
        ].compactMap { $0 }
    }
}

/// A finished one-chapter book about to be joined to others.
nonisolated private struct Piece {
    let asset: AVAsset
    let track: AVAssetTrack
    let layout: Layout
    let duration: CMTime    // Every packet's worth of audio, which is where the next part starts
    var name: String
    var tags: Tags

    init?(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let layout = await Layout(of: track), layout.isAAC,
              let packets = Self.packetCount(url) else { return nil }
        self.asset = asset
        self.track = track
        self.layout = layout
        // Copied packets keep the encoder's few milliseconds of lead-in and padding, so a part lasts all its packets,
        // which the file's packet table says without reading them.
        duration = CMTime(value: CMTimeValue(packets) * CMTimeValue(layout.framesPerPacket), timescale: CMTimeScale(layout.sampleRate))
        name = url.deletingPathExtension().lastPathComponent
        tags = await Tags(of: asset)
    }

    private static func packetCount(_ url: URL) -> UInt64? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileM4AType, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var packets: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &size, &packets) == noErr, packets > 0 else { return nil }
        return packets
    }
}

// MARK: - Writing

/// An M4A file with one audio track, its chapter track and the book's tags.
nonisolated private final class BookWriter {
    private let writer: AVAssetWriter
    private let audio: AVAssetWriterInput
    private let chapterInput: AVAssetWriterInput?
    private var chapters: [CMSampleBuffer]
    private let hint: CMFormatDescription

    /// `encodeTo` is nil when packets are copied as they are; `hint` is then their format.
    init(output: URL, encodeTo settings: [String: Any]?, hint: CMFormatDescription, chapters: [Chapter], metadata: [AVMetadataItem]) throws {
        self.hint = hint
        writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        var settings = settings
        if let wanted = settings, !writer.canApply(outputSettings: wanted, forMediaType: .audio) {
            // Low sample rates (speech recordings, 22 kHz mono) can't take every bitrate; let the encoder pick.
            settings?[AVEncoderBitRateKey] = nil
        }
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: settings == nil ? hint : nil)
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(audio) else { throw ConversionError.failed("Couldn't write this audio as an audiobook.") }
        writer.add(audio)

        if !chapters.isEmpty, let format = Self.textFormat() {
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            input.marksOutputTrackAsEnabled = false
            // Players look chapters up by language; an undetermined one only shows when asked for by locale.
            input.languageCode = Locale.current.language.languageCode?.identifier(.alpha3) ?? "eng"
            if writer.canAdd(input) {
                writer.add(input)
                audio.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
                chapterInput = input
                self.chapters = chapters.compactMap { Self.sample($0, format: format) }
            } else {
                chapterInput = nil
                self.chapters = []
            }
        } else {
            chapterInput = nil
            self.chapters = []
        }
        writer.metadata = metadata
        guard writer.startWriting() else { throw writer.error ?? ConversionError.failed("Couldn't write the audiobook.") }
        writer.startSession(atSourceTime: .zero)
        feedChapters()
    }

    /// Copies the tracks' packets one after another, each part starting where the last one's packets ended.
    func copy(_ parts: [(AVAsset, AVAssetTrack)], total: CMTime, progress: @escaping @Sendable (Double) -> Void) async throws {
        var clock = CMTime.zero
        for (asset, track) in parts {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? ConversionError.failed("Couldn't read the audio.") }
            while let buffer = output.copyNextSampleBuffer() {
                let count = CMSampleBufferGetNumSamples(buffer)
                guard count > 0, let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var packets: UnsafePointer<AudioStreamPacketDescription>?
                CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer, packetDescriptionsPointerOut: &packets, sizeOut: nil)
                // Rewrapped in the first part's format, since the writer takes one format per track; parts only
                // get here when theirs is the same apart from bitrate details.
                var moved: CMSampleBuffer?
                let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: data, formatDescription: hint, sampleCount: count,
                    presentationTimeStamp: clock, packetDescriptions: packets, sampleBufferOut: &moved)
                guard status == noErr, let moved else { throw ConversionError.failed("Couldn't copy the audio.") }
                clock = clock + CMSampleBufferGetDuration(moved)
                try await append(moved)
                if total.seconds > 0 { progress(min(1, clock.seconds / total.seconds)) }
            }
            if reader.status == .failed { throw reader.error ?? ConversionError.failed("Couldn't read the audio.") }
        }
        try await finish(at: clock)
    }

    /// Decodes the track and lets the writer encode it as AAC (converting the sample rate and channels on the way).
    func encode(_ asset: AVAsset, _ track: AVAssetTrack, total: CMTime, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let settings = audio.outputSettings else { return }
        let reader = try AVAssetReader(asset: asset)
        var pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        for key in [AVSampleRateKey, AVNumberOfChannelsKey, AVChannelLayoutKey] { pcm[key] = settings[key] }
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcm)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ConversionError.failed("Couldn't read the audio.") }
        var gotAudio = false
        while let buffer = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            gotAudio = true
            try await append(buffer)
            let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if total.seconds > 0 { progress(min(1, time / total.seconds)) }
        }
        if reader.status == .failed { throw reader.error ?? ConversionError.failed("Couldn't read the audio.") }
        guard gotAudio else {
            writer.cancelWriting()
            throw ConversionError.failed("This file has no audio.")
        }
        try await finish(at: nil)
    }

    private func append(_ buffer: CMSampleBuffer) async throws {
        while !audio.isReadyForMoreMediaData {
            feedChapters()
            if writer.status == .failed { throw writer.error ?? ConversionError.failed("Couldn't write the audiobook.") }
            if Task.isCancelled { writer.cancelWriting(); throw ConversionError.cancelled }
            try? await Task.sleep(for: .microseconds(200))
        }
        if Task.isCancelled { writer.cancelWriting(); throw ConversionError.cancelled }
        guard audio.append(buffer) else {
            throw writer.error ?? ConversionError.failed("Couldn't write the audiobook.")
        }
    }

    private func finish(at end: CMTime?) async throws {
        audio.markAsFinished()
        while chapterInput != nil, !chapters.isEmpty {
            feedChapters()
            if writer.status == .failed { break }
            try? await Task.sleep(for: .microseconds(200))
        }
        if let end { writer.endSession(atSourceTime: end) }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.failed("Couldn't write the audiobook.") }
    }

    /// The writer interleaves tracks, so chapters go in whenever it's ready for them rather than all at the end,
    /// which would leave it waiting for them before taking more audio.
    private func feedChapters() {
        guard let input = chapterInput, !chapters.isEmpty else { return }
        while !chapters.isEmpty, input.isReadyForMoreMediaData {
            if !input.append(chapters.removeFirst()) { chapters.removeAll() }
        }
        if chapters.isEmpty { input.markAsFinished() }
    }

    /// A 3GPP timed text description ("tx3g"), the kind of text track QuickTime chapters are.
    private static func textFormat() -> CMFormatDescription? {
        var bytes: [UInt8] = []
        func u32(_ value: UInt32) { bytes += withUnsafeBytes(of: value.bigEndian, Array.init) }
        func u16(_ value: UInt16) { bytes += withUnsafeBytes(of: value.bigEndian, Array.init) }
        u32(0); bytes += Array("tx3g".utf8); bytes += [0, 0, 0, 0, 0, 0]; u16(1)   // Size (filled in below), type, data reference
        u32(0)                                                // Display flags
        bytes += [0, 0, 0, 0, 0, 0]                           // Justification, background colour
        u16(0); u16(0); u16(0); u16(0)                        // Text box
        u16(0); u16(0); u16(1); bytes += [0, 12, 0, 0, 0, 255]   // Default style: font 1, 12 pt, black
        u32(13); bytes += Array("ftab".utf8); u16(1); u16(1); bytes += [0]   // Font table: font 1, no name
        let size = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: size) { bytes.replaceSubrange(0..<4, with: $0) }
        var format: CMFormatDescription?
        let status = CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
            allocator: nil, bigEndianTextDescriptionData: bytes, size: bytes.count, flavor: nil,
            mediaType: kCMMediaType_Text, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    /// One chapter: its title as a length-prefixed UTF-8 string, marked as UTF-8.
    private static func sample(_ chapter: Chapter, format: CMFormatDescription) -> CMSampleBuffer? {
        var title = Array(chapter.title.utf8.prefix(1024))
        while !title.isEmpty, String(bytes: title, encoding: .utf8) == nil { title.removeLast() }   // Don't cut a character in half
        var bytes: [UInt8] = withUnsafeBytes(of: UInt16(title.count).bigEndian, Array.init) + title
        bytes += [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0]
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block, CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
        else { return nil }
        var timing = CMSampleTimingInfo(duration: chapter.duration, presentationTimeStamp: chapter.start, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }
}
