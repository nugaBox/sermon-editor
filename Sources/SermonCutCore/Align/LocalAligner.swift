import Foundation

/// 원고 ↔ 전사문 로컬 정렬 (SPEC §3.3 1단계, API 호출 없음)
///
/// - 유사도: 세그먼트의 문자 bigram 중 원고 문장(연속 1~3문장)에 들어있는 비율(포함도).
///   구어는 원고보다 길고 군더더기가 많아 Jaccard보다 포함도가 안정적이다.
/// - 단조 증가 DP: 설교는 원고 순서대로 진행된다. 세그먼트 j가 문장 i에 매칭되면 이후 세그먼트는 i 이상에만 매칭.
///   같은 문장에 여러 세그먼트, 문장 건너뛰기(작은 벌점) 허용. 어떤 문장에도 안 맞으면 unmatched.
public struct LocalAligner: Sendable {
    public struct Config: Sendable {
        /// 이 값 이상이면 매칭 후보 (DP 이득 = 유사도 − threshold)
        public var matchThreshold: Double = 0.30
        /// 이 값 이상이면 확신 (AI로 보내지 않음)
        public var confidentThreshold: Double = 0.55
        /// 원고 문장 하나 건너뛸 때마다 벌점
        public var skipPenalty: Double = 0.01
        /// bigram이 이보다 적은 짧은 세그먼트("아멘", "여러분")는 판단 보류 → 앞뒤를 따른다
        public var minBigrams: Int = 4
        /// 한 세그먼트가 덮을 수 있는 최대 연속 문장 수
        public var maxSpan: Int = 3
        /// 문장 하나 더 덮을 때마다 빼는 값 (애매하면 적게 덮는 쪽을 택함)
        public var spanPenalty: Double = 0.03
        public init() {}
    }

    public struct Result: Sendable, Equatable {
        public var segmentID: String
        public var sentenceID: String?
        public var similarity: Double
        public var status: AlignStatus
        /// 너무 짧아 스스로 판단하지 않은 세그먼트
        public var undetermined: Bool
    }

    public var config: Config
    public init(config: Config = Config()) { self.config = config }

    public func align(segments: [TranscriptSegment], sentences: [ManuscriptSentence]) -> [Result] {
        guard !sentences.isEmpty else {
            return segments.map { Result(segmentID: $0.id, sentenceID: nil, similarity: 0, status: .notAligned, undetermined: false) }
        }
        let segGrams = segments.map { TextNormalizer.bigrams($0.text) }
        let sentGrams = sentences.map { TextNormalizer.bigrams($0.text) }
        let J = segments.count, I = sentences.count
        let maxSpan = config.maxSpan

        // 세그먼트 j가 문장 i부터 w개(i…i+w-1)를 덮는다고 볼 때의 포함도.
        // VAD가 여러 문장을 한 세그먼트로 묶는 경우가 있어 w=1…3을 본다. 문장이 늘 때마다 작은 벌점.
        func containment(_ g: Set<String>, _ i: Int, _ w: Int) -> Double {
            var window = sentGrams[i]
            for k in 1..<w { window.formUnion(sentGrams[i + k]) }
            return Double(g.intersection(window).count) / Double(g.count)
        }
        var single = Array(repeating: [Double](repeating: 0, count: I), count: J)
        // spanScore[j][e] = 끝 문장이 e인 최선의 (점수, 폭)
        var spanScore = Array(repeating: [(Double, Int)](repeating: (0, 1), count: I), count: J)
        for j in 0..<J where segGrams[j].count >= config.minBigrams {
            let g = segGrams[j]
            for i in 0..<I { single[j][i] = containment(g, i, 1) }
            for e in 0..<I {
                var best = (single[j][e], 1)
                if maxSpan >= 2 {
                    for w in 2...maxSpan where e - w + 1 >= 0 {
                        let v = containment(g, e - w + 1, w) - config.spanPenalty * Double(w - 1)
                        if v > best.0 { best = (v, w) }
                    }
                }
                spanScore[j][e] = best
            }
        }

        // DP (상태 = 마지막으로 덮은 문장 e)
        // best[e]: 최대 점수 / back[j][e]: -2 = 세그먼트 j unmatched(상태 유지), k(≥-1) = 직전 상태
        let negInf = -Double.infinity
        let none = 0.0
        var best = [Double](repeating: negInf, count: I)
        var back = Array(repeating: [Int](repeating: -2, count: I), count: J)
        let λ = config.skipPenalty

        for j in 0..<J where segGrams[j].count >= config.minBigrams {
            // pred(i) = 문장 i부터 덮기 시작할 수 있는 최대 이전 점수와 그 상태
            //   k == i  : 같은 문장 계속
            //   k <  i  : 앞에서 건너옴, 사이 문장 (i-k-1)개 × λ 벌점
            //   none    : 첫 매칭
            var pred = [(Double, Int)](repeating: (none, -1), count: I)
            var runMax = negInf, runArg = -1   // max_{k<i} (best[k] + λ·k)
            for i in 0..<I {
                var cand = (none, -1)
                if best[i] > cand.0 { cand = (best[i], i) }
                if runMax > negInf {
                    let v = runMax - λ * Double(i - 1)
                    if v > cand.0 { cand = (v, runArg) }
                }
                pred[i] = cand
                if best[i] > negInf, best[i] + λ * Double(i) > runMax {
                    runMax = best[i] + λ * Double(i)
                    runArg = i
                }
            }
            var newBest = best
            for e in 0..<I {
                let (score, w) = spanScore[j][e]
                let gain = score - config.matchThreshold
                guard gain > 0 else { continue }
                let (p, k) = pred[e - w + 1]
                if p + gain > newBest[e] {
                    newBest[e] = p + gain
                    back[j][e] = k
                }
            }
            best = newBest
        }

        // 역추적
        var state = -1
        var bestScore = none
        for i in 0..<I where best[i] > bestScore { bestScore = best[i]; state = i }
        var assign = [Int?](repeating: nil, count: J)
        var j = J - 1
        while j >= 0, state >= 0 {
            let b = back[j][state]
            if b != -2 {
                // 덮은 문장들 중 가장 비슷한 문장으로 표시
                let w = spanScore[j][state].1
                let covered = (state - w + 1)...state
                assign[j] = covered.max { single[j][$0] < single[j][$1] } ?? state
                state = b
            }
            j -= 1
        }

        return segments.indices.map { j in
            let determinable = segGrams[j].count >= config.minBigrams
            if let i = assign[j] {
                return Result(segmentID: segments[j].id, sentenceID: sentences[i].id, similarity: max(single[j][i], spanScore[j].max { $0.0 < $1.0 }?.0 ?? 0),
                              status: .matched, undetermined: false)
            }
            let top = single[j].max() ?? 0
            return Result(segmentID: segments[j].id, sentenceID: nil, similarity: top,
                          status: .unmatched, undetermined: !determinable)
        }
    }
}

public enum TextNormalizer {
    /// 한글·영문·숫자만 남기고 소문자화 (공백·구두점 제거, 조사는 유지)
    public static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { s in
            (0xAC00...0xD7A3).contains(s.value) || CharacterSet.alphanumerics.contains(s)
        }.map(Character.init))
    }

    public static func bigrams(_ text: String) -> Set<String> {
        let chars = Array(normalize(text))
        guard chars.count >= 2 else { return [] }
        var set = Set<String>()
        for i in 0..<(chars.count - 1) { set.insert(String(chars[i...i + 1])) }
        return set
    }
}
