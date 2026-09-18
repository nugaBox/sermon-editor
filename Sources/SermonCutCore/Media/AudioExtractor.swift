import Foundation

/// 원본 영상의 sourceRange 구간만 16kHz mono wav로 뽑는다. 원본은 읽기만 한다.
public struct AudioExtractor: Sendable {
    public var locator: BinaryLocator

    public init(locator: BinaryLocator = BinaryLocator()) { self.locator = locator }

    /// - progress: 0...1
    public func extract(video: URL, range: TimeRange, to output: URL,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard range.duration > 0 else { throw SermonCutError.invalidRange(start: range.start, end: range.end) }
        let ffmpeg = try locator.url(for: .ffmpeg)
        let total = range.duration
        try await ProcessRunner.run(ffmpeg, [
            "-nostdin", "-hide_banner", "-v", "error", "-y",
            "-ss", String(format: "%.3f", range.start),
            "-t", String(format: "%.3f", total),
            "-i", video.path,
            "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
            "-progress", "pipe:1",
            output.path,
        ], toolName: "ffmpeg", onStdoutLine: { line in
            guard let progress, line.hasPrefix("out_time_us="),
                  let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress(min(1, us / 1_000_000 / total))
        })
    }
}
