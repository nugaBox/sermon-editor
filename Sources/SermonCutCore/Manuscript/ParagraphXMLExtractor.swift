import Foundation

/// 문단/텍스트 요소 이름만 다르고 구조가 같은 hwpx(OWPML)·docx(WordprocessingML)용 공통 추출기.
/// 네임스페이스 접두사가 아니라 URI로 매칭한다 (docs/hwpx-structure.md §3).
struct ParagraphXMLSpec {
    var namespace: String
    var paragraph: String      // hp:p / w:p
    var text: String           // hp:t / w:t
    var tab: Set<String>       // 공백으로 바꿀 인라인 요소
    var lineBreak: Set<String> // 줄바꿈으로 바꿀 인라인 요소

    static let hwpx = ParagraphXMLSpec(
        namespace: "http://www.hancom.co.kr/hwpml/2011/paragraph",
        paragraph: "p", text: "t", tab: ["tab"], lineBreak: ["lineBreak"]
    )
    static let docx = ParagraphXMLSpec(
        namespace: "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        paragraph: "p", text: "t", tab: ["tab"], lineBreak: ["br", "cr"]
    )
}

final class ParagraphXMLExtractor: NSObject, XMLParserDelegate {
    private let spec: ParagraphXMLSpec
    private(set) var paragraphs: [String] = []
    private(set) var rootElement: (name: String, namespace: String?)?
    private var stack: [String] = []   // 열린 문단들의 텍스트 (표 안 중첩 문단 대비)
    private var textDepth = 0

    init(spec: ParagraphXMLSpec) { self.spec = spec }

    static func extract(_ data: Data, spec: ParagraphXMLSpec) throws -> (paragraphs: [String], root: String?, rootNamespace: String?) {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let delegate = ParagraphXMLExtractor(spec: spec)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SermonCutError.manuscriptUnreadable(fileName: "XML", reason: parser.parserError?.localizedDescription ?? "XML 오류")
        }
        return (delegate.paragraphs, delegate.rootElement?.name, delegate.rootElement?.namespace)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if rootElement == nil { rootElement = (elementName, namespaceURI) }
        guard namespaceURI == spec.namespace else { return }
        if elementName == spec.paragraph {
            stack.append("")
        } else if elementName == spec.text {
            textDepth += 1
        } else if !stack.isEmpty {
            if spec.tab.contains(elementName) { appendText(" ") }
            if spec.lineBreak.contains(elementName) { appendText("\n") }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard namespaceURI == spec.namespace else { return }
        if elementName == spec.paragraph, let text = stack.popLast() {
            paragraphs.append(text)
        } else if elementName == spec.text {
            textDepth = max(0, textDepth - 1)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // hp:t는 혼합 콘텐츠: markpenBegin 같은 빈 요소 뒤의 글자도 모두 hp:t 안이다
        if textDepth > 0 { appendText(string) }
    }

    private func appendText(_ s: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1] += s
    }
}
