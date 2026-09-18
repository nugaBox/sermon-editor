import Foundation

/// 설교 구간 후보 찾기 (SPEC §6.0 "자동 찾기"). **자동으로 확정하지 않고 후보만 제시한다.**
///
/// 신호 (09/13 실측):
/// - 화면: "대표기도" 하단 자막 → "성경 봉독" 슬라이드(= In) → 설교 하단 자막 → "찬송가" 슬라이드(= Out)
/// - 음성(whisper base 빠른 전사): "…말씀부터 … 읽어드리겠습니다"(= In), "봉헌"(= Out, base 모델은 자주 놓침)
public enum RangeFinder {
    public enum Source: String, Codable, Sendable { case screen = "화면", audio = "음성" }

    public struct Candidate: Codable, Sendable, Equatable {
        public var time: Double
        public var source: Source
        public var label: String
        /// 추천 순위용 점수 (높을수록 유력)
        public var score: Double
    }

    public struct Metadata: Codable, Sendable, Equatable {
        public var title: String?
        public var passage: String?
        public var preacher: String?
        public var serviceLabel: String?
        /// 화면 목차 박스의 항목 ("1. 위기의 순간 드러나는 참신앙" …)
        public var outline: [String] = []
    }

    public struct Keywords: Codable, Sendable, Equatable {
        public var start = ["성경봉독", "말씀봉독", "성경낭독"]
        public var beforeStart = ["대표기도", "대표 기도"]
        public var end = ["봉헌", "헌금", "찬송가", "찬송"]
        public init() {}
    }

    public struct Result: Sendable, Equatable {
        public var starts: [Candidate] = []
        public var ends: [Candidate] = []
        public var suggested: TimeRange?
        public var metadata: Metadata?
        /// 설교 하단 자막이 보인 구간
        public var sermonScreen: TimeRange?
    }

    public static func find(screen: ScreenTextScan?, transcript: [TranscriptSegment]?, keywords: Keywords = Keywords()) -> Result {
        var r = Result()
        let norm: (String) -> String = { $0.replacingOccurrences(of: " ", with: "") }

        // MARK: 화면
        if let screen, !screen.samples.isEmpty {
            let samples = screen.samples
            let step = screen.interval
            // 설교 하단 자막: "설교" + ("본문" 또는 "목사")
            let isSermon: (ScreenTextSample) -> Bool = { s in
                let c = s.compact
                return c.contains("설교") && (c.contains("본문") || c.contains("목사"))
            }
            // 1) 시작: "성경 봉독" 제목 카드가 처음 뜨는 곳.
            //    예배 전 주보 슬라이드(글줄 수십 개) 속 순서표에도 같은 말이 있으므로, 그 말이 한 줄을 차지하는 짧은 화면만 인정
            let isTitleCard: (ScreenTextSample, [String]) -> Bool = { s, words in
                s.lines.count <= 12 && s.lines.contains { l in
                    let t = norm(l.text)
                    return words.contains { t.hasPrefix(norm($0)) && t.count <= norm($0).count + 4 }
                }
            }
            for run in runs(samples, where: { isTitleCard($0, keywords.start) }, gap: step * 3) {
                r.starts.append(Candidate(time: run.lowerBound, source: .screen, label: "‘성경 봉독’ 화면", score: 1.0))
            }
            // 2) 대표기도 자막이 끝나는 곳 (보조)
            for run in runs(samples, where: { isTitleCard($0, keywords.beforeStart) }, gap: step * 3) {
                r.starts.append(Candidate(time: run.upperBound + step, source: .screen, label: "‘대표기도’ 자막 끝", score: 0.6))
            }
            // 3) 설교 자막 구간
            let sermonRuns = runs(samples, where: isSermon, gap: 120)
            let longest = sermonRuns.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
            if let s = longest {
                r.sermonScreen = TimeRange(start: s.lowerBound, end: s.upperBound)
                r.ends.append(Candidate(time: s.upperBound + step / 2, source: .screen, label: "설교 자막이 사라진 곳", score: 1.1))
                // 4) 설교 자막 뒤 처음 나오는 찬송/봉헌 화면
                if let e = samples.first(where: { x in x.time > s.upperBound - step && x.lines.count <= 12 && keywords.end.contains { x.compact.contains(norm($0)) } }) {
                    let word = keywords.end.first { e.compact.contains(norm($0)) } ?? ""
                    r.ends.append(Candidate(time: e.time, source: .screen, label: "‘\(word)’ 화면 (\(e.lines.first?.text ?? ""))", score: 1.0))
                }
                r.metadata = metadata(samples.filter { $0.time >= s.lowerBound && $0.time <= s.upperBound && isSermon($0) }, all: samples, sermon: s)
            }
        }

        // MARK: 음성 (빠른 전사)
        if let transcript {
            let readIntro = #"(읽어\s*드리|읽겠습니다|봉독하겠습니다|말씀을?\s*(함께\s*)?읽)"#
            for s in transcript where s.text.range(of: readIntro, options: .regularExpression) != nil {
                r.starts.append(Candidate(time: s.start, source: .audio, label: "“\(s.text.prefix(24))…”", score: 0.8))
            }
            for s in transcript where s.text.contains("봉헌") || s.text.contains("헌금") {
                r.ends.append(Candidate(time: s.start, source: .audio, label: "“\(s.text.prefix(24))…”", score: 0.8))
            }
        }

        r.starts.sort { $0.time < $1.time }
        r.ends.sort { $0.time < $1.time }
        r.suggested = suggest(r)
        return r
    }

