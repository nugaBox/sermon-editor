import Foundation

/// 한국어 문장 분할 (docs/hwpx-structure.md §5)
/// - `.` `?` `!` 뒤에 공백/끝이 오면 문장 끝
/// - 인용부호(“ ” ‘ ’) 안에서는 끊지 않는다
/// - 말줄임(`...`, `…`)은 끝이 아니다
public enum SentenceSplitter {
    public static func split(_ text: String) -> [String] {
        let chars = Array(text)
        var sentences: [String] = []
        var current = ""
        var quoteDepth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            switch c {
            case "“", "‘": quoteDepth += 1
            case "”", "’": quoteDepth = max(0, quoteDepth - 1)
            case ".", "?", "!":
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                let isEllipsis = c == "." && (prev == "." || next == ".")
                // 닫는 인용부호가 바로 뒤따르면 그것까지 포함
                var j = i + 1
                while j < chars.count, chars[j] == "”" || chars[j] == "’" || chars[j] == "\"" || chars[j] == ")" {
                    current.append(chars[j])
                    if chars[j] == "”" || chars[j] == "’" { quoteDepth = max(0, quoteDepth - 1) }
                    j += 1
                }
                let atBoundary = j >= chars.count || chars[j].isWhitespace
                // "3. " 같은 목록 번호는 문장 끝이 아니다
                let isListMarker = c == "." && current.trimmingCharacters(in: .whitespaces).range(of: #"^\d{1,2}\.$"#, options: .regularExpression) != nil
                if !isEllipsis, !isListMarker, quoteDepth == 0, atBoundary {
                    flush(&current, into: &sentences)
                }
                i = j
                continue
            case "\n":
                flush(&current, into: &sentences)
            default:
                break
            }
            i += 1
        }
        flush(&current, into: &sentences)
        return sentences
    }

    private static func flush(_ current: inout String, into list: inout [String]) {
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { list.append(t) }
        current = ""
    }
}
