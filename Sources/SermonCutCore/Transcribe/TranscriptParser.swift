import Foundation

/// whisper.cpp `-ojf` JSON → [TranscriptSegment]
///
/// ★ SPEC §4: whisper는 잘라낸 wav 기준(0초 시작) 시간을 준다.
///   **여기서, 파싱하는 바로 그 지점에서** `sourceStart`를 더해 원본 기준으로 바꾼다.
///   이후 어떤 코드도 다시 보정하지 않는다.
public enum TranscriptParser {
    public static func parse(_ data: Data, sourceStart: Double) throws -> [TranscriptSegment] {
        // 토큰 단위로 UTF-8이 잘릴 수 있어 손실 허용 디코딩 후 다시 파싱
        let cleaned = Data(String(decoding: data, as: UTF8.self).utf8)
        guard let root = try? JSONSerialization.jsonObject(with: cleaned) as? [String: Any] else {
            throw SermonCutError.transcriptParseFailed(reason: "JSON 형식이 아닙니다")
        }
        guard let items = root["transcription"] as? [[String: Any]] else {
            throw SermonCutError.transcriptParseFailed(reason: "transcription 항목이 없습니다")
        }

        var segments: [TranscriptSegment] = []
        for item in items {
            guard let offsets = item["offsets"] as? [String: Any],
                  let fromMs = number(offsets["from"]), let toMs = number(offsets["to"]) else { continue }
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, toMs > fromMs else { continue }

            let relStart = fromMs / 1000, relEnd = toMs / 1000
            let words = parseWords(item["tokens"] as? [[String: Any]], segmentRange: relStart...relEnd, sourceStart: sourceStart)
            segments.append(TranscriptSegment(
                id: "T\(segments.count + 1)",
                start: relStart + sourceStart,
                end: relEnd + sourceStart,
                text: text,
                words: words
            ))
        }
        return segments
    }

    /// 토큰을 띄어쓰기 기준 단어로 묶는다. 특수 토큰([_TT_…], [_BEG_])은 버린다.
    /// VAD 사용 시 whisper.cpp가 토큰 시간을 원래 시간축으로 되돌리지 않는 문제가 있어(2026-09 실측),
    /// 토큰 시간이 세그먼트 범위를 벗어나면 단어 타이밍 전체를 버린다(nil).
    static func parseWords(_ tokens: [[String: Any]]?, segmentRange: ClosedRange<Double>, sourceStart: Double) -> [WordTiming]? {
        guard let tokens, !tokens.isEmpty else { return nil }
        var words: [WordTiming] = []
        let tolerance = 0.5
        for tok in tokens {
            guard let text = tok["text"] as? String, !text.hasPrefix("[_"),
                  let off = tok["offsets"] as? [String: Any],
                  let f = number(off["from"]), let t = number(off["to"]) else { continue }
            let s = f / 1000, e = t / 1000
            if s < segmentRange.lowerBound - tolerance || e > segmentRange.upperBound + tolerance { return nil }
            let p = number(tok["p"])
            if text.hasPrefix(" ") || words.isEmpty {
                words.append(WordTiming(text: text.trimmingCharacters(in: .whitespaces), start: s + sourceStart,
                                        end: e + sourceStart, probability: p))
            } else if var last = words.popLast() {
                last.text += text
                last.end = e + sourceStart
                if let p, let lp = last.probability { last.probability = min(lp, p) }
                words.append(last)
            }
        }
        return words.isEmpty ? nil : words
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
