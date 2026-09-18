import Foundation

/// EDL → mp4 (SPEC §6.5)
///
/// FCP와 같은 방식으로 디졸브를 만든다: 편집점 양쪽 클립을 전환 길이의 절반씩 늘려(핸들) 겹치게 하므로
/// 결과 길이가 FCPXML과 같다(docs/fcpxml-reference.md §5). 클립마다 `-ss/-t` 입력 탐색을 써서 원본 전체를 디코딩하지 않는다.
public struct FFmpegRenderer: Sendable {
    public enum Preset: String, Sendable, CaseIterable {
        /// 컷 타이밍 검수용: 960x540, libx264 crf 28 veryfast
        case preview
        /// Compressor "MP4 5,000kbps" 설정과 같게: 원본 해상도, H.264 Main 5Mbps CBR(VideoToolbox), AAC 128k
        case final
    }

    public struct Options: Sendable {
        public var preset: Preset
        public var audioGainDB: Double
        /// 첫 클립 앞 검정에서 페이드인 / 마지막 클립 뒤 페이드아웃 (초, 0이면 없음)
        public var fadeIn: Double = 0
        public var fadeOut: Double = 0
        /// 커버 이미지(썸네일) — final에서만 첨부
        public var coverImage: URL?
        /// 인트로(썸네일+음악)·아웃트로(끝 화면+음악) — FCPXML과 같은 구성 (Phase 6)
        public var bookends: FCPXMLExporter.Bookends?
        public init(preset: Preset, audioGainDB: Double) {
            self.preset = preset
            self.audioGainDB = audioGainDB
        }
    }

    public var locator: BinaryLocator
    public init(locator: BinaryLocator = BinaryLocator()) { self.locator = locator }

    /// - Returns: 결과 길이(초)
    @discardableResult
    public func render(edl: EditDecisionList, video: URL, output: URL, options: Options, workDirectory: URL,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> Double {
        let ffmpeg = try locator.url(for: .ffmpeg)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let plan = Self.plan(edl: edl, options: options)
        let script = workDirectory.appendingPathComponent("filter_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: script) }

        var args = ["-nostdin", "-hide_banner", "-v", "error", "-y"]
        let fps = "\(edl.media.frameRateNum)/\(edl.media.frameRateDen)"
        for input in plan.inputs {
            switch input.kind {
            case .video:
                args += ["-ss", String(format: "%.6f", input.start), "-t", String(format: "%.6f", input.duration), "-i", video.path]
            case .still(let image, let audio):
                args += ["-loop", "1", "-framerate", fps, "-t", String(format: "%.6f", input.duration), "-i", image.path]
                args += ["-i", audio.path]
            }
        }
        var filter = plan.filter
        let hasCover = options.preset == .final && options.coverImage != nil
        if hasCover, let cover = options.coverImage {
            args += ["-i", cover.path]
            // 커버를 영상 해상도로 (Compressor 결과물과 같게 1920x1080)
            filter += ";\n[\(plan.inputCount):v]scale=\(edl.media.width):\(edl.media.height):force_original_aspect_ratio=decrease,pad=\(edl.media.width):\(edl.media.height):(ow-iw)/2:(oh-ih)/2,setsar=1[cover]"
        }
        try filter.write(to: script, atomically: true, encoding: .utf8)
        // ffmpeg 7부터 -filter_complex_script 대신 "-/옵션 파일" 형식 (명령행 길이 제한 회피, SPEC §6.5)
        args += ["-/filter_complex", script.path, "-map", "[vout]", "-map", "[aout]"]
        switch options.preset {
        case .preview:
            args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "28", "-pix_fmt", "yuv420p",
                     "-c:a", "aac", "-b:a", "96k"]
        case .final:
            // 영상 스트림(0)에만 적용되도록 스트림 지정자를 붙인다 — 커버(mjpeg)에 main 프로필이 걸리면 실패
            args += ["-c:v:0", "h264_videotoolbox", "-profile:v:0", "main", "-b:v:0", "5000k", "-constant_bit_rate", "1",
                     "-pix_fmt:v:0", "yuv420p", "-color_primaries:v:0", "bt709", "-color_trc:v:0", "bt709", "-colorspace:v:0", "bt709",
                     "-c:a", "aac", "-b:a", "128k", "-ar", "48000"]
            if hasCover {
                args += ["-map", "[cover]", "-c:v:1", "mjpeg", "-disposition:v:1", "attached_pic"]
            }
        }
        args += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]

        let total = plan.duration
        try await ProcessRunner.run(ffmpeg, args, toolName: "ffmpeg", onStdoutLine: { line in
            guard let progress, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            progress(min(1, us / 1_000_000 / total))
        })
        return total
    }

    // MARK: - 필터 그래프 (테스트 가능하도록 분리)

    public struct Plan: Sendable {
        public enum Kind: Sendable { case video, still(image: URL, audio: URL) }
        public struct Input: Sendable { public var start: Double; public var duration: Double; public var kind: Kind = .video }
        public var inputs: [Input]
        public var filter: String
        public var duration: Double
        /// ffmpeg 입력 파일 수 (정지 화면은 이미지+음악 2개)
        public var inputCount: Int {
            inputs.reduce(0) { n, i in if case .still = i.kind { return n + 2 } else { return n + 1 } }
        }
    }

