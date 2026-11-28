import AVFoundation
import Speech
import os

/// Writes down what's said in audio and video, entirely on this Mac: SpeechAnalyzer on macOS 26 and later,
/// the older SFSpeechRecognizer (forced to stay on-device) before that, and also whenever SpeechAnalyzer
/// fails or stops making progress. Nothing is uploaded.
nonisolated enum Transcription {
    /// Read back by bug reports, so every line says what happened without naming the file or quoting it.
    static let log = Logger(subsystem: "io.github.jaybirdzhang.ConvertAnything", category: "transcription")

    @concurrent
    static func convert(_ request: Converter.Request, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let audio = try await openAudio(request, progress: progress)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration > 0 else { throw ConversionError.failed("This file has no sound to transcribe.") }
        // A video's soundtrack was decoded first and already filled the first 5% of the bar.
        let isVideo = audio.url.lastPathComponent == extractedName
        let base = isVideo ? 0.05 : 0
        let progress: @Sendable (Double) -> Void = { progress(base + (1 - base) * $0) }

        log.notice("Transcribing \(Int(duration.rounded()), privacy: .public) s of \(isVideo ? "video soundtrack" : "audio", privacy: .public) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
        let started = ContinuousClock.now
        var tokens = try await transcribe(audio.url, duration: duration, progress: progress)
        log.notice("Transcribed in \(elapsed(since: started), privacy: .public) s")
        tokens.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !tokens.isEmpty else { throw ConversionError.failed("No speech was found in this file.") }

        let text: String
        switch request.to {
        case .srt: text = Transcript.srt(Transcript.cues(from: tokens))
        case .vtt: text = Transcript.vtt(Transcript.cues(from: tokens))
        default: text = Transcript.paragraphs(from: tokens)
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    /// SpeechAnalyzer when it's there, and SFSpeechRecognizer when it isn't or when it fails, in the language
    /// SpeechAnalyzer picked if it got that far.
    private static func transcribe(_ url: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.Token] {
        var language: Locale?
        var modernFailure: Error?
        if #available(macOS 26, *), !Debug.isOn("CONVERT_ANYTHING_LEGACY_SPEECH") {
            if SpeechTranscriber.isAvailable {
                log.notice("Engine: SpeechAnalyzer")
                do {
                    return try await ModernEngine.transcribe(url, duration: duration, language: &language, progress: progress)
                } catch {
                    if Task.isCancelled || isCancellation(error) { throw ConversionError.cancelled }
                    modernFailure = error
                    log.error("SpeechAnalyzer failed: \(describe(error), privacy: .public). Falling back to SFSpeechRecognizer")
                }
            } else {
                log.notice("Engine: SFSpeechRecognizer, because SpeechTranscriber isn't available on this Mac")
            }
        } else {
            log.notice("Engine: SFSpeechRecognizer")
        }
        do {
            return try await LegacyEngine.transcribe(url, duration: duration, language: language, progress: progress)
        } catch let unavailable as LegacyEngine.Unavailable {
            log.error("SFSpeechRecognizer can't run: \(String(describing: unavailable), privacy: .public)")
            throw ConversionError.failed(message(for: unavailable, after: modernFailure))
        } catch is Stalled {
            throw ConversionError.failed("Speech recognition stopped responding. Try again, or restart your Mac if it keeps happening.")
        } catch {
            if Task.isCancelled || isCancellation(error) { throw ConversionError.cancelled }
            log.error("SFSpeechRecognizer failed: \(describe(error), privacy: .public)")
            throw error
        }
    }

    /// What to tell someone when neither engine could run: the fix for the first engine's problem when
    /// there is one (going online for a missing model), otherwise the fix that lets the older one run.
    private static func message(for legacy: LegacyEngine.Unavailable, after modern: Error?) -> String {
        guard let modern else { return legacy.message }
        if case .download(let locale) = modern as? ModernFailure {
            return "The speech model for \(languageName(locale)) isn't on this Mac yet and couldn't be downloaded. Connect to the internet once and try again."
        }
        let lead = modern is Stalled ? "Speech recognition stopped responding" : "Speech recognition failed"
        switch legacy {
        case .notAllowed:
            return "\(lead). To use the older recognizer instead, allow Convert Anything in System Settings › Privacy & Security › Speech Recognition, then try again."
        case .notOnDevice(let locale):
            return "\(lead), and this Mac can't recognize \(languageName(locale)) speech any other way without the internet. Turn on Dictation in System Settings › Keyboard to download it, then try again."
        case .noRecognizer:
            return "\(lead). Try again, or restart your Mac if it keeps happening."
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .cancelled? = error as? ConversionError { return true }
        return false
    }

    /// The error's kind and code for the log; its text can quote a path, so that stays private.
    static func describe(_ error: Error) -> String {
        if let stalled = error as? Stalled { return "\(stalled.step) made no progress for \(stalled.seconds) s" }
        if let failure = error as? ModernFailure { return String(describing: failure) }
        let nsError = error as NSError
        log.debug("Error text: \(nsError.localizedDescription, privacy: .private)")
        return "\(type(of: error)) \(nsError.domain) \(nsError.code)"
    }

    static func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        return String(format: "%.2f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    /// Audio files are read as they are. A video's sound is first decoded into a small 16 kHz mono file
    /// (all speech recognition needs), streaming, so the whole soundtrack is never in memory.
    private static func openAudio(_ request: Converter.Request, progress: @Sendable (Double) -> Void) async throws -> AVAudioFile {
        if request.from.kind == .audio, let file = try? AVAudioFile(forReading: request.input) { return file }

        let asset = AVURLAsset(url: request.input)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.failed("This file has no sound to transcribe.")
        }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        ]
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? ConversionError.failed("Couldn't read this file's sound.") }

        let url = request.workDir.appending(path: extractedName)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = file.processingFormat
        var reported = 0.0
        while let sample = trackOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                into: buffer.mutableAudioBufferList) == noErr else { continue }
            try file.write(from: buffer)
            // Decoding is quick next to recognizing, so it gets the first few percent of the bar.
            let done = duration > 0 ? min(1, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration) : 0
            if done - reported >= 0.05 { reported = done; progress(0.05 * done) }
        }
        if reader.status == .failed { throw reader.error ?? ConversionError.failed("Couldn't read this file's sound.") }
        return try AVAudioFile(forReading: url)
    }

    private static let extractedName = "speech.caf"

    /// The system's language when speech recognition knows it, otherwise English.
    static func languageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Recognized text inside a script that doesn't put spaces between words (Chinese, Japanese, Thai).
    static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(scalar) || (0xF900...0xFAFF).contains(scalar) || (0xFF00...0xFFEF).contains(scalar)
            || (0x0E00...0x0E7F).contains(scalar)
    }
}

