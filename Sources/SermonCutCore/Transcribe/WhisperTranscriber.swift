import Foundation

public struct WhisperOptions: Sendable {
    public var modelPath: String
    /// Silero VAD 모델. 있으면 반드시 쓴다 — 없으면 large-v3가 긴 오디오에서 같은 문장을 수십 번 반복하는 루프에 빠진다(2026-09 실측: 15분 손실)
    public var vadModelPath: String?
    public var language: String = "ko"
    public var threads: Int = 8

    public init(modelPath: String, vadModelPath: String?, language: String = "ko", threads: Int = 8) {
        self.modelPath = modelPath
        self.vadModelPath = vadModelPath
        self.language = language
        self.threads = threads
    }

    /// 기본 위치: ~/Library/Application Support/SermonCut/models
    public static func defaultModelsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SermonCut/models")
    }

    public static func defaults() -> WhisperOptions {
        let dir = defaultModelsDirectory()
        let vad = dir.appendingPathComponent("ggml-silero-v5.1.2.bin").path
        return WhisperOptions(
            modelPath: dir.appendingPathComponent("ggml-large-v3.bin").path,
            vadModelPath: FileManager.default.fileExists(atPath: vad) ? vad : nil
        )
    }
}

/// whisper.cpp(whisper-cli) 실행 → JSON 파일 경로
public struct WhisperTranscriber: Sendable {
    public var locator: BinaryLocator
    public var options: WhisperOptions

    public init(locator: BinaryLocator = BinaryLocator(), options: WhisperOptions) {
        self.locator = locator
        self.options = options
    }

    /// - Returns: 생성된 JSON 파일 URL (`outputPrefix` + ".json")
    public func transcribe(wav: URL, outputPrefix: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let exe = try locator.url(for: .whisperCLI)
        guard FileManager.default.fileExists(atPath: options.modelPath) else {
            throw SermonCutError.invalidArgument("whisper 모델 파일이 없습니다: \(options.modelPath)")
        }
        var args = [
            "-m", options.modelPath,
            "-f", wav.path,
            "-l", options.language,
            "-t", String(options.threads),
            "-mc", "0",          // 이전 문맥을 넘기지 않음 → 반복 루프 방지
            "-ojf",
            "-of", outputPrefix.path,
            "-pp",
        ]
        if let vad = options.vadModelPath {
            args += ["--vad", "-vm", vad]
        }
        try await ProcessRunner.run(exe, args, toolName: "whisper-cli", onStderrLine: { line in
            // "whisper_print_progress_callback: progress =  45%"
            guard let progress, let r = line.range(of: "progress =") else { return }
            let digits = line[r.upperBound...].filter(\.isNumber)
            if let v = Double(digits) { progress(v / 100) }
        })
        return outputPrefix.appendingPathExtension("json")
    }
}
