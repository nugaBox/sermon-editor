import Foundation

/// 정렬 결과 → 삭제 후보 제안 (사용자가 최종 결정, SPEC §3.3 3단계)
///
/// 09/13 수작업 편집 분석(docs/phase1-report.md): 사용자는 원고에 없는 문장을 하나하나 지우지 않는다.
/// 원고 내용 사이사이의 부연 설명은 남기고, **원고를 벗어나 다른 화제(광고·근황·시사·교단 소식 등)로
/// 한참 이어지는 구간**만 통째로 지운다. 그래서 세그먼트 단위가 아니라 "원고 매칭이 없는 연속 구간" 단위로 판단한다.
public struct RemovalSuggester: Sendable {
    public struct Config: Sendable {
        /// 이 길이 이상 이어지는 무매칭 구간만 삭제 후보 (초)
        public var minRunSeconds: Double = 25
        /// 무매칭 구간 사이에 낀 짧은 매칭(우연히 비슷한 문장)은 무시하고 하나의 구간으로 본다 (초)
        public var bridgeMatchedSeconds: Double = 8
        /// 설교 시작부 성경 봉독 보호
        public var protectOpeningReading: Bool = true
        /// 봉독 보호를 찾는 범위: sourceRange 시작 후 이 시간 안에서만 (초)
        public var readingSearchSeconds: Double = 600
        /// 이 간격보다 가까운 무매칭 구간들은 하나의 탈선으로 합친다 (초)
        public var mergeRunGap: Double = 5
        /// 화제 이탈 판정: 주변 원고(앞뒤 매칭 문장 ±localWindow)와의 어휘 겹침(idf 가중)이 이 값 미만
        public var offTopicLocalMax: Double = 0.2
        /// 그리고 원고 전체와의 어휘 겹침이 이 값 미만
        public var offTopicGlobalMax: Double = 0.4
        public var localWindow: Int = 8
        public init() {}
    }

    public struct Suggestion: Sendable, Equatable {
        public var runSegmentIDs: [String] = []
        public var range: TimeRange
        public var segmentIDs: [String]
        public var reason: UnmatchedReason
        /// true: 화제 이탈로 판단해 삭제 표시함 / false: 원고와 어휘가 겹쳐 유지하고 "확인 필요"만 표시
        public var removed: Bool
        public var localOverlap: Double
        public var globalOverlap: Double
    }

    public var config: Config
    public init(config: Config = Config()) { self.config = config }

    /// 세그먼트에 정렬 결과와 삭제 제안을 기록해 돌려준다. 사용자가 이미 뒤집은 세그먼트(userOverridden)는 건드리지 않는다.
    public func apply(segments: [TranscriptSegment], alignment: [LocalAligner.Result], sentences: [ManuscriptSentence],
                      sourceRange: TimeRange) -> (segments: [TranscriptSegment], suggestions: [Suggestion], readingRange: TimeRange?) {
        let hasManuscript = !sentences.isEmpty
        var segs = segments
        let byID = Dictionary(uniqueKeysWithValues: alignment.map { ($0.segmentID, $0) })
        for i in segs.indices {
            guard let r = byID[segs[i].id] else { continue }
            segs[i].matchedManuscriptID = r.sentenceID
            segs[i].alignStatus = r.status
            segs[i].confidence = r.similarity
            segs[i].unmatchedReason = nil
            if !segs[i].userOverridden { segs[i].needsReview = nil; segs[i].aiNote = nil }
        }
        guard hasManuscript else { return (segs, [], nil) }

        // 성경 봉독 보호 구간
        let reading = config.protectOpeningReading ? Self.openingReading(segs, sourceRange: sourceRange, searchSeconds: config.readingSearchSeconds) : nil
        let protected: (TranscriptSegment) -> Bool = { s in reading.map { s.end <= $0.end + 0.01 } ?? false }

        // 매칭 여부 (짧아서 판단 보류된 세그먼트는 무매칭으로 취급 — 구간 길이 계산에 포함)
        let matched = segs.map { s in byID[s.id]?.status == .matched }

        // 무매칭 연속 구간 찾기 (짧은 매칭 섬은 다리 놓기)
        var runs: [ClosedRange<Int>] = []
        var i = 0
        while i < segs.count {
            if matched[i] || protected(segs[i]) { i += 1; continue }
            var end = i
            var k = i + 1
            while k < segs.count {
                if protected(segs[k]) { break }
                if !matched[k] { end = k; k += 1; continue }
                // 매칭 섬의 길이
                var m = k
                while m < segs.count, matched[m] { m += 1 }
                let islandSeconds = segs[m - 1].end - segs[k].start
                // 이미 탈선이 충분히 길게 이어진 상태에서만 다리를 놓는다 (진짜 원고 복귀를 삼키지 않도록)
                let runSoFar = segs[end].end - segs[i].start
                if m < segs.count, !matched[m], islandSeconds <= config.bridgeMatchedSeconds,
                   runSoFar >= config.minRunSeconds * 0.6, !protected(segs[m]) {
                    end = m; k = m + 1
                } else {
                    break
                }
            }
            runs.append(i...end)
            i = end + 1
        }

        // 짧은 간격으로 끊긴 무매칭 구간은 하나의 탈선으로 합친다
        var mergedRuns: [ClosedRange<Int>] = []
        for run in runs {
            if let last = mergedRuns.last, segs[run.lowerBound].start - segs[last.upperBound].end < config.mergeRunGap,
               !segs[(last.upperBound + 1)..<run.lowerBound].contains(where: protected) {
                mergedRuns[mergedRuns.count - 1] = last.lowerBound...run.upperBound
            } else {
                mergedRuns.append(run)
            }
        }

        let topic = TopicOverlap(sentences: sentences)
        var suggestions: [Suggestion] = []
        for run in mergedRuns {
            let start = segs[run.lowerBound].start, end = segs[run.upperBound].end
            guard end - start >= config.minRunSeconds else { continue }
            let text = segs[run].map(\.text).joined(separator: " ")
            // 주변 원고 범위: 앞뒤로 가장 가까운 매칭 문장
            let before = segs[..<run.lowerBound].last { $0.alignStatus == .matched }?.matchedManuscriptID
            let after = segs[(run.upperBound + 1)...].first { $0.alignStatus == .matched }?.matchedManuscriptID
            let local = topic.overlap(text, around: before, after, window: config.localWindow)
            let global = topic.overlap(text)
            let offTopic = local < config.offTopicLocalMax && global < config.offTopicGlobalMax
            var ids: [String] = []
            for j in run where !segs[j].userOverridden {
                segs[j].isRemoved = offTopic
                segs[j].unmatchedReason = offTopic ? .improvised : .unknown
                segs[j].needsReview = offTopic ? nil : true
                segs[j].aiNote = nil
                ids.append(segs[j].id)
            }
            suggestions.append(Suggestion(runSegmentIDs: segs[run].map(\.id), range: TimeRange(start: start, end: end), segmentIDs: ids,
                                          reason: offTopic ? .improvised : .unknown, removed: offTopic,
                                          localOverlap: local, globalOverlap: global))
        }
        return (segs, suggestions, reading)
    }

