import Foundation

/// 초 ↔ 프레임, FCPXML 유리수 시간 문자열 (docs/fcpxml-reference.md §1)
public struct FrameSnapper: Sendable {
    public let media: MediaInfo

    public init(media: MediaInfo) { self.media = media }

    /// 가장 가까운 프레임 번호
    public func frame(_ seconds: Double) -> Int {
        Int((seconds * Double(media.frameRateNum) / Double(media.frameRateDen)).rounded())
    }

    public func seconds(_ frame: Int) -> Double {
        Double(frame) * Double(media.frameRateDen) / Double(media.frameRateNum)
    }

    /// 프레임 수 → "N/3000s" (30fps) / "N/30000s" (29.97). 0은 "0s"
    public func fcpTime(frames: Int) -> String {
        guard frames != 0 else { return "0s" }
        return "\(frames * media.frameDurationValue)/\(media.timescale)s"
    }

    /// 프레임 절반 단위가 필요한 트랜지션 offset용: value 단위(1/timescale)로 직접 표기
    public func fcpTime(value: Int) -> String {
        guard value != 0 else { return "0s" }
        return "\(value)/\(media.timescale)s"
    }

    public var frameDurationString: String { "\(media.frameDurationValue)/\(media.timescale)s" }
}