// MARK: - Never waiting forever

/// How long each step may go without progress before it counts as stuck. Long files and slow downloads
/// are fine; these only measure time in which nothing at all moved.
nonisolated enum StallLimit {
    /// Locale lookups and format queries, which take milliseconds.
    static var lookup: Duration { Debug.stallSeconds ?? .seconds(30) }
    /// The model download reports progress about every 2 seconds, even on a slow connection.
    static var download: Duration { Debug.stallSeconds ?? .seconds(90) }
    /// The language sample takes about a second.
    static var detection: Duration { Debug.stallSeconds ?? .seconds(30) }
    /// SpeechAnalyzer asks for more audio, or hands back text, many times a second; the first time a model
    /// is loaded after a download can take a while longer.
    static var analysis: Duration { Debug.stallSeconds ?? .seconds(60) }
    /// The older recognizer reports once per piece of up to 55 seconds, at least twice as fast as it plays.
    static var legacyPiece: Duration { Debug.stallSeconds ?? .seconds(120) }
    /// The system's permission prompt, which waits for the person to answer it.
    static var permission: Duration { Debug.stallSeconds.map { $0 * 2 } ?? .seconds(180) }
    /// How long a cancelled step gets to wind down before it's left behind.
    static let windDown: Duration = .seconds(5)
}

/// A step that went `seconds` without progress and was stopped.
nonisolated struct Stalled: Error {
    let step: String
    let seconds: Int
}

/// Lets a watched step report that it's still moving.
nonisolated final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    // The suspending clock stands still while the Mac sleeps, so a nap isn't taken for a stall.
    private var last = SuspendingClock.now

    func beat() { lock.withLock { last = .now } }
    var idle: Duration { SuspendingClock.now - lock.withLock { last } }
}

extension Transcription {
    /// Runs `operation` and returns what it returns, unless it goes `limit` without calling `beat()`. Then it's
    /// cancelled, given a few seconds to wind down, and left behind if it still hasn't (a system call that
    /// ignores cancellation), so the conversion ends with `Stalled` instead of waiting forever.
    nonisolated static func watch<T: Sendable>(_ step: String, limit: Duration,
                                               _ operation: @escaping @Sendable (Heartbeat) async throws -> T) async throws -> T {
        let heartbeat = Heartbeat()
        let outcome = Outcome<T>()
        let work = Task {
            let result: Result<T, Error>
            do { result = .success(try await operation(heartbeat)) } catch { result = .failure(error) }
            outcome.workEnded(with: result)
        }
        let watchdog = Task {
            while !outcome.isDelivered && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard heartbeat.idle >= limit, outcome.beginStopping() else { continue }
                let seconds = Int(limit.components.seconds)
                log.error("\(step, privacy: .public) made no progress for \(seconds, privacy: .public) s; stopping it")
                work.cancel()
                let deadline = ContinuousClock.now + StallLimit.windDown
                while !outcome.hasEnded && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                if !outcome.hasEnded { log.error("\(step, privacy: .public) didn't stop when cancelled; leaving it behind") }
                outcome.deliver(.failure(Stalled(step: step, seconds: seconds)))
            }
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await outcome.value()
        } onCancel: {
            work.cancel()
            outcome.deliver(.failure(CancellationError()))
        }
    }

    /// Hands a watched step's result, or its stall, to the waiting task exactly once.
    private nonisolated final class Outcome<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        private var stopping = false
        private var ended = false

        var isDelivered: Bool { lock.withLock { result != nil } }
        var hasEnded: Bool { lock.withLock { ended } }

        /// True the first time, when the step is still running and its own result should no longer count.
        func beginStopping() -> Bool {
            lock.withLock {
                guard result == nil, !stopping else { return false }
                stopping = true
                return true
            }
        }

        func workEnded(with result: Result<T, Error>) {
            let stopping = lock.withLock { ended = true; return self.stopping }
            if !stopping { deliver(result) }
        }

        func deliver(_ newResult: Result<T, Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<T, Error>? in
                guard result == nil else { return nil }
                result = newResult
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: newResult)
        }

        func value() async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                let ready = lock.withLock { () -> Result<T, Error>? in
                    if result == nil { self.continuation = continuation }
                    return result
                }
                if let ready { continuation.resume(with: ready) }
            }
        }
    }
}

