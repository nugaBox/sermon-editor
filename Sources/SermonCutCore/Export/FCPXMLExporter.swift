import Foundation

/// FCPXML 1.14 출력. 형태는 Phase 0 라운드트립으로 검증된 단순형 (docs/fcpxml-reference.md §4, §7)
public struct FCPXMLExporter: Sendable {
    public struct Options: Sendable {
        public var eventName: String
        public var projectName: String
        public var audioGainDB: Double
        /// 로케일 표시명 — 식별은 uid로 한다
        public var dissolveName = "교차 디졸브"
        public var crossfadeName = "오디오 크로스페이드"
        /// 클립 이름 앞부분
        public var clipNamePrefix = "설교"
        /// 챕터 마커: (원본 기준 초, 제목)
        public var chapterMarkers: [(sourceSeconds: Double, title: String)] = []

        public init(eventName: String, projectName: String, audioGainDB: Double) {
            self.eventName = eventName
            self.projectName = projectName
            self.audioGainDB = audioGainDB
        }
    }

    public static let crossDissolveUID = "FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"
    public static let audioCrossfadeUID = "FFAudioTransition"

    public init() {}

    public func export(edl: EditDecisionList, videoURL: URL, options: Options) -> String {
        let media = edl.media
        let snap = FrameSnapper(media: media)
        let mediaFrames = Int((media.durationSeconds * media.fps).rounded(.down))
        let usesTransitions = edl.transitions.contains { $0.durationFrames > 0 }
        let src = videoURL.standardizedFileURL.absoluteString

        var formatAttrs = "id=\"r1\""
        if let name = Self.formatName(media) { formatAttrs += " name=\"\(name)\"" }
        formatAttrs += " frameDuration=\"\(snap.frameDurationString)\" width=\"\(media.width)\" height=\"\(media.height)\" colorSpace=\"1-1-1 (Rec. 709)\""

        var assetAttrs = "id=\"r2\" name=\"\(xml(videoURL.deletingPathExtension().lastPathComponent))\" start=\"0s\" duration=\"\(snap.fcpTime(frames: mediaFrames))\" hasVideo=\"1\" format=\"r1\""
        if media.hasAudio {
            assetAttrs += " hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(media.audioChannels ?? 2)\" audioRate=\"\(media.audioSampleRate ?? 48000)\""
        }
        assetAttrs += " videoSources=\"1\""

        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<!DOCTYPE fcpxml>")
        lines.append("")
        lines.append("<fcpxml version=\"1.14\">")
        lines.append("    <resources>")
        lines.append("        <format \(formatAttrs)/>")
        lines.append("        <asset \(assetAttrs)>")
        lines.append("            <media-rep kind=\"original-media\" src=\"\(xml(src))\"/>")
        lines.append("        </asset>")
        if usesTransitions {
            lines.append("        <effect id=\"r3\" name=\"\(xml(options.dissolveName))\" uid=\"\(Self.crossDissolveUID)\"/>")
            lines.append("        <effect id=\"r4\" name=\"\(xml(options.crossfadeName))\" uid=\"\(Self.audioCrossfadeUID)\"/>")
        }
        lines.append("    </resources>")
        lines.append("    <library>")
        lines.append("        <event name=\"\(xml(options.eventName))\">")
        lines.append("            <project name=\"\(xml(options.projectName))\">")
        lines.append("                <sequence format=\"r1\" duration=\"\(snap.fcpTime(frames: edl.totalFrames))\" tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">")
        lines.append("                    <spine>")

        let markersByClip = chapterMarkersByClip(edl: edl, options: options)
        let gain = options.audioGainDB
        for (i, clip) in edl.clips.enumerated() {
            let name = "\(options.clipNamePrefix) \(i + 1) (\(Timecode.format(snap.seconds(clip.sourceStartFrame), millis: false)))"
            let attrs = "ref=\"r2\" offset=\"\(snap.fcpTime(frames: clip.timelineOffsetFrame))\" name=\"\(xml(name))\" start=\"\(snap.fcpTime(frames: clip.sourceStartFrame))\" duration=\"\(snap.fcpTime(frames: clip.durationFrames))\" tcFormat=\"NDF\" audioRole=\"dialogue\""
            let markers = markersByClip[i] ?? []
            if abs(gain) < 0.001 && markers.isEmpty {
                lines.append("                        <asset-clip \(attrs)/>")
            } else {
                lines.append("                        <asset-clip \(attrs)>")
                // DTD 순서: intrinsic-params(adjust-volume) → marker_item(chapter-marker)
                if abs(gain) >= 0.001 {
                    lines.append("                            <adjust-volume amount=\"\(Self.decibels(gain))\"/>")
                }
                for m in markers {
                    lines.append("                            <chapter-marker start=\"\(snap.fcpTime(frames: m.frame))\" duration=\"\(snap.frameDurationString)\" value=\"\(xml(m.title))\" posterOffset=\"0s\"/>")
                }
                lines.append("                        </asset-clip>")
            }
            if let t = edl.transitions.first(where: { $0.afterClip == i }), t.durationFrames > 0 {
                let edit = (clip.timelineOffsetFrame + clip.durationFrames) * media.frameDurationValue
                let half = t.durationFrames * media.frameDurationValue / 2
                lines.append("                        <transition name=\"\(xml(options.dissolveName))\" offset=\"\(snap.fcpTime(value: edit - half))\" duration=\"\(snap.fcpTime(frames: t.durationFrames))\">")
                lines.append("                            <filter-video ref=\"r3\" name=\"\(xml(options.dissolveName))\"/>")
                lines.append("                            <filter-audio ref=\"r4\" name=\"\(xml(options.crossfadeName))\"/>")
                lines.append("                        </transition>")
            }
        }

        lines.append("                    </spine>")
        lines.append("                </sequence>")
        lines.append("            </project>")
        lines.append("        </event>")
        lines.append("    </library>")
        lines.append("</fcpxml>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 챕터 마커 위치: 클립 안의 원본 프레임(asset-clip 시간축은 원본 시간)
    private func chapterMarkersByClip(edl: EditDecisionList, options: Options) -> [Int: [(frame: Int, title: String)]] {
        let snap = FrameSnapper(media: edl.media)
        var result: [Int: [(frame: Int, title: String)]] = [:]
        for m in options.chapterMarkers {
            let f = snap.frame(m.sourceSeconds)
            // 삭제 구간이면 다음 클립 시작으로
            guard let idx = edl.clips.firstIndex(where: { f < $0.sourceEndFrame }) else { continue }
            let clip = edl.clips[idx]
            result[idx, default: []].append((max(f, clip.sourceStartFrame), m.title))
        }
        return result
    }

    static func formatName(_ m: MediaInfo) -> String? {
        let label: String
        switch (m.frameRateNum, m.frameRateDen) {
        case (24, 1): label = "24"
        case (25, 1): label = "25"
        case (30, 1): label = "30"
        case (50, 1): label = "50"
        case (60, 1): label = "60"
        case (24000, 1001): label = "2398"
        case (30000, 1001): label = "2997"
        case (60000, 1001): label = "5994"
        default: return nil
        }
        switch (m.width, m.height) {
        case (1920, 1080): return "FFVideoFormat1080p\(label)"
        case (1280, 720): return "FFVideoFormat720p\(label)"
        case (3840, 2160): return "FFVideoFormat3840x2160p\(label)"
        default: return nil
        }
    }

    static func decibels(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))dB" : String(format: "%.1fdB", v)
    }

    func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
