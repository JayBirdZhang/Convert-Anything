import AVFoundation
import ImageIO

// What a converted file keeps from its original: its dates (every conversion), a photo's EXIF, an audio file's
// tags and cover art, and a video's creation date. All of it is written while the output is being made, or added
// to it right after, without decoding or encoding anything a second time. None of it is worth failing a
// conversion over, so anything that goes wrong here just leaves the file without it.

// MARK: - Dates

/// The original's creation and modification dates, read before converting and put on the result once it's in place.
nonisolated struct OriginalDates: Sendable {
    let created: Date?
    let modified: Date?

    init(of url: URL) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        created = values?.creationDate
        modified = values?.contentModificationDate
    }

    /// A folder of pages gets the dates too, and so does each page in it.
    func apply(to url: URL) {
        set(url)
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        files.forEach(set)
    }

    private func set(_ url: URL) {
        // Modification first: a modification date earlier than the creation date drags the creation date back
        // with it, so the creation date goes last and lands where it should.
        if let modified { try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        if let created { try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path) }
    }
}

// MARK: - Photos

nonisolated enum PhotoMetadata {
    /// The source's properties, ready for the converted picture: its rotation is already applied to the pixels,
    /// and EXIF's pixel size follows the new size.
    static func carried(_ source: [CFString: Any], image: CGImage) -> [CFString: Any] {
        var metadata = source
        metadata[kCGImagePropertyOrientation] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any], exif[kCGImagePropertyExifPixelXDimension] != nil {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        metadata[kCGImagePropertyPixelWidth] = nil
        metadata[kCGImagePropertyPixelHeight] = nil
        return metadata
    }
}

// MARK: - Video

nonisolated enum VideoMetadata {
    /// Metadata for the export session, or nil when it carries everything over by itself. Phone videos keep their
    /// date and place in metadata items, which the export copies. Cameras and other apps often keep the date only
    /// in the movie header, which the export rewrites with today's date, so it's added back as an item.
    static func exportItems(for asset: AVAsset) async -> [AVMetadataItem]? {
        guard let items = try? await asset.load(.metadata),
              !items.contains(where: { $0.commonKey == .commonKeyCreationDate }),
              let date = try? await asset.load(.creationDate)?.load(.dateValue) else { return nil }
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataCreationDate
        item.value = ISO8601DateFormatter().string(from: date) as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return items + [item]
    }

    /// The export stamps the movie header with today's date. Writes the original's back, in place (16 bytes).
    /// MOV and MP4 also have it in a metadata item, but for M4V the header is the only creation date macOS reads:
    /// the export turns the item into iTunes' release date there.
    static func stampHeader(of url: URL, with date: Date) {
        guard let file = try? FileHandle(forUpdating: url) else { return }
        defer { try? file.close() }
        func box(at offset: UInt64) -> (type: String, size: UInt64, header: UInt64)? {
            try? file.seek(toOffset: offset)
            guard let head = try? file.read(upToCount: 16), head.count >= 8 else { return nil }
            let size32 = head.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: head[4..<8], as: UTF8.self)
            if size32 == 1, head.count == 16 { return (type, head[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, 16) }
            return size32 >= 8 ? (type, size32, 8) : nil
        }
        func find(_ type: String, from start: UInt64, to end: UInt64) -> (offset: UInt64, header: UInt64)? {
            var offset = start
            while offset < end, let b = box(at: offset) {
                if b.type == type { return (offset, b.header) }
                offset += b.size
            }
            return nil
        }
        guard let fileEnd = try? file.seekToEnd(),
              let moov = find("moov", from: 0, to: fileEnd), let moovBox = box(at: moov.offset),
              let mvhd = find("mvhd", from: moov.offset + moov.header, to: moov.offset + moovBox.size) else { return }
        let body = mvhd.offset + mvhd.header
        try? file.seek(toOffset: body)
        guard let version = try? file.read(upToCount: 1)?.first else { return }
        let seconds = UInt64(max(0, date.timeIntervalSince1970 + 2_082_844_800))     // the header counts from 1904
        var stamp = Data()
        if version == 1 {
            stamp.appendBigEndian64(seconds); stamp.appendBigEndian64(seconds)
        } else {
            guard seconds <= UInt64(UInt32.max) else { return }
            stamp.appendBigEndian(UInt32(seconds)); stamp.appendBigEndian(UInt32(seconds))
        }
        try? file.seek(toOffset: body + 4)
        try? file.write(contentsOf: stamp)
    }
}

