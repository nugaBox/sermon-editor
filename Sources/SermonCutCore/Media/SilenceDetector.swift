import Foundation

/// ffmpeg silencedetect. 잘라낸 wav를 분석하므로 결과에 sourceStart를 더한다 (SPEC §4 — 파싱 직후 한 번만).
public struct SilenceDetector: Sendable {
    public var locator: BinaryLocator

    public init(locator: BinaryLocator = BinaryLocator()) { self.locator = locator }

    public func detect(audio: URL, sourceStart: Double, thresholdDB: Double, minDuration: Double) async throws -> [TimeRange] {
        let ffmpeg = try locator.url(for: .ffmpeg)
        let result = try await ProcessRunner.run(ffmpeg, [
            "-nostdin", "-hide_banner", "-nostats", "-i", audio.path,
            "-af", "silencedetect=noise=\(thresholdDB)dB:d=\(minDuration)",
            "-f", "null", "-",
        ], toolName: "ffmpeg")
        return Self.parse(result.stderrString, sourceStart: sourceStart)
    }

    /// `silence_start: 12.3` / `silence_end: 13.1 | silence_duration: 0.8` 줄을 읽는다.
    public static func parse(_ log: String, sourceStart: Double) -> [TimeRange] {
        var ranges: [TimeRange] = []
        var openStart: Double?
        for line in log.split(separator: "\n") {
            if let r = line.range(of: "silence_start: ") {
                openStart = Double(line[r.upperBound...].prefix { !$0.isWhitespace })
            } else if let r = line.range(of: "silence_end: ") {
                let endText = line[r.upperBound...].prefix { !$0.isWhitespace && $0 != "|" }
                if let end = Double(endText) {
                    let start = max(0, openStart ?? 0)
                    ranges.append(TimeRange(start: start + sourceStart, end: end + sourceStart))
                }
                openStart = nil
            }
        }
        return ranges
    }
}