    /// 추천 구간: 설교 자막 구간을 기준으로
    ///  In  = 설교 자막 시작 전 30분 안의 마지막 '성경 봉독' 화면. 그 뒤 60초 안에 봉독 안내 음성이 있으면 그 음성 시작
    ///  Out = 설교 자막이 사라진 곳과 그 뒤 첫 찬송/봉헌 화면 중 이른 쪽
    public static func suggest(_ r: Result) -> TimeRange? {
        let anchor = r.sermonScreen?.start
        let screenStarts = r.starts.filter { $0.source == .screen && $0.score >= 1 }
        var start: Double?
        if let anchor {
            start = screenStarts.filter { $0.time <= anchor && $0.time >= anchor - 1800 }.last?.time
                ?? r.starts.filter { $0.time <= anchor && $0.time >= anchor - 1800 }.last?.time
        } else {
            start = (screenStarts.last ?? r.starts.last)?.time
        }
        guard var s = start else { return nil }
        if let voice = r.starts.first(where: { $0.source == .audio && $0.time >= s && $0.time <= s + 60 }) { s = voice.time }
        let ends = r.ends.filter { $0.time > s + 300 }
        guard let e = ends.filter({ $0.source == .screen }).map(\.time).min() ?? ends.map(\.time).min() else { return nil }
        return TimeRange(start: s, end: e)
    }