/// Switches for trying each failure on a Mac where nothing fails. Debug builds only.
nonisolated enum Debug {
    static func isOn(_ name: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment[name] != nil
        #else
        false
        #endif
    }

    /// CONVERT_ANYTHING_STALL_SECONDS shortens every stall limit, so the stall switches can be tried quickly.
    static var stallSeconds: Duration? {
        #if DEBUG
        ProcessInfo.processInfo.environment["CONVERT_ANYTHING_STALL_SECONDS"].flatMap(Int.init).map { .seconds($0) }
        #else
        nil
        #endif
    }

    /// What a stuck system call looks like: it never returns, and cancelling it does nothing.
    static func hang() async {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }
}

/// Why SpeechAnalyzer couldn't be used, for the log and for choosing what to tell the person.
nonisolated enum ModernFailure: Error, CustomStringConvertible {
    case unavailable(String)
    case download(Locale)

    var description: String {
        switch self {
        case .unavailable(let reason): "unavailable (\(reason))"
        case .download(let locale): "the \(locale.identifier) model couldn't be downloaded"
        }
    }
}

// MARK: - Languages

/// Apple's recognizers can't tell which language is spoken, so it comes from the languages set on this Mac.
nonisolated enum SpeechLanguages {
    /// The recognizer locale for a preferred language: the same language and script, in the region the
    /// language names, else this Mac's region, else the language's usual one. Always the same answer for
    /// the same list (`supportedLocale(equivalentTo:)` picks a different Spanish each time for es-419).
    static func match(_ identifier: String, in locales: [Locale]) -> Locale? {
        let wanted = Locale.Language(identifier: Locale.Language(identifier: identifier).maximalIdentifier)
        guard let code = wanted.languageCode else { return nil }
        let same = locales.filter {
            let language = Locale.Language(identifier: $0.language.maximalIdentifier)
            return language.languageCode == code && language.script == wanted.script
        }
        guard !same.isEmpty else { return nil }
        let usual = Locale.Language(identifier: Locale.Language(identifier: code.identifier).maximalIdentifier).region
        for region in [Locale(identifier: identifier).region, Locale.current.region, wanted.region, usual].compactMap({ $0 }) {
            if let found = same.first(where: { $0.region == region }) { return found }
        }
        return same.min { $0.identifier < $1.identifier }
    }

    static var preferred: [String] { Locale.preferredLanguages.isEmpty ? ["en-US"] : Locale.preferredLanguages }
}

/// Reads a file as the analyzer wants it, a second at a time, so the analyzer pulls audio only as fast as it
/// works through it, and each pull shows it's still moving.
nonisolated final class AnalyzerAudio: @unchecked Sendable {
    let format: AVAudioFormat
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private var inputEnded = false
    private(set) var ended = false
    /// Frames handed out so far, in `format`.
    private(set) var position: AVAudioFramePosition = 0

    /// A fresh file for each pass, since a file remembers where it was read to.
    init(_ url: URL, as format: AVAudioFormat) throws {
        file = try AVAudioFile(forReading: url)
        self.format = format
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768) else {
            throw ConversionError.failed("Couldn't read this file's sound.")
        }
        self.converter = converter
        self.input = input
    }

    var seconds: Double { Double(position) / format.sampleRate }

    /// The next second of audio, or nil at the end.
    func next() throws -> AVAudioPCMBuffer? {
        guard !ended else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return nil }
        var readError: Error?
        let status = converter.convert(to: output, error: nil) { [self] _, inputStatus in
            if !inputEnded {
                do { try file.read(into: input) } catch { readError = error }
                if input.frameLength == 0 || readError != nil { inputEnded = true }
            }
            if inputEnded {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        if let readError, file.framePosition < file.length { throw readError }
        if status == .error { throw ConversionError.failed("Couldn't read this file's sound.") }
        if status == .endOfStream || output.frameLength == 0 { ended = true }
        guard output.frameLength > 0 else { return nil }
        position += AVAudioFramePosition(output.frameLength)
        return output
    }

    /// Whether any twentieth of a second is louder than about -40 dB, the same line the older engine uses
    /// for a pause.
    static func hasSound(_ buffer: AVAudioPCMBuffer) -> Bool {
        let count = Int(buffer.frameLength), window = max(1, Int(buffer.format.sampleRate / 20))
        func loud(_ value: (Int) -> Float) -> Bool {
            var position = 0
            while position < count {
                let end = min(count, position + window)
                var energy: Float = 0
                for index in position..<end { let sample = value(index); energy += sample * sample }
                if energy / Float(end - position) >= 1e-4 { return true }
                position = end
            }
            return false
        }
        if let data = buffer.int16ChannelData { return loud { Float(data[0][$0]) / 32_768 } }
        if let data = buffer.floatChannelData { return loud { data[0][$0] } }
        return true
    }
}

// MARK: - macOS 26 and later

