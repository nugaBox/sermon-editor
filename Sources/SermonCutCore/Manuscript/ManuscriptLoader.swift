import Foundation

/// 확장자별로 원고를 읽어 문단 배열로 만든 뒤 전처리·문장 분할까지 한다.
public struct ManuscriptLoader: Sendable {
    public var locator: BinaryLocator

    public init(locator: BinaryLocator = BinaryLocator()) { self.locator = locator }

    public func load(_ url: URL) async throws -> Manuscript {
        let paragraphs = try await loadParagraphs(url)
        return ManuscriptPreprocessor.process(paragraphs: paragraphs)
    }

    public func loadParagraphs(_ url: URL) async throws -> [String] {
        let ext = url.pathExtension.lowercased()
        do {
            switch ext {
            case "hwpx": return try await HwpxParser(locator: locator).paragraphs(url)
            case "docx": return try await DocxParser(locator: locator).paragraphs(url)
            case "txt", "md", "text": return try Self.plainParagraphs(url)
            case "hwp": return try HwpParser().paragraphs(url)
            default: throw SermonCutError.unsupportedManuscript(fileExtension: ext)
            }
        } catch let e as SermonCutError {
            switch e {
            case .hwpProtected, .unsupportedManuscript, .manuscriptUnreadable, .cancelled: throw e
            default: throw SermonCutError.manuscriptUnreadable(fileName: url.lastPathComponent, reason: e.localizedDescription)
            }
        }
    }

    static func plainParagraphs(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        // UTF-8 우선, 실패하면 한글 윈도우 인코딩(CP949)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))))
            ?? String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: .newlines).map { line in
            // 마크다운 제목 기호(#)는 소제목 표시로 바꿔 둔다
            var l = line
            if let r = l.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) { l.replaceSubrange(r, with: "** ") }
            return l
        }
    }
}

public struct HwpxParser: Sendable {
    public var locator: BinaryLocator
    public init(locator: BinaryLocator = BinaryLocator()) { self.locator = locator }

    public func paragraphs(_ url: URL) async throws -> [String] {
        let zip = ZipReader(archive: url, locator: locator)
        let entries = try await zip.entries()
        var sectionFiles: [String] = []
        if entries.contains("Contents/content.hpf") {
            let hpf = try await zip.read("Contents/content.hpf")
            sectionFiles = HpfManifest.spineFiles(hpf)
        }
        if sectionFiles.isEmpty {
            // 매니페스트를 못 읽으면 section*.xml 을 숫자 순서로
            sectionFiles = entries.filter { $0.hasPrefix("Contents/section") && $0.hasSuffix(".xml") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        var result: [String] = []
        for file in sectionFiles where entries.contains(file) {
            try Task.checkCancellation()
            let data = try await zip.read(file)
            let extracted = try ParagraphXMLExtractor.extract(data, spec: .hwpx)
            // 루트가 hs:sec 인 파일만 본문 (header.xml 등은 건너뜀)
            guard extracted.root == "sec" else { continue }
            result += extracted.paragraphs
        }
        guard !result.isEmpty else {
            throw SermonCutError.manuscriptUnreadable(fileName: url.lastPathComponent, reason: "본문 문단을 찾지 못함")
        }
        return result
    }
}

/// Contents/content.hpf (OPF) 의 spine 순서대로 파일 경로를 돌려준다.
enum HpfManifest {
    static func spineFiles(_ data: Data) -> [String] {
        final class Delegate: NSObject, XMLParserDelegate {
            var items: [String: String] = [:]
            var spine: [String] = []
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                        qualifiedName qName: String?, attributes a: [String: String] = [:]) {
                if elementName == "item", let id = a["id"], let href = a["href"] { items[id] = href }
                if elementName == "itemref", let idref = a["idref"] { spine.append(idref) }
            }
        }
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        let d = Delegate()
        parser.delegate = d
        guard parser.parse() else { return [] }
        return d.spine.compactMap { d.items[$0] }.filter { $0.hasSuffix(".xml") }
    }
}

public struct DocxParser: Sendable {
    public var locator: BinaryLocator
    public init(locator: BinaryLocator = BinaryLocator()) { self.locator = locator }

    public func paragraphs(_ url: URL) async throws -> [String] {
        let data = try await ZipReader(archive: url, locator: locator).read("word/document.xml")
        return try ParagraphXMLExtractor.extract(data, spec: .docx).paragraphs
    }
}
