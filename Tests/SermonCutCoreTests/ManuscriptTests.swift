import XCTest
@testable import SermonCutCore

final class ManuscriptTests: XCTestCase {
    func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    func testHwpxParsesSpineOrderAndMixedContent() async throws {
        let paragraphs = try await HwpxParser().paragraphs(try fixture("sample.hwpx"))
        // header.xml(hh:head)는 제외, spine 순서 section0 → section1
        XCTAssertFalse(paragraphs.contains { $0.contains("헤더") })
        XCTAssertEqual(paragraphs.first, "제  목 : 시험 설교 제목 (3)")
        // markpen 인라인 요소 뒤의 글자까지 모아야 한다
        XCTAssertTrue(paragraphs.contains("  “하나님이 세상을 이처럼 사랑하사”(요한복음 3:16)."))
        // hp:tab → 공백, 여러 런은 이어붙임
        XCTAssertTrue(paragraphs.contains("탭 뒤의 글자와 다음 런이 이어집니다."))
        XCTAssertLessThan(paragraphs.firstIndex(of: "  ** 첫째 대지 제목") ?? 99, paragraphs.firstIndex(of: "  ** 둘째 대지 제목") ?? -1)
    }

    func testHwpxManuscriptPreprocessing() async throws {
        let m = try await ManuscriptLoader().load(try fixture("sample.hwpx"))
        XCTAssertEqual(m.title, "시험 설교 제목")          // 시리즈 번호 (3) 제거
        XCTAssertEqual(m.passage, "요한복음 3장 1~16절")
        XCTAssertEqual(m.headings.map(\.title), ["첫째 대지 제목", "둘째 대지 제목"])
        XCTAssertEqual(m.sentences.map(\.text), [
            "첫 문장입니다.", "둘째 문장입니다.",           // (3:16) 제거
            "“하나님이 세상을 이처럼 사랑하사”.",
            "탭 뒤의 글자와 다음 런이 이어집니다.",
        ])
        XCTAssertEqual(m.headings[0].firstSentenceID, "M1")
        XCTAssertEqual(m.headings[1].firstSentenceID, "M4")
        XCTAssertTrue(m.sentences[2].isScripture)
        XCTAssertEqual(m.sentences[3].sectionIndex, 2)
    }

    func testDocxWithNumberedHeadings() async throws {
        let m = try await ManuscriptLoader().load(try fixture("sample.docx"))
        XCTAssertEqual(m.title, "워드 원고")
        XCTAssertEqual(m.headings.map(\.title), ["첫 번째 요점", "두 번째 요점"])
        // 문단 안 줄바꿈(w:br)은 공백으로 합쳐진다
        XCTAssertEqual(m.sentences.map(\.text), ["본문 문장 하나입니다.", "줄 바꿈 문장입니다."])
    }

    func testHwpIsRejectedWithGuidance() async {
        do {
            _ = try await ManuscriptLoader().load(URL(fileURLWithPath: "/tmp/없음.hwp"))
            XCTFail("hwp는 거부해야 함")
        } catch let e as SermonCutError {
            XCTAssertEqual(e, .hwpBinaryNotSupported)
            XCTAssertTrue(e.localizedDescription.contains("HWPX"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testNumberedHeadingsNeedSequence() {
        // 본문 속 번호(3. …다.)나 순서가 안 맞는 번호는 소제목이 아니다
        let m = ManuscriptPreprocessor.process(paragraphs: [
            "3. 이것은 문장으로 끝납니다.",
            "1. 위기의 순간",
            "내용입니다.",
            "2. 각오",
            "내용입니다.",
        ])
        XCTAssertEqual(m.headings.map(\.title), ["위기의 순간", "각오"])
        XCTAssertEqual(m.sentences.first?.text, "3. 이것은 문장으로 끝납니다.")
    }

    func testNoHeadings() {
        let m = ManuscriptPreprocessor.process(paragraphs: ["그냥 문장입니다. 또 문장입니다.", "", "12"])
        XCTAssertTrue(m.headings.isEmpty)
        XCTAssertEqual(m.sentences.count, 2)   // 빈 문단·쪽번호 제거
        XCTAssertNil(m.title)
    }

    func testSentenceSplitter() {
        XCTAssertEqual(SentenceSplitter.split("첫째입니다. 둘째인가요? 셋째!"), ["첫째입니다.", "둘째인가요?", "셋째!"])
        // 인용 안에서는 끊지 않음
        XCTAssertEqual(SentenceSplitter.split("그는 “가라. 멈추지 마라.”라고 말했습니다. 끝."),
                       ["그는 “가라. 멈추지 마라.”라고 말했습니다.", "끝."])
        // 말줄임은 끝이 아님
        XCTAssertEqual(SentenceSplitter.split("‘굳이 내가 하지 않아도...’라고 생각합니다."), ["‘굳이 내가 하지 않아도...’라고 생각합니다."])
        // 숫자 소수점
        XCTAssertEqual(SentenceSplitter.split("3.5절 말씀입니다."), ["3.5절 말씀입니다."])
    }

    func testCleanRemovesVerseReferencesAndMemos() {
        XCTAssertEqual(ManuscriptPreprocessor.clean("조서를 내렸습니다.(3:13) [찬송] 그리고 (잠시 침묵) 말했습니다(4:10~11)."),
                       "조서를 내렸습니다. 그리고 말했습니다.")
        XCTAssertEqual(ManuscriptPreprocessor.clean("“죽으면 죽으리이다”(에스더 4:16)."), "“죽으면 죽으리이다”.")
    }
}
