import Foundation

/// 예배 전체 빠른 음성 스캔 (whisper base, SPEC §6.0 자동 찾기). 결과는 캐시해 두고 다시 쓴다.
/// 09/13 실측: 92분을 93초에 전사. "대표기도"·"봉헌" 같은 낱말은 잘 못 잡지만 봉독 안내 음성은 잡는다.
public struct QuickScanner: Sendable {
    public var locator: BinaryLocator
    public var modelPath: String
    public var vadModelPath: String?

    public init(locator: BinaryLocator = BinaryLocator(), modelPath: String? = nil, vadModelPath: String? = nil) {
        self.locator = locator
        let dir = WhisperOptions.defaultModelsDirectory()
        self.modelPath = modelPath ?? dir.appendingPathComponent("ggml-base.bin").path
        self.vadModelPath = vadModelPath ?? WhisperOptions.defaults().vadModelPath
    }

    public var isAvailable: Bool { FileManager.default.fileExists(atPath: modelPath) }

    public func scan(video: URL, duration: Double, cacheDirectory: URL,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptSegment] {
        let dir = cacheDirectory.appendingPathComponent("quickscan-" + WaveformGenerator.cacheKey(video))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = dir.appendingPathComponent("base")
        let json = prefix.appendingPathExtension("json")
        if !FileManager.default.fileExists(atPath: json.path) {
            let wav = dir.appendingPathComponent("full.wav")
            if !FileManager.default.fileExists(atPath: wav.path) {
                try await AudioExtractor(locator: locator).extract(video: video, range: TimeRange(start: 0, end: duration), to: wav) { p in
                    progress?(p * 0.2)
                }
            }
            var options = WhisperOptions(modelPath: modelPath, vadModelPath: vadModelPath)
            options.threads = 8
            _ = try await WhisperTranscriber(locator: locator, options: options).transcribe(wav: wav, outputPrefix: prefix) { p in
                progress?(0.2 + p * 0.8)
            }
            try? FileManager.default.removeItem(at: wav)   // 90분 wav(170MB)는 남기지 않는다
        }
        progress?(1)
        // 전체 오디오를 0초부터 뽑았으므로 원본 기준 시간 = whisper 시간
        return try TranscriptParser.parse(Data(contentsOf: json), sourceStart: 0)
    }
}
