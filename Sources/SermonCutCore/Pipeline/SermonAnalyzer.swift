import Foundation

/// 분석 단계 전체 (SPEC §1 4단계): 오디오 추출 → 전사 → 무음 → 원고 → 정렬 → 삭제 제안
/// 작업 폴더에 중간 결과를 캐시해 두고, 있으면 다시 쓴다.
public struct SermonAnalyzer: Sendable {
    public enum Stage: String, Sendable {
        case probe = "영상 정보 읽기"
        case extractAudio = "오디오 추출"
        case transcribe = "음성 전사"
        case silence = "무음 구간 분석"
        case manuscript = "원고 읽기"
        case align = "원고 정렬"
    }

    public struct Input: Sendable {
        public var video: URL
        public var sourceRange: TimeRange
        public var manuscript: URL?
        public var workDirectory: URL
        public var settings = ExportSettings()
        public init(video: URL, sourceRange: TimeRange, manuscript: URL?, workDirectory: URL) {
            self.video = video
            self.sourceRange = sourceRange
            self.manuscript = manuscript
            self.workDirectory = workDirectory
        }
    }

    public var locator: BinaryLocator
    public var whisper: WhisperOptions
    public var aligner = LocalAligner()
    public var suggester = RemovalSuggester()

    public init(locator: BinaryLocator = BinaryLocator(), whisper: WhisperOptions = .defaults()) {
        self.locator = locator
        self.whisper = whisper
    }

    public func run(_ input: Input,
                    onStage: (@Sendable (Stage) -> Void)? = nil,
                    onProgress: (@Sendable (Stage, Double) -> Void)? = nil) async throws -> SermonProject {
        let fm = FileManager.default
        try fm.createDirectory(at: input.workDirectory, withIntermediateDirectories: true)

        onStage?(.probe)
        let media = try await MediaProbe(locator: locator).probe(input.video)
        let range = TimeRange(start: max(0, input.sourceRange.start), end: min(media.durationSeconds, input.sourceRange.end))
        guard range.duration > 1 else { throw SermonCutError.invalidRange(start: range.start, end: range.end) }

        // 캐시 키: 구간이 바뀌면 다시 뽑는다
        let key = String(format: "%.3f-%.3f", range.start, range.end)
        let wav = input.workDirectory.appendingPathComponent("audio_\(key).wav")
        let transcriptPrefix = input.workDirectory.appendingPathComponent("transcript_\(key)")
        let transcriptJSON = transcriptPrefix.appendingPathExtension("json")

        onStage?(.extractAudio)
        if !fm.fileExists(atPath: wav.path) {
            let tmp = input.workDirectory.appendingPathComponent("audio_\(key).partial.wav")
            try await AudioExtractor(locator: locator).extract(video: input.video, range: range, to: tmp) { p in
                onProgress?(.extractAudio, p)
            }
            try? fm.removeItem(at: wav)
            try fm.moveItem(at: tmp, to: wav)
        }
        try Task.checkCancellation()

        onStage?(.transcribe)
        if !fm.fileExists(atPath: transcriptJSON.path) {
            _ = try await WhisperTranscriber(locator: locator, options: whisper).transcribe(wav: wav, outputPrefix: transcriptPrefix) { p in
                onProgress?(.transcribe, p)
            }
        }
        // ★ 원본 기준 시간으로 변환은 TranscriptParser 한 곳에서만
        let segments = try TranscriptParser.parse(try Data(contentsOf: transcriptJSON), sourceStart: range.start)
        try Task.checkCancellation()

        onStage?(.silence)
        let silences = try await SilenceDetector(locator: locator).detect(
            audio: wav, sourceStart: range.start,
            thresholdDB: input.settings.silenceThresholdDB, minDuration: input.settings.minSilenceDuration)

        var manuscript: Manuscript?
        if let m = input.manuscript {
            onStage?(.manuscript)
            manuscript = try await ManuscriptLoader(locator: locator).load(m)
        }

        onStage?(.align)
        var project = SermonProject(videoPath: input.video.path, manuscriptPath: input.manuscript?.path, media: media,
                                    sourceRange: range, segments: segments, manuscript: manuscript,
                                    silences: silences, settings: input.settings)
        project = realign(project)
        return project
    }

    /// 원고 정렬 + 삭제 제안만 다시 (파라미터 조정용)
    public func realign(_ project: SermonProject) -> SermonProject {
        var p = project
        let sentences = p.manuscript?.sentences ?? []
        let alignment = aligner.align(segments: p.segments, sentences: sentences)
        let result = suggester.apply(segments: p.segments.map { s in
            var s = s
            if !s.userOverridden { s.isRemoved = false }
            return s
        }, alignment: alignment, sentences: sentences, sourceRange: p.sourceRange)
        p.segments = result.segments
        p.candidates = result.suggestions.enumerated().map { i, s in
            DigressionCandidate(id: "C\(i + 1)", segmentIDs: s.runSegmentIDs, range: s.range, localOverlap: s.localOverlap,
                                globalOverlap: s.globalOverlap, localRemoved: s.removed, ai: nil)
        }
        p.updatedAt = Date()
        return p
    }
}

public enum ProjectFile {
    public static func save(_ project: SermonProject, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        do { try enc.encode(project).write(to: url, options: .atomic) } catch {
            throw SermonCutError.fileWriteFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    public static func load(_ url: URL) throws -> SermonProject {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(SermonProject.self, from: Data(contentsOf: url))
    }
}
