import Foundation

public enum ExternalTool: String, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe
    case whisperCLI = "whisper-cli"
    case unzip
    case xmllint
}

/// 외부 바이너리 경로 해석. 순서: 설정 지정 경로 → 앱 번들 Resources/bin → Homebrew → 시스템 (SPEC §2)
public struct BinaryLocator: Sendable {
    public var overrides: [ExternalTool: String]

    public init(overrides: [ExternalTool: String] = [:]) {
        self.overrides = overrides
    }

    public func url(for tool: ExternalTool) throws -> URL {
        let fm = FileManager.default
        var candidates: [String] = []
        if let o = overrides[tool] { candidates.append(o) }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("bin/\(tool.rawValue)").path)
        }
        candidates += ["/opt/homebrew/bin/\(tool.rawValue)", "/usr/local/bin/\(tool.rawValue)", "/usr/bin/\(tool.rawValue)"]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw SermonCutError.binaryNotFound(tool: tool.rawValue)
    }
}
