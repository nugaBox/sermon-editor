import Foundation

/// 문단 배열 → 제목/본문/소제목/문장 (docs/hwpx-structure.md §4, SPEC §6.0b·§6.6)
public enum ManuscriptPreprocessor {
    public static func process(paragraphs raw: [String]) -> Manuscript {
        var title: String?
        var passage: String?
        var body: [(text: String, isHeadingCandidate: HeadingCandidate?)] = []

        for p in raw {
            let text = p.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if isPageNumber(text) { continue }
            if title == nil, let v = metadataValue(text, key: "제목") {
                title = v.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
                continue
            }
            if passage == nil, let v = metadataValue(text, key: "본문") {
                passage = v
                continue
            }
            body.append((text, headingCandidate(text)))
        }

        // 번호형 소제목은 1부터 연속 증가하는 경우만 인정 (본문 속 번호 목록 오탐 방지)
        let accepted = acceptHeadings(body.map(\.isHeadingCandidate))

        var headings: [ManuscriptHeading] = []
        var sentences: [ManuscriptSentence] = []
        var pendingHeading: Int?
        for (i, item) in body.enumerated() {
            if accepted.contains(i), let c = item.isHeadingCandidate {
                headings.append(ManuscriptHeading(number: headings.count + 1, title: c.title, firstSentenceID: nil))
                pendingHeading = headings.count - 1
                continue
            }
            let isScripture = isScriptureParagraph(item.text)
            let cleaned = clean(item.text)
            for s in SentenceSplitter.split(cleaned) {
                let id = "M\(sentences.count + 1)"
                sentences.append(ManuscriptSentence(id: id, text: s, order: sentences.count,
                                                    sectionIndex: headings.count, isScripture: isScripture))
                if let h = pendingHeading {
                    headings[h].firstSentenceID = id
                    pendingHeading = nil
                }
            }
        }
        return Manuscript(title: title, passage: passage, headings: headings, sentences: sentences)
    }

    // MARK: - 메타데이터

    /// "제  목 : …", "본  문 : …" (글자 사이 공백 허용)
    static func metadataValue(_ text: String, key: String) -> String? {
        let pattern = "^" + key.map { String($0) }.joined(separator: #"\s*"#) + #"\s*[:：]\s*(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    static func isPageNumber(_ text: String) -> Bool {
        text.range(of: #"^[-–\s]*\d{1,3}[-–\s]*$"#, options: .regularExpression) != nil
    }

    // MARK: - 소제목

    struct HeadingCandidate: Equatable {
        enum Kind: Equatable { case marked, numbered(Int) }
        var kind: Kind
        var title: String
    }

    static let maxHeadingLength = 40

    static func headingCandidate(_ text: String) -> HeadingCandidate? {
        guard text.count <= maxHeadingLength + 6, !text.contains("\n") else { return nil }
        // ** 제목
        if let r = text.range(of: #"^\*{1,3}\s*"#, options: .regularExpression) {
            let t = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : HeadingCandidate(kind: .marked, title: t)
        }
        // 1. 제목 / 1) 제목 / (1) 제목 / Ⅰ. 제목 / 첫째, 제목
        let numbered: [(String, (String) -> Int?)] = [
            (#"^(\d{1,2})\s*[.)]\s*"#, { Int($0) }),
            (#"^\((\d{1,2})\)\s*"#, { Int($0) }),
            (#"^([ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ])\s*[.)]?\s*"#, { romanValue($0) }),
            (#"^(첫|둘|셋|넷|다섯|여섯)째\s*[,.]?\s*"#, { ["첫": 1, "둘": 2, "셋": 3, "넷": 4, "다섯": 5, "여섯": 6][$0] }),
        ]
        for (pattern, value) in numbered {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let numRange = Range(m.range(at: 1), in: text),
                  let whole = Range(m.range, in: text),
                  let n = value(String(text[numRange])) else { continue }
            let t = String(text[whole.upperBound...]).trimmingCharacters(in: .whitespaces)
            // 문장처럼 끝나면(…다. …까?) 소제목이 아니라 번호 매긴 본문
            guard !t.isEmpty, t.count <= maxHeadingLength, !endsLikeSentence(t) else { return nil }
            return HeadingCandidate(kind: .numbered(n), title: t)
        }
        return nil
    }

    static func acceptHeadings(_ candidates: [HeadingCandidate?]) -> Set<Int> {
        var accepted = Set<Int>()
        // ** 표시는 모두 인정
        for (i, c) in candidates.enumerated() where c?.kind == .marked { accepted.insert(i) }
        if !accepted.isEmpty { return accepted }
        // 번호형: 1,2,3… 순서대로 나오는 것만
        var expected = 1
        var run: [Int] = []
        for (i, c) in candidates.enumerated() {
            if case .numbered(let n)? = c?.kind, n == expected {
                run.append(i)
                expected += 1
            }
        }
        return run.count >= 2 ? Set(run) : []
    }

    static func romanValue(_ s: String) -> Int? {
        ["Ⅰ": 1, "Ⅱ": 2, "Ⅲ": 3, "Ⅳ": 4, "Ⅴ": 5, "Ⅵ": 6, "Ⅶ": 7, "Ⅷ": 8, "Ⅸ": 9, "Ⅹ": 10][s]
    }

    static func endsLikeSentence(_ t: String) -> Bool {
        t.range(of: #"(다|요|까|오|라|니다|시다)[.!?]\s*$"#, options: .regularExpression) != nil
    }

    // MARK: - 본문 정리

    /// “…”(에스더 4:1). 처럼 인용부호로 시작하고 성구 표기로 끝나는 단독 문단
    static func isScriptureParagraph(_ text: String) -> Bool {
        text.hasPrefix("“") || text.hasPrefix("\"")
            ? text.range(of: #"[”"]\s*\((?:[가-힣]+\s*)?\d+:\d+[^)]*\)\s*\.?$"#, options: .regularExpression) != nil
            : false
    }

    /// 낭독되지 않는 표기 제거: 성구 표기 (3:13), (에스더 4:1), 대괄호 메모 [찬송]
    static func clean(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"\((?:[가-힣]+\s*)?\d+\s*:\s*\d+(?:\s*[~\-–]\s*\d+(?::\d+)?)?(?:\s*,\s*\d+)*\)"#,
                                   with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[[^\]]{0,30}\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\((?:잠시|침묵|찬송|기도|낭독|박수|영상)[^)]{0,20}\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}
