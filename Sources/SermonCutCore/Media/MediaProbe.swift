import Foundation

/// ffprobe → MediaInfo
public struct MediaProbe: Sendable {
    public var locator: BinaryLocator

    public init(locator: BinaryLocator = BinaryLocator()) { self.locator = locator }

    public func probe(_ video: URL) async throws -> MediaInfo {
        let ffprobe = try locator.url(for: .ffprobe)
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", video.path,
        ], toolName: "ffprobe")
        return try Self.parse(result.stdout)
    }

    public static func parse(_ json: Data) throws -> MediaInfo {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else {
            throw SermonCutError.mediaProbeFailed(reason: "ffprobe 출력이 JSON이 아닙니다")
        }
        // 커버 이미지(attached_pic)는 영상 트랙이 아니다
        let video = streams.first { s in
            (s["codec_type"] as? String) == "video"
                && ((s["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0
        }
        guard let video else { throw SermonCutError.noVideoStream }
        let audio = streams.first { ($0["codec_type"] as? String) == "audio" }

        guard let rate = (video["r_frame_rate"] as? String) ?? (video["avg_frame_rate"] as? String),
              let (num, den) = parseRational(rate), num > 0, den > 0 else {
            throw SermonCutError.mediaProbeFailed(reason: "프레임레이트를 알 수 없습니다")
        }
        let formatDuration = ((root["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init)
        let streamDuration = (video["duration"] as? String).flatMap(Double.init)
        guard let duration = formatDuration ?? streamDuration else {
            throw SermonCutError.mediaProbeFailed(reason: "길이를 알 수 없습니다")
        }
        return MediaInfo(
            durationSeconds: duration,
            frameRateNum: num, frameRateDen: den,
            width: video["width"] as? Int ?? 0,
            height: video["height"] as? Int ?? 0,
            hasAudio: audio != nil,
            audioSampleRate: (audio?["sample_rate"] as? String).flatMap(Int.init),
            audioChannels: audio?["channels"] as? Int
        )
    }

    static func parseRational(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]) else { return nil }
        // 30000/1001 처럼 이미 표준형이면 그대로, 60/2 같은 경우 약분
        let g = gcd(n, d)
        return g > 0 ? (n / g, d / g) : nil
    }
}

func gcd(_ a: Int, _ b: Int) -> Int {
    var (a, b) = (abs(a), abs(b))
    while b != 0 { (a, b) = (b, a % b) }
    return a
}
