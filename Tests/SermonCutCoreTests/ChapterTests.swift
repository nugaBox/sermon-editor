import XCTest
@testable import SermonCutCore

final class ChapterTests: XCTestCase {
    let media = MediaInfo(durationSeconds: 5506, frameRateNum: 30, frameRateDen: 1, width: 1920, height: 1080, hasAudio: true)

    func testParseOutlineStripsNumbersAndTimes() {
        let text = """
        00:00 성경봉독
        03:45 1. 위기의 순간 드러나는 참신앙
        18:15 2."죽으면 죽으리이다"의 각오로
        ** 죽기를 각오한 기도
        첫째, 넷째 제목

        """
        XCTAssertEqual(ChapterBuilder.parseOutline(text),
                       ["위기의 순간 드러나는 참신앙", "\"죽으면 죽으리이다\"의 각오로", "죽기를 각오한 기도", "넷째 제목"])
    }

    func project() -> SermonProject {
        var segs: [TranscriptSegment] = []
        for i in 0..<60 { segs.append(TranscriptSegment(id: "T\(i + 1)", start: 1000 + Double(i) * 10, end: 1010 + Double(i) * 10, text: "말 \(i)")) }
        return SermonProject(videoPath: "/tmp/v.mp4", manuscriptPath: nil, media: media, sourceRange: TimeRange(start: 1000, end: 1600),
                             segments: segs, manuscript: nil, silences: [])
    }

    func testOverlayOnlyWithLagAndOutputMapping() {
        var p = project()
        // 유지: 1000~1200, 1300~1600 (1200~1300 삭제)
        let edl = EditDecisionList.fromKeptRanges([TimeRange(start: 1000, end: 1200), TimeRange(start: 1300, end: 1600)], media: media)
        p.screenOutline = ["1. 첫째 대지", "2. 둘째 대지"]
        let overlay = [ChapterBuilder.OverlayChange(number: 1, title: "첫째 대지", time: 1015),
                       ChapterBuilder.OverlayChange(number: 2, title: "둘째 대지", time: 1403)]
        var o = ChapterBuilder.Options()
        o.introDuration = 10
        let list = ChapterBuilder.build(project: p, edl: edl, overlay: overlay, overlayOutline: p.screenOutline ?? [], options: o)
        XCTAssertEqual(list.map(\.title), ["첫째 대지", "둘째 대지"])
        // 1장: 1015-3=1012 → 가까운 말 시작 1010 → 첫 대지는 30초 안 앞 편집점(1000)으로 → 출력 0+10
        XCTAssertEqual(list[0].outputTime, 10)
        // 2장: 1403-3=1400 → 말 시작 1400 → 출력 200 + (1400-1300) + 10 = 310
        XCTAssertEqual(list[1].outputTime, 310)
        XCTAssertEqual(list[1].timeSource, .overlay)
        XCTAssertEqual(ChapterBuilder.youtubeText(list, options: o), "00:00 성경봉독\n00:10 1. 첫째 대지\n05:10 2. 둘째 대지")
    }

    func testManualOverrideWins() {
        var p = project()
        p.chapterOutlineText = "1. 하나\n2. 둘"
        p.chapterTimeOverrides = [2: 1500]
        let edl = EditDecisionList.fromKeptRanges([TimeRange(start: 1000, end: 1600)], media: media)
        var o = ChapterBuilder.Options()
        o.introDuration = 0
        let list = ChapterBuilder.build(project: p, edl: edl, options: o)
        XCTAssertEqual(list[1].timeSource, .manual)
        XCTAssertEqual(list[1].outputTime, 500)
        XCTAssertNotNil(list[0].warning)   // 1장은 시간 출처가 없음
    }

    func testRemovedRegionMapsToNextClip() {
        let edl = EditDecisionList.fromKeptRanges([TimeRange(start: 1000, end: 1200), TimeRange(start: 1300, end: 1600)], media: media)
        var o = ChapterBuilder.Options()
        o.introDuration = 0
        XCTAssertEqual(ChapterBuilder.outputTime(1250, edl: edl, options: o), 200)
        XCTAssertEqual(ChapterBuilder.outputTime(1300.6, edl: edl, options: o), 200)   // 편집점 1초 안 → 편집점
        XCTAssertEqual(ChapterBuilder.clock(3725), "1:02:05")
    }
}
