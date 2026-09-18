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
        public init() {}
    }

    public struct Suggestion: Sendable, Equatable {
        public var range: TimeRange
        public var segmentIDs: [String]
        public var reason: UnmatchedReason
    }

    public var config: Config
    public init(config: Config = Config()) { self.config = config }

    /// 세그먼트에 정렬 결과와 삭제 제안을 기록해 돌려준다. 사용자가 이미 뒤집은 세그먼트(userOverridden)는 건드리지 않는다.
    public func apply(segments: [TranscriptSegment], alignment: [LocalAligner.Result],
                      sourceRange: TimeRange, hasManuscript: Bool) -> (segments: [TranscriptSegment], suggestions: [Suggestion], readingRange: TimeRange?) {
        var segs = segments
        let byID = Dictionary(uniqueKeysWithValues: alignment.map { ($0.segmentID, $0) })
        for i in segs.indices {
            guard let r = byID[segs[i].id] else { continue }
            segs[i].matchedManuscriptID = r.sentenceID
            segs[i].alignStatus = r.status
            segs[i].confidence = r.similarity
            segs[i].unmatchedReason = nil
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

        var suggestions: [Suggestion] = []
        for run in runs {
            let start = segs[run.lowerBound].start, end = segs[run.upperBound].end
            guard end - start >= config.minRunSeconds else { continue }
            var ids: [String] = []
            for j in run where !segs[j].userOverridden {
                segs[j].isRemoved = true
                segs[j].unmatchedReason = .improvised
                ids.append(segs[j].id)
            }
            suggestions.append(Suggestion(range: TimeRange(start: start, end: end), segmentIDs: ids, reason: .improvised))
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