/// SpeechAnalyzer works through the file as fast as the Neural Engine allows, with no length limit.
@available(macOS 26, *)
nonisolated private enum ModernEngine {
    /// Seconds of speech heard in each candidate language to choose between them.
    static let sampleSeconds = 15

    /// `language` is set as soon as it's known, so a fallback to the older engine can keep it.
    static func transcribe(_ url: URL, duration: Double, language: inout Locale?,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.Token] {
        if Debug.isOn("CONVERT_ANYTHING_NO_MODERN_SPEECH") { throw ModernFailure.unavailable("switched off for testing") }
        let log = Transcription.log
        let (primary, candidates) = try await Transcription.watch("Language lookup", limit: StallLimit.lookup) { _ in
            await languages()
        }
        language = primary
        log.notice("Preferred languages \(SpeechLanguages.preferred, privacy: .public); main language \(primary.identifier, privacy: .public); candidates \(candidates.map(\.identifier), privacy: .public)")
        // Without the main language's model, the older engine in that language is the better bet than
        // another language's model.
        try await install(primary, simulatingStall: Debug.isOn("CONVERT_ANYTHING_STALL_DOWNLOAD"), progress: progress)

        var chosen = candidates[0]
        if candidates.count > 1 {
            do {
                let (best, sample) = try await Transcription.watch("Language detection", limit: StallLimit.detection) { heartbeat in
                    try await detect(url, among: candidates, heartbeat: heartbeat)
                }
                chosen = best
                language = best
                if let sample {
                    log.notice("The sample was the whole file; using its transcript")
                    progress(1)
                    return sample
                }
            } catch {
                if Task.isCancelled || Transcription.isCancellation(error) { throw error }
                log.error("Language detection failed: \(Transcription.describe(error), privacy: .public). Using \(chosen.identifier, privacy: .public)")
            }
        }
        if chosen != primary { try await install(chosen, progress: progress) }
        return try await analyze(url, in: chosen, duration: duration, progress: progress)
    }

    /// The first preferred language SpeechTranscriber knows (English if none), then every other preferred
    /// language whose model is already on this Mac. Models are never downloaded just to compare.
    private static func languages() async -> (primary: Locale, candidates: [Locale]) {
        let installed = await SpeechTranscriber.installedLocales
        var supported: [Locale]?
        var primary: Locale?
        var others: [Locale] = []
        for identifier in SpeechLanguages.preferred {
            if let locale = SpeechLanguages.match(identifier, in: installed) {
                if primary == nil { primary = locale } else if locale != primary && !others.contains(locale) { others.append(locale) }
            } else if primary == nil {
                if supported == nil { supported = await SpeechTranscriber.supportedLocales }
                primary = SpeechLanguages.match(identifier, in: supported ?? [])
            }
        }
        if primary == nil {
            if supported == nil { supported = await SpeechTranscriber.supportedLocales }
            primary = SpeechLanguages.match("en-US", in: supported ?? []) ?? Locale(identifier: "en_US")
        }
        let main = primary ?? Locale(identifier: "en_US")
        return (main, [main] + others.filter { $0 != main })
    }

    private static func transcriber(_ locale: Locale, confidence: Bool = false) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: confidence ? [.audioTimeRange, .transcriptionConfidence] : [.audioTimeRange])
    }

    /// Each language's model is a separate system download, made the first time it's needed.
    private static func install(_ locale: Locale, simulatingStall simulateStall: Bool = false,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        let log = Transcription.log
        let modules = [transcriber(locale)]
        let started = ContinuousClock.now
        do {
            let downloaded = try await Transcription.watch("Model download", limit: StallLimit.download) { heartbeat -> Bool in
                if simulateStall {
                    log.notice("Model for \(locale.identifier, privacy: .public): downloading (simulated stall)")
                    progress(0.16)
                    await Debug.hang()
                }
                guard let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                    return false
                }
                log.notice("Model for \(locale.identifier, privacy: .public): downloading")
                heartbeat.beat()
                let watcher = Task {
                    var last = -1.0, logged = -1
                    while !Task.isCancelled {
                        let fraction = installation.progress.fractionCompleted
                        if fraction != last {
                            last = fraction
                            heartbeat.beat()
                            progress(fraction)
                            if Int(fraction * 10) > logged {
                                logged = Int(fraction * 10)
                                log.notice("Model download \(logged * 10, privacy: .public)%")
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { watcher.cancel() }
                try await installation.downloadAndInstall()
                return true
            }
            if downloaded {
                log.notice("Model for \(locale.identifier, privacy: .public): downloaded in \(Transcription.elapsed(since: started), privacy: .public) s")
            } else {
                log.notice("Model for \(locale.identifier, privacy: .public): already installed")
            }
        } catch {
            if Task.isCancelled || Transcription.isCancellation(error) { throw ConversionError.cancelled }
            log.error("Model for \(locale.identifier, privacy: .public): \(Transcription.describe(error), privacy: .public)")
            throw ModernFailure.download(locale)
        }
    }

    /// Transcribes about 15 seconds of speech, from the first sound on, in every candidate language at once
    /// (one analyzer, one model per language), and keeps the language the recognizer was surest of. When the
    /// sample turns out to be the whole file, its transcript is the result too.
    private static func detect(_ url: URL, among candidates: [Locale], heartbeat: Heartbeat) async throws -> (Locale, [Transcript.Token]?) {
        let log = Transcription.log
        let started = ContinuousClock.now
        let transcribers = candidates.map { transcriber($0, confidence: true) }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: transcribers) else {
            throw ModernFailure.unavailable("no audio format for the sample")
        }
        let audio = try AnalyzerAudio(url, as: format)
        // Skip the silence before the first sound, then take the sample, and a little more rather than
        // leaving a sliver of the file unheard.
        var sample: [AnalyzerInput] = []
        var lengths: [Int] = []
        let wanted = Int(format.sampleRate) * sampleSeconds, enough = Int(format.sampleRate) * (sampleSeconds + 5)
        while let buffer = try audio.next() {
            heartbeat.beat()
            if sample.isEmpty {
                guard AnalyzerAudio.hasSound(buffer) else { continue }
                let start = CMTime(value: audio.position - AVAudioFramePosition(buffer.frameLength), timescale: CMTimeScale(format.sampleRate))
                sample.append(AnalyzerInput(buffer: buffer, bufferStartTime: start))
            } else {
                sample.append(AnalyzerInput(buffer: buffer))
            }
            lengths.append(Int(buffer.frameLength))
            if lengths.reduce(0, +) >= enough { break }
        }
        let wholeFile = audio.ended
        guard !sample.isEmpty else {
            log.notice("Language detection: no sound found; using \(candidates[0].identifier, privacy: .public)")
            return (candidates[0], wholeFile ? [] : nil)
        }
        if !wholeFile {
            while lengths.count > 1 && lengths.reduce(0, +) - lengths[lengths.count - 1] >= wanted {
                lengths.removeLast()
                sample.removeLast()
            }
        }
        let sampleSeconds = Double(lengths.reduce(0, +)) / format.sampleRate

        let analyzer = SpeechAnalyzer(modules: transcribers, options: .init(priority: .utility, modelRetention: .whileInUse))
        let collectors = transcribers.map { transcriber in
            Task { () -> (confidence: Double, words: Int, tokens: [Transcript.Token]) in
                var total = 0.0, words = 0
                var tokens: [Transcript.Token] = []
                for try await result in transcriber.results {
                    heartbeat.beat()
                    for run in result.text.runs {
                        if let confidence = run.transcriptionConfidence { total += confidence; words += 1 }
                    }
                    append(result, to: &tokens)
                }
                return (words > 0 ? total / Double(words) : 0, words, tokens)
            }
        }
        let inputs = sample
        let stream = AsyncStream<AnalyzerInput> { continuation in
            for input in inputs { continuation.yield(input) }
            continuation.finish()
        }
        do {
            try await withTaskCancellationHandler {
                if let end = try await analyzer.analyzeSequence(stream) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
                for collector in collectors { collector.cancel() }
            }
        } catch {
            Task { await analyzer.cancelAndFinishNow() }
            for collector in collectors { collector.cancel() }
            throw error
        }
        var scores: [(confidence: Double, words: Int, tokens: [Transcript.Token])] = []
        for collector in collectors { scores.append(try await collector.value) }

        // The highest average confidence per word; on a tie, the language listed first.
        var best = 0
        for index in scores.indices where scores[index].words > 0 && scores[index].confidence > scores[best].confidence { best = index }
        let summary = zip(candidates, scores).map { "\($0.identifier) \(String(format: "%.3f", $1.confidence)) (\($1.words) words)" }
        log.notice("Language detection on \(Int(sampleSeconds.rounded()), privacy: .public) s: \(summary.joined(separator: ", "), privacy: .public) → \(candidates[best].identifier, privacy: .public), in \(Transcription.elapsed(since: started), privacy: .public) s")
        return (candidates[best], wholeFile ? scores[best].tokens : nil)
    }

    private static func analyze(_ url: URL, in locale: Locale, duration: Double,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.Token] {
        let log = Transcription.log
        let transcriber = transcriber(locale)
        let format = try await Transcription.watch("Audio format lookup", limit: StallLimit.lookup) { _ in
            await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        }
        guard let format else { throw ModernFailure.unavailable("no audio format for \(locale.identifier)") }
        let stallAnalyzer = Debug.isOn("CONVERT_ANYTHING_STALL_ANALYZER"), stallResults = Debug.isOn("CONVERT_ANYTHING_STALL_RESULTS")
        log.notice("Analyzer starting in \(locale.identifier, privacy: .public), \(Int(format.sampleRate), privacy: .public) Hz")
        let started = ContinuousClock.now
        let tokens = try await Transcription.watch("Analyzer", limit: StallLimit.analysis) { heartbeat in
            let audio = try AnalyzerAudio(url, as: format)
            // Released as soon as the file is done, so the model doesn't sit in memory while the app idles.
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .whileInUse))
            let collector = Task {
                var tokens: [Transcript.Token] = []
                for try await result in transcriber.results {
                    heartbeat.beat()
                    append(result, to: &tokens)
                    progress(min(1, result.range.end.seconds / duration))
                }
                if stallResults { await Debug.hang() }
                return tokens
            }
            let input = AsyncThrowingStream<AnalyzerInput, Error> {
                heartbeat.beat()
                if stallAnalyzer && audio.seconds >= duration * 0.2 { await Debug.hang() }
                return try audio.next().map { AnalyzerInput(buffer: $0) }
            }
            do {
                try await withTaskCancellationHandler {
                    if let end = try await analyzer.analyzeSequence(input) {
                        try await analyzer.finalizeAndFinish(through: end)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                } onCancel: {
                    Task { await analyzer.cancelAndFinishNow() }
                    collector.cancel()
                }
            } catch {
                // Finishing the analyzer ends the results too, so the collector can't be left waiting.
                Task { await analyzer.cancelAndFinishNow() }
                collector.cancel()
                throw Task.isCancelled ? ConversionError.cancelled : error
            }
            return try await collector.value
        }
        if Task.isCancelled { throw ConversionError.cancelled }
        log.notice("Analyzer finished: \(tokens.count, privacy: .public) words in \(Transcription.elapsed(since: started), privacy: .public) s")
        return tokens
    }

    /// Each timed run is a word; the untimed text between them (spaces, punctuation) stays with the word before it.
    private static func append(_ result: SpeechTranscriber.Result, to tokens: inout [Transcript.Token]) {
        let text = result.text
        var first = true
        for run in text.runs {
            var piece = String(text[run.range].characters)
            if first, let last = tokens.last?.text.last, let next = piece.first,
               !last.isWhitespace, !next.isWhitespace, !(Transcription.isUnspaced(last) && Transcription.isUnspaced(next)) {
                tokens[tokens.count - 1].text += " "
            }
            if let range = run.audioTimeRange {
                tokens.append(.init(text: piece, start: range.start.seconds, end: range.end.seconds))
            } else if !tokens.isEmpty && !first {
                tokens[tokens.count - 1].text += piece
            } else {
                piece = piece.trimmingCharacters(in: .whitespaces)
                tokens.append(.init(text: piece, start: result.range.start.seconds, end: result.range.start.seconds))
            }
            first = false
        }
    }
}