    /// 시작부 성경 봉독: 첫 몇 세그먼트 안에 "읽어드리겠습니다/봉독" 같은 안내가 있으면,
    /// 거기서부터 처음 나오는 단독 "아멘"까지를 봉독으로 본다.
    static func openingReading(_ segs: [TranscriptSegment], sourceRange: TimeRange, searchSeconds: Double) -> TimeRange? {
        let limit = sourceRange.start + searchSeconds
        let intro = #"(읽어\s*드리|읽겠습니다|봉독|말씀을?\s*(함께\s*)?읽)"#
        guard let startIdx = segs.prefix(5).firstIndex(where: { $0.text.range(of: intro, options: .regularExpression) != nil }) else {
            return nil
        }
        for s in segs[startIdx...] where s.start <= limit {
            let t = TextNormalizer.normalize(s.text)
            if t == "아멘" || t.hasSuffix("아멘") && t.count <= 6 {
                return TimeRange(start: segs[startIdx].start, end: s.end)
            }
        }
        return nil
    }
}

/// 발화 묶음과 원고의 어휘 겹침 (bigram, idf 가중). 화제 이탈(시사·교단 소식·근황)은 원고 어휘와 거의 겹치지 않는다.
struct TopicOverlap {
    let sentences: [ManuscriptSentence]
    let grams: [Set<String>]
    let df: [String: Int]
    let index: [String: Int]

    init(sentences: [ManuscriptSentence]) {
        self.sentences = sentences
        grams = sentences.map { TextNormalizer.bigrams($0.text) }
        var df: [String: Int] = [:]
        for g in grams { for b in g { df[b, default: 0] += 1 } }
        self.df = df
        index = Dictionary(uniqueKeysWithValues: sentences.enumerated().map { ($1.id, $0) })
    }

    /// 전체 원고 기준
    func overlap(_ text: String) -> Double {
        weighted(text) { df[$0] != nil }
    }

    /// 앞뒤 매칭 문장 사이 ± window 문장 기준
    func overlap(_ text: String, around before: String?, _ after: String?, window: Int) -> Double {
        guard !sentences.isEmpty else { return 0 }
        let lo = before.flatMap { index[$0] } ?? 0
        let hi = after.flatMap { index[$0] } ?? sentences.count - 1
        let range = max(0, min(lo, hi) - window)...min(sentences.count - 1, max(lo, hi) + window)
        var local = Set<String>()
        for i in range { local.formUnion(grams[i]) }
        return weighted(text) { local.contains($0) }
    }

    private func weighted(_ text: String, _ hit: (String) -> Bool) -> Double {
        let chars = Array(TextNormalizer.normalize(text))
        guard chars.count >= 2, !sentences.isEmpty else { return 0 }
        let n = Double(sentences.count)
        var total = 0.0, found = 0.0
        for i in 0..<(chars.count - 1) {
            let b = String(chars[i...i + 1])
            let w = log(n / Double(df[b] ?? 1))   // 원고에 없는 bigram도 희귀어로 취급
            total += w
            if hit(b) { found += w }
        }
        return total > 0 ? found / total : 0
    }
}