// MARK: - Audio tags

/// The tags worth keeping from an audio file, read by AVFoundation from whatever the source uses (ID3 in MP3 and
/// AIFF, iTunes atoms in M4A, Vorbis comments in FLAC, INFO in WAV), and written in the target's own way.
nonisolated struct AudioTags: Sendable {
    var title, artist, album, albumArtist, composer, genre, date, comment: String?
    var track: String?      // "3" or "3/12"
    var disc: String?
    var artwork: Data?

    /// Formats that can hold tags that macOS reads back. Raw AAC (ADTS) has nowhere to put them.
    static func canWrite(_ format: Format) -> Bool { [.mp3, .m4a, .flac, .wav, .aiff].contains(format) }

    var isEmpty: Bool {
        [title, artist, album, albumArtist, composer, genre, date, comment, track, disc].allSatisfy { $0 == nil } && artwork == nil
    }

    private var artworkIsPNG: Bool { artwork?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true }

    // MARK: Reading

    /// Only reads the file's header, so it's quick even for long recordings. Nil when there's nothing to keep.
    static func load(_ url: URL, format: Format) async -> AudioTags? {
        guard let items = try? await AVURLAsset(url: url).load(.metadata) else { return nil }
        var tags = AudioTags()
        var trackTotal: String?, discTotal: String?
        for item in items {
            let id = item.identifier
            if id == .iTunesMetadataTrackNumber || id == .iTunesMetadataDiscNumber {
                // "trkn" and "disk" are binary: two bytes of padding, the number, then the total.
                guard let data = try? await item.load(.dataValue), data.count >= 6 else { continue }
                let bytes = [UInt8](data)
                let number = Int(bytes[2]) << 8 | Int(bytes[3]), total = Int(bytes[4]) << 8 | Int(bytes[5])
                guard number > 0 else { continue }
                let value = total > 0 ? "\(number)/\(total)" : "\(number)"
                if id == .iTunesMetadataTrackNumber { tags.track = value } else { tags.disc = value }
                continue
            }
            if item.commonKey == .commonKeyArtwork || id == .iTunesMetadataCoverArt {
                if tags.artwork == nil { tags.artwork = try? await item.load(.dataValue) }
                continue
            }
            guard let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            // Vorbis comments and WAV's INFO chunk only have plain keys, no identifiers of their own.
            let key = (item.key as? String)?.uppercased() ?? ""
            let space = item.keySpace?.rawValue
            let vorbis = space == "vorb" ? key : "", info = space == "caaf" ? key : ""
            func fill(_ field: WritableKeyPath<AudioTags, String?>) { if tags[keyPath: field] == nil { tags[keyPath: field] = value } }
            switch true {
            case item.commonKey == .commonKeyTitle: fill(\.title)
            case item.commonKey == .commonKeyArtist: fill(\.artist)
            case item.commonKey == .commonKeyAlbumName: fill(\.album)
            case id == .id3MetadataBand || id == .iTunesMetadataAlbumArtist || vorbis == "ALBUMARTIST": fill(\.albumArtist)
            case id == .id3MetadataComposer || id == .iTunesMetadataComposer || vorbis == "COMPOSER" || info == "INFO-COMPOSER": fill(\.composer)
            case id == .id3MetadataContentType || id == .iTunesMetadataUserGenre || vorbis == "GENRE" || info == "INFO-GENRE": fill(\.genre)
            case id == .id3MetadataYear || id == .id3MetadataRecordingTime || id == .iTunesMetadataReleaseDate
                || vorbis == "DATE" || info == "INFO-YEAR": fill(\.date)
            case id == .id3MetadataComments || id == .iTunesMetadataUserComment || vorbis == "COMMENT" || info == "INFO-COMMENTS": fill(\.comment)
            case id == .id3MetadataTrackNumber || vorbis == "TRACKNUMBER" || info == "INFO-TRACK NUMBER": fill(\.track)
            case id == .id3MetadataPartOfASet || vorbis == "DISCNUMBER": fill(\.disc)
            case vorbis == "TRACKTOTAL" || vorbis == "TOTALTRACKS": trackTotal = value
            case vorbis == "DISCTOTAL" || vorbis == "TOTALDISCS": discTotal = value
            default: break
            }
        }
        if let total = trackTotal, let track = tags.track, !track.contains("/") { tags.track = "\(track)/\(total)" }
        if let total = discTotal, let disc = tags.disc, !disc.contains("/") { tags.disc = "\(disc)/\(total)" }
        // AVFoundation reads FLAC's comments but not its picture, which is in a block near the start.
        if format == .flac, tags.artwork == nil { tags.artwork = FLAC.picture(in: url) }
        return tags.isEmpty ? nil : tags
    }

    // MARK: Writing

    /// Adds the tags to a finished file. MP3 doesn't come here: its tag is written first, by the encoder (see `id3v2`).
    func write(to url: URL, as format: Format) async {
        switch format {
        case .wav: RIFF.append([("LIST", infoList()), ("id3 ", id3v2())], to: url, bigEndian: false)
        case .aiff: RIFF.append([("ID3 ", id3v2())], to: url, bigEndian: true)
        case .flac: FLAC.replaceMetadata(of: url, with: [(4, vorbisComment()), (6, flacPicture())].filter { !$0.1.isEmpty })
        case .m4a: await MP4.retag(url, with: iTunesItems())
        default: break
        }
    }

    /// An ID3v2.3 tag: what an MP3 file starts with, and what WAV and AIFF files carry in an "id3 " chunk.
    func id3v2() -> Data {
        var frames = Data()
        func frame(_ id: String, _ body: Data) {
            frames.append(Data(id.utf8))
            frames.appendBigEndian(UInt32(body.count))     // Plain 32 bits in v2.3; only the tag's own size is synchsafe
            frames.append(contentsOf: [0, 0])
            frames.append(body)
        }
        func text(_ id: String, _ value: String?) {
            guard let value else { return }
            // Latin-1 when the text fits, so plain tags stay small; otherwise UTF-16 with a byte-order mark.
            frame(id, value.data(using: .isoLatin1).map { Data([0]) + $0 } ?? Data([1]) + Self.utf16(value))
        }
        text("TIT2", title); text("TPE1", artist); text("TALB", album); text("TPE2", albumArtist)
        text("TCOM", composer); text("TCON", genre); text("TRCK", track); text("TPOS", disc)
        text("TYER", date.map { String($0.prefix(4)) })      // v2.3 years are four digits
        if let comment {
            frame("COMM", Data([1]) + Data("eng".utf8) + Self.utf16("") + Data([0, 0]) + Self.utf16(comment))
        }
        if let artwork {
            // Latin-1 MIME type, "front cover", empty description, then the picture.
            frame("APIC", Data([0]) + Data((artworkIsPNG ? "image/png" : "image/jpeg").utf8) + Data([0, 3, 0]) + artwork)
        }
        guard !frames.isEmpty else { return Data() }
        let size = frames.count
        return Data("ID3".utf8) + Data([3, 0, 0, UInt8(size >> 21 & 0x7F), UInt8(size >> 14 & 0x7F),
                                        UInt8(size >> 7 & 0x7F), UInt8(size & 0x7F)]) + frames
    }

    /// Byte-order mark, then UTF-16 little-endian.
    private static func utf16(_ value: String) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in value.utf16 { data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8)) }
        return data
    }

    /// WAV's own LIST/INFO chunk, which is what macOS reads in a WAV file (it ignores ID3 there; other apps don't).
    private func infoList() -> Data {
        var list = Data("INFO".utf8)
        for (id, value) in [("INAM", title), ("IART", artist), ("IPRD", album), ("IGNR", genre),
                            ("ICRD", date), ("ITRK", track), ("ICMT", comment)] {
            guard let value else { continue }
            let text = Data(value.utf8) + Data([0])
            list.append(Data(id.utf8))
            list.appendLittleEndian(UInt32(text.count))
            list.append(text)
            if text.count % 2 == 1 { list.append(0) }
        }
        return list.count > 4 ? list : Data()
    }

    private func vorbisComment() -> Data {
        var fields: [String] = []
        func add(_ key: String, _ value: String?) { if let value { fields.append("\(key)=\(value)") } }
        func addNumber(_ key: String, _ totalKey: String, _ value: String?) {
            guard let parts = value?.split(separator: "/", maxSplits: 1) else { return }
            add(key, parts.first.map(String.init))
            if parts.count == 2 { add(totalKey, String(parts[1])) }
        }
        add("TITLE", title); add("ARTIST", artist); add("ALBUM", album); add("ALBUMARTIST", albumArtist)
        add("COMPOSER", composer); add("GENRE", genre); add("DATE", date); add("COMMENT", comment)
        addNumber("TRACKNUMBER", "TRACKTOTAL", track); addNumber("DISCNUMBER", "DISCTOTAL", disc)
        guard !fields.isEmpty else { return Data() }
        let vendor = Data("Convert Anything".utf8)
        var data = Data()
        data.appendLittleEndian(UInt32(vendor.count)); data.append(vendor)
        data.appendLittleEndian(UInt32(fields.count))
        for field in fields {
            let bytes = Data(field.utf8)
            data.appendLittleEndian(UInt32(bytes.count)); data.append(bytes)
        }
        return data
    }

    private func flacPicture() -> Data {
        guard let artwork else { return Data() }
        let mime = Data((artworkIsPNG ? "image/png" : "image/jpeg").utf8)
        var data = Data()
        data.appendBigEndian(3)                              // Front cover
        data.appendBigEndian(UInt32(mime.count)); data.append(mime)
        for _ in 0..<5 { data.appendBigEndian(0) }           // No description; size and colors unknown (allowed)
        data.appendBigEndian(UInt32(artwork.count)); data.append(artwork)
        return data
    }

    private func iTunesItems() -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, _ type: CFString) -> AVMetadataItem? {
            guard let value else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = value
            item.dataType = type as String
            return item
        }
        func text(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            item(id, value as NSString?, kCMMetadataBaseDataType_UTF8)
        }
        /// "3/12" as iTunes' binary pair: padding, number, total (and two more bytes of padding for tracks).
        func number(_ id: AVMetadataIdentifier, _ value: String?, trailing: Int) -> AVMetadataItem? {
            let parts = value?.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? []
            guard let first = parts.first, (1...0xFFFF).contains(first) else { return nil }
            let total = parts.count > 1 ? min(parts[1], 0xFFFF) : 0
            let bytes = [0, 0, UInt8(first >> 8), UInt8(first & 0xFF), UInt8(total >> 8), UInt8(total & 0xFF)] + [UInt8](repeating: 0, count: trailing)
            return item(id, Data(bytes) as NSData, kCMMetadataBaseDataType_RawData)
        }
        return [
            text(.iTunesMetadataSongName, title), text(.iTunesMetadataArtist, artist), text(.iTunesMetadataAlbum, album),
            text(.iTunesMetadataAlbumArtist, albumArtist), text(.iTunesMetadataComposer, composer),
            text(.iTunesMetadataUserGenre, genre), text(.iTunesMetadataReleaseDate, date), text(.iTunesMetadataUserComment, comment),
            number(.iTunesMetadataTrackNumber, track, trailing: 2), number(.iTunesMetadataDiscNumber, disc, trailing: 0),
            item(.iTunesMetadataCoverArt, artwork as NSData?, artworkIsPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG),
        ].compactMap { $0 }
    }
}