// MARK: - macOS 14 and 15

/// SFSpeechRecognizer, kept on-device. It works on about a minute of audio at a time and forgets what came
/// before a long pause, so the audio is fed in pieces cut at each pause, or at the quietest moment before
/// 55 seconds when the speaker doesn't stop.
nonisolated private enum LegacyEngine {
    static let sampleRate = 16_000.0

    /// Why the older engine can't run here, each with what to do about it.
    enum Unavailable: Error, CustomStringConvertible {
        case notAllowed
        case noRecognizer
        case notOnDevice(Locale)

        var message: String {
            switch self {
            case .notAllowed:
                "Convert Anything isn't allowed to recognize speech. Turn it on in System Settings › Privacy & Security › Speech Recognition."
            case .noRecognizer:
                "Speech recognition isn't available on this Mac."
            case .notOnDevice(let locale):
                "This Mac can't recognize \(Transcription.languageName(locale)) speech without the internet. Turn on Dictation in System Settings › Keyboard to download it, then try again."
            }
        }

        var description: String {
            switch self {
            case .notAllowed: "not allowed to recognize speech"
            case .noRecognizer: "no recognizer"
            case .notOnDevice(let locale): "no on-device model for \(locale.identifier)"
            }
        }
    }

    /// `language` is the one SpeechAnalyzer chose, when it got that far; otherwise the first preferred
    /// language this recognizer knows, or English.
    static func transcribe(_ url: URL, duration: Double, language: Locale?,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.Token] {
        let log = Transcription.log
        try await authorize()
        guard let recognizer = recognizer(for: language) else { throw Unavailable.noRecognizer }
        let onDevice = recognizer.supportsOnDeviceRecognition && !Debug.isOn("CONVERT_ANYTHING_NO_LEGACY_SPEECH")
        log.notice("SFSpeechRecognizer in \(recognizer.locale.identifier, privacy: .public), on-device model \(onDevice ? "present" : "missing", privacy: .public)")
        guard onDevice else { throw Unavailable.notOnDevice(recognizer.locale) }

        let audio = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: audio.processingFormat, to: format) else {
            throw ConversionError.failed("Couldn't read this file's sound.")
        }
        let maxChunk = Int(55 * sampleRate), searchFrom = Int(40 * sampleRate)
        var samples: [Float] = []
        var offset = 0.0
        var tokens: [Transcript.Token] = []
        var finished = false
        let started = ContinuousClock.now
        while !finished || !samples.isEmpty {
            try Task.checkCancellation()
            if !finished { finished = try read(audio, through: converter, into: &samples, upTo: maxChunk) }
            let cut = firstPause(in: samples, limit: maxChunk)
                ?? (samples.count > maxChunk ? quietestPoint(in: samples, from: searchFrom, to: maxChunk) : samples.count)
            // A silent piece (the quiet tail after the last words) makes the old recognizer invent a word.
            if hasSound(samples[0..<cut]) {
                let piece = Array(samples[0..<cut]), pieceOffset = offset
                tokens += try await Transcription.watch("Speech recognizer", limit: StallLimit.legacyPiece) { _ in
                    try await recognize(piece[...], offset: pieceOffset, with: recognizer, format: format)
                }
            }
            samples.removeFirst(cut)
            offset += Double(cut) / sampleRate
            progress(min(1, offset / duration))
        }
        log.notice("SFSpeechRecognizer finished: \(tokens.count, privacy: .public) words in \(Transcription.elapsed(since: started), privacy: .public) s")
        return tokens
    }

    private static func recognizer(for language: Locale?) -> SFSpeechRecognizer? {
        if let language, let recognizer = SFSpeechRecognizer(locale: language) { return recognizer }
        let supported = Array(SFSpeechRecognizer.supportedLocales())
        for identifier in SpeechLanguages.preferred {
            if let locale = SpeechLanguages.match(identifier, in: supported), let recognizer = SFSpeechRecognizer(locale: locale) {
                return recognizer
            }
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    private static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            Transcription.log.notice("Waiting for permission to recognize speech")
            do {
                status = try await Transcription.watch("Permission prompt", limit: StallLimit.permission) { _ in
                    await withCheckedContinuation { continuation in
                        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                    }
                }
            } catch is Stalled {
                throw Unavailable.notAllowed
            }
        }
        guard status == .authorized else { throw Unavailable.notAllowed }
    }

    /// Converts audio to 16 kHz mono until `samples` holds `limit` samples. Returns true at the end of the file.
    private static func read(_ audio: AVAudioFile, through converter: AVAudioConverter, into samples: inout [Float], upTo limit: Int) throws -> Bool {
        let chunk: AVAudioFrameCount = 16_000
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: chunk),
              let input = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 32_768) else { return true }
        while samples.count < limit {
            var readError: Error?
            var ended = false
            let status = converter.convert(to: output, error: nil) { _, inputStatus in
                do {
                    try audio.read(into: input)
                } catch {
                    readError = error
                }
                if input.frameLength == 0 || readError != nil {
                    ended = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let readError, audio.framePosition < audio.length { throw readError }
            if status == .error { throw ConversionError.failed("Couldn't read this file's sound.") }
            if let data = output.floatChannelData, output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || (ended && output.frameLength == 0) { return true }
        }
        return false
    }

    /// The middle of the first pause of 0.7 seconds or more (quieter than -40 dB) that follows some sound,
    /// within the first `limit` samples.
    private static func firstPause(in samples: [Float], limit: Int) -> Int? {
        let window = Int(sampleRate / 20), needed = Int(0.7 * sampleRate)
        var heard = false, quiet = 0, position = 0
        let end = min(samples.count, limit)
        while position + window <= end {
            var energy: Float = 0
            for index in position..<position + window { energy += samples[index] * samples[index] }
            if energy / Float(window) < 1e-4 {
                quiet += window
                if heard && quiet >= needed { return position + window - quiet / 2 }
            } else {
                heard = true
                quiet = 0
            }
            position += window
        }
        return nil
    }

    /// Whether any twentieth of a second is louder than the pause threshold.
    private static func hasSound(_ samples: ArraySlice<Float>) -> Bool {
        let window = Int(sampleRate / 20)
        var position = samples.startIndex
        while position + window <= samples.endIndex {
            var energy: Float = 0
            for index in position..<position + window { energy += samples[index] * samples[index] }
            if energy / Float(window) >= 1e-4 { return true }
            position += window
        }
        return false
    }

    /// The start of the quietest tenth of a second between `start` and `end`.
    private static func quietestPoint(in samples: [Float], from start: Int, to end: Int) -> Int {
        let window = Int(sampleRate / 10)
        var best = end, lowest = Float.greatestFiniteMagnitude
        var position = start
        while position + window <= end {
            var energy: Float = 0
            for index in position..<position + window { energy += samples[index] * samples[index] }
            if energy < lowest { lowest = energy; best = position + window / 2 }
            position += window / 2
        }
        return best
    }

    /// One piece of audio through the recognizer. Every final result is kept, since a long pause can end one.
    private static func recognize(_ samples: ArraySlice<Float>, offset: Double, with recognizer: SFSpeechRecognizer,
                                  format: AVAudioFormat) async throws -> [Transcript.Token] {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.append(buffer)
        request.endAudio()

        let state = RecognitionState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.start(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        state.add(tokens(in: result.bestTranscription, offset: offset))
                    }
                    if let error {
                        // "No speech detected" just means this piece was silent or music.
                        let nsError = error as NSError
                        state.finish(nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 ? nil : error)
                    } else if result?.isFinal == true {
                        state.finish(nil)
                    }
                }
                state.task = task
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Each word with the spaces and punctuation that follow it, so the words joined give back the full text.
    private static func tokens(in transcription: SFTranscription, offset: Double) -> [Transcript.Token] {
        let text = transcription.formattedString as NSString
        let segments = transcription.segments
        return segments.enumerated().map { index, segment in
            let start = index == 0 ? 0 : segment.substringRange.location
            let end = index + 1 < segments.count ? segments[index + 1].substringRange.location : text.length
            let piece = text.substring(with: NSRange(location: start, length: max(0, end - start)))
            return .init(text: piece, start: offset + segment.timestamp, end: offset + segment.timestamp + segment.duration)
        }
    }

    /// Hands the recognizer's callbacks to the waiting task exactly once, whatever order they arrive in.
    private final class RecognitionState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[Transcript.Token], Error>?
        private var tokens: [Transcript.Token] = []
        private var cancelled = false
        var task: SFSpeechRecognitionTask? {
            get { lock.withLock { _task } }
            set { lock.withLock { _task = newValue }; if lock.withLock({ cancelled }) { newValue?.cancel() } }
        }
        private var _task: SFSpeechRecognitionTask?

        func start(_ continuation: CheckedContinuation<[Transcript.Token], Error>) {
            let alreadyCancelled = lock.withLock { () -> Bool in self.continuation = continuation; return cancelled }
            if alreadyCancelled { finish(ConversionError.cancelled) }
        }

        func add(_ more: [Transcript.Token]) { lock.withLock { tokens += more } }

        func finish(_ error: Error?) {
            let (continuation, tokens) = lock.withLock { () -> (CheckedContinuation<[Transcript.Token], Error>?, [Transcript.Token]) in
                defer { self.continuation = nil }
                return (self.continuation, self.tokens)
            }
            if let error { continuation?.resume(throwing: error) } else { continuation?.resume(returning: tokens) }
        }

        func cancel() {
            let task = lock.withLock { () -> SFSpeechRecognitionTask? in cancelled = true; return _task }
            task?.cancel()
            finish(ConversionError.cancelled)
        }
    }
}

