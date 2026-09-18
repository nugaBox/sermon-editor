import Foundation

/// 설교 목차(유튜브 챕터) 만들기 (SPEC §6.6)
///
/// 제목 출처: 붙여넣기 > 원고 소제목 > 화면 목차 박스
/// 시간 출처: 화면 목차 강조 전환 > 원고 정렬 > 전사문 유사도 (둘 이상이면 교차 검증)
/// 출력 시간 = 결과 영상 기준(인트로 길이 포함), 첫 줄은 항상 "00:00 성경봉독"
public enum ChapterBuilder {
    public struct Options: Codable, Sendable, Equatable {
        /// 결과 영상 앞에 붙는 인트로(썸네일) 길이 — 09/13 템플릿 10.067초
        public var introDuration: Double = 10.067
        public var firstLine: String? = "성경봉독"
        /// 사용자가 붙여넣은 목차 (줄 단위)
        public var pastedOutline: String?
        /// 편집점에서 이 시간 안이면 편집점으로 붙인다
        public var snapToEdit: Double = 1.0
        /// 두 시간 출처가 이보다 크게 다르면 ⚠
        public var disagreementWarning: Double = 20
        /// 화면 목차는 방송 담당자가 설교자 말을 듣고 바꾸므로 실제보다 늦다 (09/13 실측 약 3초)
        public var overlayLag: Double = 3
        /// 첫 대지는 설교 시작점에서 시작한다고 보고, 이 시간 안이면 앞의 편집점(설교 시작)으로 붙인다
        public var firstChapterSnap: Double = 30
        public init() {}
    }

    public enum TimeSource: String, Codable, Sendable { case overlay = "화면", manuscript = "원고", transcript = "전사문", manual = "직접", none = "없음" }

    public struct Chapter: Codable, Sendable, Equatable, Identifiable {
        public var id: Int { number }
        public var number: Int
        public var title: String
        public var titleSource: String
        /// 원본 기준 시작 (nil = 못 찾음)
        public var sourceTime: Double?
        public var timeSource: TimeSource
        /// 결과 영상 기준 (인트로 포함)
        public var outputTime: Double?
        public var warning: String?
    }

    // MARK: - 화면 목차 강조 전환

    public struct OverlayChange: Codable, Sendable, Equatable {
        public var number: Int
        public var title: String
        public var time: Double
    }

