import XCTest
@testable import SermonCutCore

final class RangeFinderTests: XCTestCase {
    func sample(_ t: Double, _ lines: [String], x: Double = 0.1, y: Double = 0.2) -> ScreenTextSample {
        ScreenTextSample(time: t, lines: lines.enumerated().map { i, text in
            .init(text: text, x: x, y: y + Double(i) * 0.03, w: 0.3, h: 0.03, confidence: 0.9)
        })
    }

    /// 09/13 화면 순서를 줄인 가상 스캔
    func scan() -> ScreenTextScan {
        var s: [ScreenTextSample] = []
        // 예배 전 주보(줄 많음) — 순서표 속 "성경 봉독"은 무시해야 한다
        s.append(sample(60, ["예배 순서", "성경 봉독"] + (0..<20).map { "주보 줄 \($0)" }))
        s.append(sample(2130, ["대표 기도", "김철수 장로"]))
        s.append(sample(2136, ["대표 기도", "김철수 장로"]))
        s.append(sample(2142, ["성경 봉독", "에스더 4장 1~17절 구약 754쪽"]))
        s.append(sample(2148, ["성경 봉독", "에스더 4장 1~17절 구약 754쪽"]))
        for t in stride(from: 2640.0, through: 4950, by: 6) {
            var smp = sample(t, ["주일낮예배 설교 | 강해 (7)", "믿음의 사람이 세상을 돌파한다", "설교 : 홍길동 목사 / 본문 : 에스더 4장 1~17절"])
            smp.lines[1].h = 0.06
            smp.lines += [ScreenTextSample.Line(text: "1. 위기의 순간", x: 0.7, y: 0.3, w: 0.2, h: 0.02, confidence: 0.9),
                          ScreenTextSample.Line(text: "2. 각오로", x: 0.7, y: 0.27, w: 0.2, h: 0.02, confidence: 0.9)]
            s.append(smp)
        }
        s.append(sample(4956, ["봉헌 찬송", "찬송가 329장"]))
        s.append(sample(5100, ["교단 총회", "기도해 주시기 바랍니다"]))
        return ScreenTextScan(interval: 6, samples: s)
    }

    func testSuggestsReadingToOffering() throws {
        let voice = [TranscriptSegment(id: "T1", start: 2157.8, end: 2170, text: "4장 1절 말씀부터 제가 읽어드리겠습니다")]
        let r = RangeFinder.find(screen: scan(), transcript: voice)
        let s = try XCTUnwrap(r.suggested)
        XCTAssertEqual(s.start, 2157.8, accuracy: 1e-9)        // 봉독 화면 뒤 60초 안의 안내 음성
        XCTAssertEqual(s.end, 4953, accuracy: 1e-9)            // 설교 자막이 사라진 곳 (4950 + 3)
        XCTAssertFalse(r.starts.contains { $0.time == 60 })    // 주보 속 순서표는 후보 아님
        XCTAssertEqual(r.metadata?.title, "믿음의 사람이 세상을 돌파한다")
        XCTAssertEqual(r.metadata?.passage, "에스더 4장 1~17절")
        XCTAssertEqual(r.metadata?.preacher, "홍길동 목사")
        XCTAssertEqual(r.metadata?.serviceLabel, "주일낮예배 설교 | 강해 (7)")
        XCTAssertEqual(r.metadata?.outline, ["1. 위기의 순간", "2. 각오로"])
    }

    func testScreenOnlyWithoutVoice() throws {
        let r = RangeFinder.find(screen: scan(), transcript: nil)
        XCTAssertEqual(try XCTUnwrap(r.suggested).start, 2142, accuracy: 1e-9)
    }

    func testClosingAnnouncementIsSuggestedForRemoval() {
        let sentences = [ManuscriptSentence(id: "M1", text: "원고 문장 번호 일번 내용은 이러합니다 가나다라", order: 0, sectionIndex: 0, isScripture: false)]
        let segs = [TranscriptSegment(id: "T1", start: 100, end: 110, text: "원고 문장 번호 일번 내용은 이러합니다 가나다라"),
                    TranscriptSegment(id: "T2", start: 110, end: 115, text: "찬송가 329장을 찬송하시면서 봉헌하십시오")]
        let out = RemovalSuggester().apply(segments: segs, alignment: LocalAligner().align(segments: segs, sentences: sentences),
                                           sentences: sentences, sourceRange: TimeRange(start: 100, end: 116))
        XCTAssertFalse(out.segments[0].isRemoved)
        XCTAssertTrue(out.segments[1].isRemoved)
        XCTAssertEqual(out.segments[1].unmatchedReason, .greeting)
    }
}