    /// 조건을 만족하는 샘플들의 연속 구간 [처음, 마지막] (gap보다 짧게 끊긴 것은 이어 붙임)
    static func runs(_ samples: [ScreenTextSample], where match: (ScreenTextSample) -> Bool, gap: Double) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for s in samples where match(s) {
            if let last = out.last, s.time - last.upperBound <= gap {
                out[out.count - 1] = last.lowerBound...s.time
            } else {
                out.append(s.time...s.time)
            }
        }
        return out
    }

    /// 설교 하단 자막과 목차 박스에서 제목·본문·설교자·목차를 읽는다 (여러 장에서 가장 자주 나온 값)
    static func metadata(_ sermon: [ScreenTextSample], all: [ScreenTextSample], sermon range: ClosedRange<Double>) -> Metadata {
        var m = Metadata()
        func mostCommon(_ values: [String]) -> String? {
            Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key
        }
        var titles: [String] = [], passages: [String] = [], preachers: [String] = [], labels: [String] = []
        for s in sermon {
            // 하단 자막 영역(화면 아래쪽 40%)의 줄들
            let lower = s.lines.filter { $0.y < 0.4 && $0.x < 0.6 }
            for l in lower {
                let t = l.text.trimmingCharacters(in: .whitespaces)
                if t.contains("|") || t.contains("｜") { labels.append(t); continue }
                if t.contains("본문") {
                    if let r = t.range(of: #"본\s*문\s*[:：]?\s*"#, options: .regularExpression) {
                        passages.append(String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
                    }
                    if let r = t.range(of: #"설\s*교\s*[:：]\s*([^/]+?)\s*/"#, options: .regularExpression) {
                        let who = t[r].replacingOccurrences(of: #"^설\s*교\s*[:：]\s*"#, with: "", options: .regularExpression)
                            .replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces)
                        preachers.append(who)
                    }
                    continue
                }
            }
            // 제목: 하단 자막에서 글자가 가장 큰 줄
            if let big = lower.filter({ !$0.text.contains("|") && !$0.text.contains("본문") && !$0.text.contains(":") })
                .max(by: { $0.h < $1.h }) {
                titles.append(big.text.trimmingCharacters(in: .whitespaces))
            }
        }
        m.title = mostCommon(titles)
        m.passage = mostCommon(passages)
        m.preacher = mostCommon(preachers)
        m.serviceLabel = mostCommon(labels)

        // 목차 박스: 오른쪽 아래, "1." "2." 로 시작하는 줄
        var outline: [Int: [String]] = [:]
        for s in all where s.time >= range.lowerBound && s.time <= range.upperBound {
            for l in s.lines where l.x > 0.6 && l.y < 0.5 {
                let t = l.text.trimmingCharacters(in: .whitespaces)
                guard let r = t.range(of: #"^(\d{1,2})\s*[.)]\s*"#, options: .regularExpression),
                      let n = Int(t[r].filter(\.isNumber)) else { continue }
                outline[n, default: []].append(String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        m.outline = outline.keys.sorted().compactMap { n in mostCommon(outline[n] ?? []).map { "\(n). \($0)" } }
        return m
    }

    /// 거친 스캔(기본 6초) → 후보 주변 ±8초만 1초 간격으로 다시 스캔 → 후보 계산
    public static func scan(video: URL, coarseInterval: Double = 6, transcript: [TranscriptSegment]? = nil,
                            cacheDirectory: URL?, keywords: Keywords = Keywords(),
                            progress: (@Sendable (Double) -> Void)? = nil) async throws -> (Result, ScreenTextScan) {
        let coarse = try await ScreenTextScanner(interval: coarseInterval).scan(
            video: video, cacheDirectory: cacheDirectory) { p in progress?(p * 0.85) }
        let first = find(screen: coarse, transcript: transcript, keywords: keywords)
        var refineTimes = Set<Double>()
        for c in first.starts + first.ends where c.source == .screen {
            for dt in stride(from: -8.0, through: 8.0, by: 1.0) { refineTimes.insert((c.time + dt).rounded()) }
        }
        let known = Set(coarse.samples.map { $0.time.rounded() })
        let fine = try await ScreenTextScanner(interval: 1).scan(
            video: video, times: refineTimes.subtracting(known).filter { $0 >= 0 }.sorted()) { p in progress?(0.85 + p * 0.15) }
        let merged = ScreenTextScan(interval: 1, samples: (coarse.samples + fine).sorted { $0.time < $1.time })
        // 간격이 섞였으므로 runs의 gap 판정은 거친 간격 기준으로
        var r = find(screen: ScreenTextScan(interval: coarseInterval, samples: merged.samples), transcript: transcript, keywords: keywords)
        r.suggested = suggest(r)
        return (r, merged)
    }
}