    /// 목차 박스(화면 오른쪽 아래) 줄들 중 가장 밝은 줄 = 현재 대지. 번호가 바뀌는 시점을 찾는다.
    public static func overlayChanges(_ scan: ScreenTextScan, within range: TimeRange? = nil) -> [OverlayChange] {
        var current: [(time: Double, number: Int)] = []
        var titles: [Int: [String]] = [:]
        for s in scan.samples where range.map({ $0.contains(s.time) }) ?? true {
            var items: [(n: Int, title: String, b: Double)] = []
            for l in s.lines where l.x > 0.6 && l.y < 0.5 {
                let t = l.text.trimmingCharacters(in: .whitespaces)
                guard let r = t.range(of: #"^(\d{1,2})\s*[.)]\s*"#, options: .regularExpression),
                      let n = Int(t[r].filter(\.isNumber)), let b = l.brightness else { continue }
                let title = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                items.append((n, title, b))
                titles[n, default: []].append(title)
            }
            guard items.count >= 2 else { continue }
            let sorted = items.sorted { $0.b > $1.b }
            // 가장 밝은 줄이 두 번째보다 뚜렷이 밝을 때만 (0.12 = 흰색 vs 회색 실측 차이의 절반 정도)
            guard sorted[0].b - sorted[1].b > 0.12 else { continue }
            current.append((s.time, sorted[0].n))
        }
        // 번호가 커지는 시점만 (역행·잡음 무시), 같은 번호가 2장 이상 이어질 때 인정
        var changes: [OverlayChange] = []
        var last = 0
        for (i, c) in current.enumerated() where c.number > last {
            let confirmed = i + 1 < current.count ? current[i + 1].number == c.number : true
            guard confirmed else { continue }
            let title = Dictionary((titles[c.number] ?? []).map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key ?? ""
            changes.append(OverlayChange(number: c.number, title: title, time: c.time))
            last = c.number
        }
        return changes
    }

    /// 거친 스캔에서 찾은 전환 시점 앞뒤를 1초 간격으로 다시 봐서 정확한 전환 시각을 구한다
    public static func refineOverlayChanges(_ changes: [OverlayChange], coarse: ScreenTextScan, video: URL) async throws -> [OverlayChange] {
        var times = Set<Double>()
        for c in changes {
            for dt in stride(from: -coarse.interval, through: 0, by: 1) { times.insert((c.time + dt).rounded()) }
        }
        let fine = try await ScreenTextScanner(interval: 1).scan(video: video, times: times.sorted())
        let merged = ScreenTextScan(interval: 1, samples: (coarse.samples + fine).sorted { $0.time < $1.time })
        var refined = changes
        for i in refined.indices {
            let c = refined[i]
            let window = TimeRange(start: c.time - coarse.interval - 0.5, end: c.time + 0.5)
            // 창 안에서 해당 번호가 처음 강조된 시각
            if let first = overlayChanges(merged, within: TimeRange(start: window.start - 60, end: window.end))
                .first(where: { $0.number == c.number && window.contains($0.time) }) {
                refined[i].time = first.time
            }
        }
        return refined
    }

    // MARK: - 결합

    /// 프로젝트에 저장된 값(붙여넣기·화면 목차·직접 수정)으로 만든다
    public static func build(project p: SermonProject, edl: EditDecisionList?, options: Options = Options()) -> [Chapter] {
        var o = options
        if o.pastedOutline == nil { o.pastedOutline = p.chapterOutlineText }
        return build(project: p, edl: edl, overlay: p.overlayChanges ?? [], overlayOutline: p.screenOutline ?? [], options: o)
    }

    public static func build(project p: SermonProject, edl: EditDecisionList?, overlay: [OverlayChange],
                             overlayOutline: [String] = [], options: Options = Options()) -> [Chapter] {
        // 제목
        var titles: [(String, String)] = []
        if let pasted = options.pastedOutline, !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            titles = parseOutline(pasted).map { ($0, "붙여넣기") }
        } else if let h = p.manuscript?.headings, !h.isEmpty {
            titles = h.map { ($0.title, "원고") }
        } else if !overlayOutline.isEmpty {
            titles = parseOutline(overlayOutline.joined(separator: "\n")).map { ($0, "화면") }
        } else if !overlay.isEmpty {
            titles = overlay.map { ($0.title, "화면") }
        }

        let manuscriptTimes = ChapterMarkers.fromManuscript(p)
        let segs = p.segments.filter { !$0.isRemoved }
        var chapters: [Chapter] = []
        var lastTime = p.sourceRange.start
        for (i, (title, src)) in titles.enumerated() {
            let n = i + 1
            let ov = overlay.first { $0.number == n }?.time
            // 원고 시간은 같은 번호의 소제목일 때만
            let ms = (src == "원고" || p.manuscript?.headings.count == titles.count) ? manuscriptTimes.first { $0.title.hasPrefix("\(n). ") }?.sourceSeconds : nil
            let tr = transcriptTime(title, segs, after: lastTime)
            // 화면 시간은 반응 지연만큼 당기고, 가장 가까운 말 시작(±4초)에 맞춘다
            let ovAdjusted = ov.map { t -> Double in
                let target = t - options.overlayLag
                let near = segs.filter { abs($0.start - target) <= 4 }.min { abs($0.start - target) < abs($1.start - target) }
                return near?.start ?? target
            }
            var time: Double?
            var source = TimeSource.none
            // 원고 시간이 가장 정확(대지 첫 문장을 말한 시점). 화면과 30초 넘게 어긋나면 원고 매칭 실수로 보고 화면을 쓴다
            if let ms, ov.map({ abs($0 - ms) <= 30 }) ?? true { time = ms; source = .manuscript }
            else if let ovAdjusted { time = ovAdjusted; source = .overlay }
            else if let tr { time = tr; source = .transcript }
            var warning: String?
            if let ov, let ms, abs(ov - ms) > options.disagreementWarning {
                warning = String(format: "화면(%@)과 원고(%@) 시간이 %.0f초 다름", Timecode.format(ov, millis: false),
                                 Timecode.format(ms, millis: false), abs(ov - ms))
            }
            if let manual = p.chapterTimeOverrides?[n] { time = manual; source = .manual; warning = nil }
            if time == nil { warning = "시작 위치를 찾지 못함 — 직접 지정해 주세요" }
            if let t = time { lastTime = t }
            var opts = options
            if n == 1 { opts.snapToEdit = options.firstChapterSnap }
            chapters.append(Chapter(number: n, title: title, titleSource: src, sourceTime: time, timeSource: source,
                                    outputTime: time.flatMap { outputTime($0, edl: edl, options: opts, backwardOnly: n == 1) }, warning: warning))
        }
        return chapters
    }

    /// 원본 시간 → 결과 영상 시간 (인트로 포함, 편집점 스냅, 초 단위 내림)
    public static func outputTime(_ source: Double, edl: EditDecisionList?, options: Options, backwardOnly: Bool = false) -> Double? {
        guard let edl else { return nil }
        let snap = FrameSnapper(media: edl.media)
        var t = source
        // 편집점 스냅: 클립 시작 ±snapToEdit 안이면 클립 시작 (첫 대지는 앞쪽 편집점으로만)
        for c in edl.clips {
            let start = snap.seconds(c.sourceStartFrame)
            let d = t - start
            if backwardOnly ? (d >= 0 && d <= options.snapToEdit) : abs(d) <= options.snapToEdit { t = start; break }
        }
        guard let out = edl.timelineSeconds(forSource: t) else { return nil }
        return (out + options.introDuration).rounded(.down)
    }

    /// 제목을 소리 내어 읽은 세그먼트 (bigram 포함도 0.5 이상, 가장 이른 것)
    static func transcriptTime(_ title: String, _ segs: [TranscriptSegment], after: Double) -> Double? {
        let g = TextNormalizer.bigrams(title)
        guard g.count >= 3 else { return nil }
        for s in segs where s.start >= after {
            let sg = TextNormalizer.bigrams(s.text)
            if Double(g.intersection(sg).count) / Double(g.count) >= 0.5 { return s.start }
        }
        return nil
    }

    /// "03:45 1. 제목", "1) 제목", "첫째, 제목" 등에서 제목만
    public static func parseOutline(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { line in
            var t = line.trimmingCharacters(in: .whitespaces)
            t = t.replacingOccurrences(of: #"^\d{1,2}:\d{2}(:\d{2})?\s*"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"^(\(?\d{1,2}[.)]|[①-⑩]|[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ][.)]?|(첫|둘|셋|넷|다섯|여섯)째\s*[,.]?)\s*"#,
                                       with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"^\*+\s*"#, with: "", options: .regularExpression)
            t = t.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t != "성경봉독", t != "성경 봉독" else { return nil }
            return t
        }
    }

    /// 유튜브 설명란용 텍스트
    public static func youtubeText(_ chapters: [Chapter], options: Options) -> String {
        var lines: [String] = []
        if let first = options.firstLine { lines.append("00:00 \(first)") }
        for c in chapters {
            guard let t = c.outputTime else { continue }
            lines.append("\(clock(t)) \(c.number). \(c.title)")
        }
        return lines.joined(separator: "\n")
    }

    public static func clock(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

extension ChapterBuilder {
    /// 설교 구간을 스캔해 화면 목차 전환과 목차 항목을 프로젝트에 저장 (결과 캐시)
    public static func scanOverlay(_ p: SermonProject, cacheDirectory: URL?,
                                   progress: (@Sendable (Double) -> Void)? = nil) async throws -> SermonProject {
        var p = p
        let video = URL(fileURLWithPath: p.videoPath)
        let coarse = try await ScreenTextScanner(interval: 6).scan(video: video, range: p.sourceRange, cacheDirectory: cacheDirectory) { v in
            progress?(v * 0.8)
        }
        let changes = overlayChanges(coarse)
        p.overlayChanges = try await refineOverlayChanges(changes, coarse: coarse, video: video)
        p.screenOutline = RangeFinder.find(screen: coarse, transcript: nil).metadata?.outline
        progress?(1)
        return p
    }
}