// MARK: - Writing it out

/// Timed words → readable paragraphs or subtitle cues. Shared by both engines and by subtitle files.
nonisolated enum Transcript {
    /// A word (or, in Chinese and Japanese, a few characters) with the spaces and punctuation after it, and when it was said.
    struct Token: Sendable, Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    struct Cue: Sendable, Equatable {
        var start: Double
        var end: Double
        var lines: [String]
    }

    static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]

    static func endsSentence(_ token: Token) -> Bool {
        var text = Substring(token.text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = text.last, "\"'”’)]".contains(last) { text = text.dropLast() }
        return text.last.map(sentenceEnds.contains) ?? false
    }

    /// Plain text with a new paragraph wherever the speaker pauses at the end of a sentence, or pauses for
    /// long in the middle of one. Very long stretches without pauses still break at a sentence end.
    static func paragraphs(from tokens: [Token]) -> String {
        var paragraphs: [String] = []
        var current = ""
        for (index, token) in tokens.enumerated() {
            current += token.text
            guard index + 1 < tokens.count else { break }
            let gap = tokens[index + 1].start - token.end
            let sentence = endsSentence(token)
            if gap >= 2.5 || (sentence && (gap >= 1.0 || current.count >= 700)) {
                paragraphs.append(current)
                current = ""
            }
        }
        paragraphs.append(current)
        return paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n") + "\n"
    }

    /// Subtitle cues of at most two lines of about 42 characters and 6 seconds, starting fresh at each
    /// sentence and after each pause.
    static func cues(from tokens: [Token], lineWidth: Int = 42, maxDuration: Double = 6) -> [Cue] {
        var groups: [[Token]] = []
        var current: [Token] = []
        for token in tokens {
            if let last = current.last, let first = current.first {
                let width = self.width(current.map(\.text).joined() + token.text)
                let breaks = endsSentence(last)
                    || token.start - last.end >= 1.0
                    || token.end - first.start > maxDuration
                    || width > 2 * lineWidth
                    || lines(for: current + [token], width: lineWidth).contains { self.width($0) > lineWidth }
                    || (width > lineWidth * 3 / 2 && last.text.trimmingCharacters(in: .whitespaces).last.map { ",;:、，".contains($0) } == true)
                if breaks {
                    groups.append(current)
                    current = []
                }
            }
            current.append(token)
        }
        if !current.isEmpty { groups.append(current) }

        var cues = groups.map { group in
            Cue(start: group.first!.start, end: group.last!.end, lines: lines(for: group, width: lineWidth))
        }
        // Short cues stay up for at least a second (when the next one allows), so they can be read.
        for index in cues.indices {
            let next = index + 1 < cues.count ? cues[index + 1].start : .infinity
            cues[index].end = max(cues[index].end, min(cues[index].start + 1, next))
        }
        return cues
    }

    /// One line, or two of about equal length, broken between words.
    private static func lines(for group: [Token], width lineWidth: Int) -> [String] {
        let full = group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard width(full) > lineWidth, group.count > 1 else { return [full] }
        var best = 1, bestWidth = Int.max
        for split in 1..<group.count {
            let first = width(group[..<split].map(\.text).joined()), second = width(group[split...].map(\.text).joined())
            if max(first, second) < bestWidth { bestWidth = max(first, second); best = split }
        }
        return [group[..<best], group[best...]].map { $0.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Characters on screen; Chinese and Japanese characters are about twice as wide as Latin ones.
    private static func width(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).reduce(0) { $0 + (Transcription.isUnspaced($1) ? 2 : 1) }
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(time(cue.start, ",")) --> \(time(cue.end, ","))\n\(cue.lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(time(cue.start, ".")) --> \(time(cue.end, "."))\n\(cue.lines.joined(separator: "\n"))\n"
        }.joined(separator: "\n")
    }

    /// HH:MM:SS,mmm (SRT) or HH:MM:SS.mmm (WebVTT).
    static func time(_ seconds: Double, _ separator: String) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, separator, total % 1000)
    }
}