    public static func plan(edl: EditDecisionList, options: Options) -> Plan {
        let media = edl.media
        let snap = FrameSnapper(media: media)
        let fps = "\(media.frameRateNum)/\(media.frameRateDen)"
        let size = options.preset == .preview ? "960:540" : "\(media.width):\(media.height)"
        let b = options.bookends

        // 항목: [인트로] + 설교 클립들 + [아웃트로], 사이 전환(프레임, xfade 종류)
        enum Item { case clip(EDLClip), still(URL, URL, Int) }
        var items: [Item] = []
        var trans: [(frames: Int, kind: String)] = []
        if let b {
            items.append(.still(b.thumbnail.url, b.introAudio.url, snap.frame(b.introSeconds)))
            trans.append((HandleValidator.evenFrames(snap.frame(b.introFadeSeconds)), "fadeblack"))
        }
        for (i, c) in edl.clips.enumerated() {
            items.append(.clip(c))
            if i < edl.clips.count - 1 { trans.append((edl.transitions.first { $0.afterClip == i }?.durationFrames ?? 0, "fade")) }
        }
        if let b {
            trans.append((HandleValidator.evenFrames(snap.frame(b.outroFadeSeconds)), "fadeblack"))
            items.append(.still(b.endPoster.url, b.outroAudio.url, snap.frame(b.posterSeconds)))
        }

        var inputs: [Plan.Input] = []
        var lines: [String] = []
        var ffIndex = 0
        for (i, item) in items.enumerated() {
            // 핸들: 앞 전환의 절반만큼 앞으로, 뒤 전환의 절반만큼 뒤로 늘린다 (FCP와 같음)
            let head = i > 0 ? trans[i - 1].frames / 2 : 0
            let tail = i < trans.count ? trans[i].frames / 2 : 0
            let vchain = "setpts=PTS-STARTPTS,fps=\(fps),scale=\(size):force_original_aspect_ratio=decrease,pad=\(size):(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p,settb=AVTB"
            switch item {
            case .clip(let c):
                let dur = snap.seconds(c.durationFrames + head + tail)
                inputs.append(.init(start: snap.seconds(c.sourceStartFrame - head), duration: dur))
                lines.append("[\(ffIndex):v]\(vchain)[v\(i)]")
                lines.append("[\(ffIndex):a]asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,volume=\(options.audioGainDB)dB[a\(i)]")
                ffIndex += 1
            case .still(let image, let audio, let frames):
                let dur = snap.seconds(frames + head + tail)
                inputs.append(.init(start: 0, duration: dur, kind: .still(image: image, audio: audio)))
                lines.append("[\(ffIndex):v]\(vchain)[v\(i)]")
                // 음악은 정지 화면 구간 시작부터 (앞 핸들만큼 늦게), 길이를 화면에 맞춤
                let delayMs = Int((snap.seconds(head) * 1000).rounded())
                lines.append("[\(ffIndex + 1):a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,adelay=\(delayMs)|\(delayMs),apad,atrim=0:\(fmt(dur)),asetpts=PTS-STARTPTS[a\(i)]")
                ffIndex += 2
            }
        }

        // 체인: 늘린 길이 기준 누적 길이 L. 전환은 offset = L − d, 결과 길이 = L + len − d
        var vPrev = "v0", aPrev = "a0"
        var L = inputs.first?.duration ?? 0
        for i in 1..<max(1, items.count) {
            let d = snap.seconds(trans[i - 1].frames)
            let vOut = "vx\(i)", aOut = "ax\(i)"
            if d > 0 {
                lines.append("[\(vPrev)][v\(i)]xfade=transition=\(trans[i - 1].kind):duration=\(fmt(d)):offset=\(fmt(L - d))[\(vOut)]")
                lines.append("[\(aPrev)][a\(i)]acrossfade=d=\(fmt(d)):c1=tri:c2=tri[\(aOut)]")
                L += inputs[i].duration - d
            } else {
                lines.append("[\(vPrev)][v\(i)]concat=n=2:v=1:a=0[\(vOut)]")
                lines.append("[\(aPrev)][a\(i)]concat=n=2:v=0:a=1[\(aOut)]")
                L += inputs[i].duration
            }
            vPrev = vOut; aPrev = aOut
        }
        var vf: [String] = [], af: [String] = []
        let fadeIn = b.map { $0.edgeDissolveSeconds } ?? options.fadeIn
        let fadeOut = b.map { $0.edgeDissolveSeconds } ?? options.fadeOut
        if fadeIn > 0 { vf.append("fade=t=in:st=0:d=\(fmt(fadeIn))"); af.append("afade=t=in:st=0:d=\(fmt(fadeIn))") }
        if fadeOut > 0 {
            vf.append("fade=t=out:st=\(fmt(L - fadeOut)):d=\(fmt(fadeOut))")
            af.append("afade=t=out:st=\(fmt(L - fadeOut)):d=\(fmt(fadeOut))")
        }
        lines.append("[\(vPrev)]\(vf.isEmpty ? "null" : vf.joined(separator: ","))[vout]")
        lines.append("[\(aPrev)]\(af.isEmpty ? "anull" : af.joined(separator: ","))[aout]")
        return Plan(inputs: inputs, filter: lines.joined(separator: ";\n"), duration: L)
    }

    static func fmt(_ v: Double) -> String { String(format: "%.6f", v) }
}
