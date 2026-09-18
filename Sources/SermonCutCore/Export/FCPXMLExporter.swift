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
        /// 인트로/아웃트로 (Phase 6) — nil이면 설교 클립만
        public var bookends: Bookends?

        public init(eventName: String, projectName: String, audioGainDB: Double) {
            self.eventName = eventName
            self.projectName = projectName
            self.audioGainDB = audioGainDB
        }
    }

    public static let crossDissolveUID = "FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"
    public static let audioCrossfadeUID = "FFAudioTransition"
    public static let fadeToColorUID = "FxPlug:F779C565-486D-4633-8035-0374B4DB8F5C"

    /// 09/13 완성본과 같은 앞뒤 구성 (docs/fcpxml-reference.md §3)
    public struct Bookends: Sendable {
        public struct Still: Sendable { public var url: URL; public var width: Int; public var height: Int
            public init(url: URL, width: Int, height: Int) { self.url = url; self.width = width; self.height = height } }
        public struct Audio: Sendable { public var url: URL; public var duration: Double; public var sampleRate: Int; public var channels: Int
            public init(url: URL, duration: Double, sampleRate: Int, channels: Int) {
                self.url = url; self.duration = duration; self.sampleRate = sampleRate; self.channels = channels } }
        public var thumbnail: Still
        public var introAudio: Audio
        public var endPoster: Still
        public var outroAudio: Audio
        // 프레임 수 (30fps 기준 실측값을 초로 저장 → 매체 fps로 변환)
        public var introSeconds = 302.0 / 30          // 10.067초
        public var posterSeconds = 441.0 / 30         // 14.7초
        public var introFadeSeconds = 74.0 / 30       // 색상으로 페이드 2.467초
        public var outroFadeSeconds = 48.0 / 30       // 색상으로 페이드 1.6초
        public var edgeDissolveSeconds = 1.0          // 처음 페이드인·끝 페이드아웃
        public var outroLeadSeconds = 6.0 / 30        // 아웃트로 음악이 마지막 클립 끝보다 먼저 시작
        public var fadeName = "색상으로 페이드"
        public init(thumbnail: Still, introAudio: Audio, endPoster: Still, outroAudio: Audio) {
            self.thumbnail = thumbnail; self.introAudio = introAudio; self.endPoster = endPoster; self.outroAudio = outroAudio
        }
    }

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
        if usesTransitions || options.bookends != nil {
            lines.append("        <effect id=\"r3\" name=\"\(xml(options.dissolveName))\" uid=\"\(Self.crossDissolveUID)\"/>")
            lines.append("        <effect id=\"r4\" name=\"\(xml(options.crossfadeName))\" uid=\"\(Self.audioCrossfadeUID)\"/>")
        }
        if let b = options.bookends {
            lines.append("        <effect id=\"r5\" name=\"\(xml(b.fadeName))\" uid=\"\(Self.fadeToColorUID)\"/>")
            lines.append("        <format id=\"r6\" name=\"FFVideoFormatRateUndefined\" width=\"\(b.thumbnail.width)\" height=\"\(b.thumbnail.height)\"/>")
            lines.append("        <asset id=\"r7\" name=\"\(xml(b.thumbnail.url.deletingPathExtension().lastPathComponent))\" start=\"0s\" duration=\"0s\" hasVideo=\"1\" format=\"r6\" videoSources=\"1\">")
            lines.append("            <media-rep kind=\"original-media\" src=\"\(xml(b.thumbnail.url.standardizedFileURL.absoluteString))\"/>")
            lines.append("        </asset>")
            lines.append("        <format id=\"r8\" name=\"FFVideoFormatRateUndefined\" width=\"\(b.endPoster.width)\" height=\"\(b.endPoster.height)\"/>")
            lines.append("        <asset id=\"r9\" name=\"\(xml(b.endPoster.url.deletingPathExtension().lastPathComponent))\" start=\"0s\" duration=\"0s\" hasVideo=\"1\" format=\"r8\" videoSources=\"1\">")
            lines.append("            <media-rep kind=\"original-media\" src=\"\(xml(b.endPoster.url.standardizedFileURL.absoluteString))\"/>")
            lines.append("        </asset>")
            lines.append("        <format id=\"r10\" name=\"FFVideoFormatRateUndefined\"/>")
            for (id, a) in [("r11", b.introAudio), ("r12", b.outroAudio)] {
                let samples = Int((a.duration * Double(a.sampleRate)).rounded(.down))
                lines.append("        <asset id=\"\(id)\" name=\"\(xml(a.url.deletingPathExtension().lastPathComponent))\" start=\"0s\" duration=\"\(samples)/\(a.sampleRate)s\" hasAudio=\"1\" audioSources=\"1\" audioChannels=\"\(a.channels)\" audioRate=\"\(a.sampleRate)\">")
                lines.append("            <media-rep kind=\"original-media\" src=\"\(xml(a.url.standardizedFileURL.absoluteString))\"/>")
                lines.append("        </asset>")
            }
        }
        lines.append("    </resources>")
        lines.append("    <library>")
        lines.append("        <event name=\"\(xml(options.eventName))\">")
        lines.append("            <project name=\"\(xml(options.projectName))\">")
        // 인트로가 있으면 설교 클립을 그만큼 뒤로 민다
        let b = options.bookends
        let introFrames = b.map { snap.frame($0.introSeconds) } ?? 0
        let posterFrames = b.map { snap.frame($0.posterSeconds) } ?? 0
        let outroFrames = b.map { snap.frame($0.outroAudio.duration) } ?? 0
        let outroLead = b.map { snap.frame($0.outroLeadSeconds) } ?? 0
        let sermonEnd = introFrames + edl.totalFrames
        let totalFrames = b == nil ? edl.totalFrames : max(sermonEnd + posterFrames, sermonEnd - outroLead + outroFrames)
        lines.append("                <sequence format=\"r1\" duration=\"\(snap.fcpTime(frames: totalFrames))\" tcStart=\"0s\" tcFormat=\"NDF\" audioLayout=\"stereo\" audioRate=\"48k\">")
        lines.append("                    <spine>")
        let stillStart = "3600s"
        func transition(_ name: String, ref: String, offsetValue: Int, frames: Int, audio: Bool) {
            lines.append("                        <transition name=\"\(xml(name))\" offset=\"\(snap.fcpTime(value: offsetValue))\" duration=\"\(snap.fcpTime(frames: frames))\">")
            lines.append("                            <filter-video ref=\"\(ref)\" name=\"\(xml(name))\"/>")
            if audio { lines.append("                            <filter-audio ref=\"r4\" name=\"\(xml(options.crossfadeName))\"/>") }
            lines.append("                        </transition>")
        }
        let fdv = media.frameDurationValue
        if let b {
            let edge = HandleValidator.evenFrames(snap.frame(b.edgeDissolveSeconds))
            let introFade = HandleValidator.evenFrames(snap.frame(b.introFadeSeconds))
            transition(options.dissolveName, ref: "r3", offsetValue: 0, frames: edge, audio: false)
            lines.append("                        <video ref=\"r7\" offset=\"0s\" start=\"\(stillStart)\" duration=\"\(snap.fcpTime(frames: introFrames))\">")
            lines.append("                            <asset-clip ref=\"r11\" lane=\"-1\" offset=\"\(stillStart)\" name=\"\(xml(b.introAudio.url.deletingPathExtension().lastPathComponent))\" duration=\"\(snap.fcpTime(frames: min(introFrames, snap.frame(b.introAudio.duration))))\" format=\"r10\" audioRole=\"dialogue\"/>")
            lines.append("                        </video>")
            transition(b.fadeName, ref: "r5", offsetValue: (introFrames - introFade / 2) * fdv, frames: introFade, audio: false)
        }

        let markersByClip = chapterMarkersByClip(edl: edl, options: options)
        let gain = options.audioGainDB
        for (i, clip) in edl.clips.enumerated() {
            let name = "\(options.clipNamePrefix) \(i + 1) (\(Timecode.format(snap.seconds(clip.sourceStartFrame), millis: false)))"
            let attrs = "ref=\"r2\" offset=\"\(snap.fcpTime(frames: clip.timelineOffsetFrame + introFrames))\" name=\"\(xml(name))\" start=\"\(snap.fcpTime(frames: clip.sourceStartFrame))\" duration=\"\(snap.fcpTime(frames: clip.durationFrames))\" tcFormat=\"NDF\" audioRole=\"dialogue\""
            let markers = markersByClip[i] ?? []
            let isLast = i == edl.clips.count - 1
            let outro: String? = (isLast ? b : nil).map { b in
                // 연결 클립 offset은 부모 클립의 원본 시간축 기준 (docs/fcpxml-reference.md §3-5)
                "<asset-clip ref=\"r12\" lane=\"-1\" offset=\"\(snap.fcpTime(frames: clip.sourceEndFrame - outroLead))\" name=\"\(xml(b.outroAudio.url.deletingPathExtension().lastPathComponent))\" duration=\"\(snap.fcpTime(frames: outroFrames))\" format=\"r10\" audioRole=\"dialogue\"/>"
            }
            if abs(gain) < 0.001 && markers.isEmpty && outro == nil {
                lines.append("                        <asset-clip \(attrs)/>")
            } else {
                lines.append("                        <asset-clip \(attrs)>")
                // DTD 순서: intrinsic-params(adjust-volume) → marker_item(chapter-marker)
                if abs(gain) >= 0.001 {
                    lines.append("                            <adjust-volume amount=\"\(Self.decibels(gain))\"/>")
                }
                // DTD 순서: intrinsic-params → anchor_item(연결 클립) → marker_item
                if let outro { lines.append("                            " + outro) }
                for m in markers {
                    lines.append("                            <chapter-marker start=\"\(snap.fcpTime(frames: m.frame))\" duration=\"\(snap.frameDurationString)\" value=\"\(xml(m.title))\" posterOffset=\"0s\"/>")
                }
                lines.append("                        </asset-clip>")
            }
            if let t = edl.transitions.first(where: { $0.afterClip == i }), t.durationFrames > 0 {
                let edit = (clip.timelineOffsetFrame + clip.durationFrames + introFrames) * media.frameDurationValue
                let half = t.durationFrames * media.frameDurationValue / 2
                lines.append("                        <transition name=\"\(xml(options.dissolveName))\" offset=\"\(snap.fcpTime(value: edit - half))\" duration=\"\(snap.fcpTime(frames: t.durationFrames))\">")
                lines.append("                            <filter-video ref=\"r3\" name=\"\(xml(options.dissolveName))\"/>")
                lines.append("                            <filter-audio ref=\"r4\" name=\"\(xml(options.crossfadeName))\"/>")
                lines.append("                        </transition>")
            }
        }

        if let b {
            let outroFade = HandleValidator.evenFrames(snap.frame(b.outroFadeSeconds))
            let edge = HandleValidator.evenFrames(snap.frame(b.edgeDissolveSeconds))
            transition(b.fadeName, ref: "r5", offsetValue: (sermonEnd - outroFade / 2) * fdv, frames: outroFade, audio: false)
            lines.append("                        <video ref=\"r9\" offset=\"\(snap.fcpTime(frames: sermonEnd))\" start=\"\(stillStart)\" duration=\"\(snap.fcpTime(frames: posterFrames))\"/>")
            transition(options.dissolveName, ref: "r3", offsetValue: (sermonEnd + posterFrames - edge) * fdv, frames: edge, audio: false)
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