// MARK: - Subtitle files

/// SRT and WebVTT files: their text without the timings, or the same cues in the other format.
nonisolated enum Subtitles {
    /// Formats that are written directly; other documents (Word, PDF…) are laid out from the plain text.
    static let directTargets: [Format] = [.txt, .md, .srt, .vtt]

    static func convert(_ request: Converter.Request, output: URL) async throws {
        let data = try Data(contentsOf: request.input)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ConversionError.failed("Couldn't read this subtitle file.")
        }
        let cues = parse(text)
        guard !cues.isEmpty else { throw ConversionError.failed("No subtitles were found in this file.") }
        // Each cue joins the text like a word does, so pauses between cues still start new paragraphs.
        let paragraphs = Transcript.paragraphs(from: cues.map { cue in
            .init(text: cue.lines.joined(separator: " ") + " ", start: cue.start, end: cue.end)
        })
        switch request.to {
        case .srt: try Transcript.srt(cues).write(to: output, atomically: true, encoding: .utf8)
        case .vtt: try Transcript.vtt(cues).write(to: output, atomically: true, encoding: .utf8)
        case .txt, .md: try paragraphs.write(to: output, atomically: true, encoding: .utf8)
        default:
            let text = request.workDir.appending(path: "subtitles.txt")
            try paragraphs.write(to: text, atomically: true, encoding: .utf8)
            let textRequest = Converter.Request(input: text, from: .txt, to: request.to, workDir: request.workDir,
                                            title: request.title, originalDir: request.originalDir, quality: request.quality)
            try await DocumentConversion.convert(textRequest, output: output)
        }
    }

    /// Reads cues from SRT or WebVTT, dropping numbering, styling tags and WebVTT's notes and style blocks.
    static func parse(_ text: String) -> [Transcript.Cue] {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var cues: [Transcript.Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = seconds(parts[0]),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]) else { continue }
            let body = lines[(timing + 1)...].map(clean).filter { !$0.isEmpty }
            if !body.isEmpty { cues.append(.init(start: start, end: end, lines: body)) }
        }
        return cues
    }

    /// "01:02:03,456", "01:02:03.456" or WebVTT's short "02:03.456".
    private static func seconds(_ text: String) -> Double? {
        let fields = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Removes <i>, <font …>, <v Speaker> and {\an8}-style tags.
    private static func clean(_ line: String) -> String {
        line.replacing(/<[^>]*>/, with: "").replacing(/\{\\[^}]*\}/, with: "").trimmingCharacters(in: .whitespaces)
    }
}