// MARK: - Containers

/// WAV (RIFF) and AIFF (FORM) files are a list of chunks, so tags are new chunks at the end: nothing else moves.
nonisolated private enum RIFF {
    static func append(_ chunks: [(String, Data)], to url: URL, bigEndian: Bool) {
        var tail = Data()
        for (id, body) in chunks where !body.isEmpty {
            tail.append(Data(id.utf8))
            if bigEndian { tail.appendBigEndian(UInt32(body.count)) } else { tail.appendLittleEndian(UInt32(body.count)) }
            tail.append(body)
            if body.count % 2 == 1 { tail.append(0) }
        }
        guard !tail.isEmpty, let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end % 2 == 0, end + UInt64(tail.count) < UInt64(UInt32.max) else { return }
        let size = UInt32(end + UInt64(tail.count) - 8)    // The file's own size field doesn't count its first 8 bytes
        var field = Data()
        if bigEndian { field.appendBigEndian(size) } else { field.appendLittleEndian(size) }
        try? handle.write(contentsOf: tail)
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: field)
    }
}

/// A FLAC file is "fLaC", a few metadata blocks, then the audio. Core Audio leaves no room among the blocks, so
/// adding tags means writing the file again with new blocks in front (a plain copy of the audio, no re-encoding).
nonisolated private enum FLAC {
    /// Each block: last-block flag and type in one byte, a 24-bit length, then the body.
    private static func blocks(of handle: FileHandle) throws -> (blocks: [(type: UInt8, body: Data)], audioStart: UInt64)? {
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
        var blocks: [(UInt8, Data)] = []
        while true {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { return nil }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            let body = try handle.read(upToCount: length) ?? Data()
            guard body.count == length else { return nil }
            blocks.append((header[0] & 0x7F, body))
            if header[0] & 0x80 != 0 { return (blocks, try handle.offset()) }
        }
    }

    /// The front-cover picture (or the first one), from a PICTURE block.
    static func picture(in url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let pictures = (try? blocks(of: handle))?.blocks.filter({ $0.type == 6 }).map(\.body) else { return nil }
        func data(of body: Data) -> (type: UInt32, data: Data)? {
            let bytes = [UInt8](body)
            func u32(_ at: Int) -> Int? { at + 4 <= bytes.count ? bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } : nil }
            guard let mime = u32(4), let description = u32(8 + mime), let length = u32(28 + mime + description) else { return nil }
            let start = 32 + mime + description
            guard start + length <= bytes.count else { return nil }
            return (UInt32(u32(0) ?? 0), Data(bytes[start..<start + length]))
        }
        let found = pictures.compactMap(data)
        return (found.first { $0.type == 3 } ?? found.first)?.data
    }

    /// Replaces the comment, picture and padding blocks with `new` ones, keeping the stream info and seek table.
    static func replaceMetadata(of url: URL, with new: [(type: UInt8, body: Data)]) {
        guard !new.isEmpty, let reader = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? reader.close() }
        guard let parsed = (try? blocks(of: reader)) ?? nil, new.allSatisfy({ $0.body.count < 1 << 24 }) else { return }
        let kept = parsed.blocks.filter { ![1, 4, 6].contains($0.type) }
        let all = kept + new
        var header = Data("fLaC".utf8)
        for (index, block) in all.enumerated() {
            let length = block.body.count
            header.append(contentsOf: [block.type | (index == all.count - 1 ? 0x80 : 0),
                                       UInt8(length >> 16), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            header.append(block.body)
        }
        let tagged = url.deletingLastPathComponent().appending(path: "tagged-" + url.lastPathComponent)
        do {
            FileManager.default.createFile(atPath: tagged.path, contents: header)
            let writer = try FileHandle(forWritingTo: tagged)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try reader.seek(toOffset: parsed.audioStart)
            while let chunk = try reader.read(upToCount: 8 << 20), !chunk.isEmpty { try writer.write(contentsOf: chunk) }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tagged)
        } catch {
            try? FileManager.default.removeItem(at: tagged)
        }
    }
}

/// Core Audio's M4A writer has no way to add tags, so the finished file is copied once more with them, without
/// re-encoding (AVFoundation's passthrough export).
nonisolated private enum MP4 {
    static func retag(_ url: URL, with metadata: [AVMetadataItem]) async {
        guard !metadata.isEmpty,
              let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetPassthrough) else { return }
        let tagged = url.deletingLastPathComponent().appending(path: "tagged-" + url.lastPathComponent)
        session.metadata = metadata
        do {
            if #available(macOS 15, *) {
                try await session.export(to: tagged, as: .m4a)
            } else {
                session.outputURL = tagged
                session.outputFileType = .m4a
                await session.export()
                guard session.status == .completed else { throw session.error ?? ConversionError.failed("") }
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tagged)
        } catch {
            try? FileManager.default.removeItem(at: tagged)
        }
    }
}

nonisolated extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    mutating func appendBigEndian64(_ value: UInt64) {
        appendBigEndian(UInt32(value >> 32)); appendBigEndian(UInt32(value & 0xFFFF_FFFF))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}
