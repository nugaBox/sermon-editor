import XCTest
@testable import SermonCutCore

final class EditTests: XCTestCase {
    let media30 = MediaInfo(durationSeconds: 5506.133333, frameRateNum: 30, frameRateDen: 1, width: 1920, height: 1080,
                            hasAudio: true, audioSampleRate: 48000, audioChannels: 2)
    let media2997 = MediaInfo(durationSeconds: 600, frameRateNum: 30000, frameRateDen: 1001, width: 1920, height: 1080, hasAudio: true)

    func seg(_ id: String, _ s: Double, _ e: Double, removed: Bool = false) -> TranscriptSegment {
        var t = TranscriptSegment(id: id, start: s, end: e, text: id)
        t.isRemoved = removed
        return t
    }

    func settings(pad: Double = 0, snap: Bool = false, transition: Double = 1.0) -> ExportSettings {
        var s = ExportSettings()
        s.padHead = pad; s.padTail = pad; s.snapToSilence = snap; s.transitionDuration = transition
        return s
    }

    // MARK: 프레임 스냅 (docs/fcpxml-reference.md §1)

    func testFrameTimeStrings30fps() {
        let snap = FrameSnapper(media: media30)
        XCTAssertEqual(snap.frame(2162.5667), 64877)
        XCTAssertEqual(snap.fcpTime(frames: 64877), "6487700/3000s")   // 09/13 완성본 클립 1 start 와 동일
        XCTAssertEqual(snap.fcpTime(frames: 0), "0s")
        XCTAssertEqual(snap.frameDurationString, "100/3000s")
    }

    func testFrameTimeStrings2997() {
        let snap = FrameSnapper(media: media2997)
        XCTAssertEqual(snap.frameDurationString, "1001/30000s")
        XCTAssertEqual(snap.fcpTime(frames: 30), "30030/30000s")
        XCTAssertEqual(snap.seconds(30), 1.001, accuracy: 1e-9)
    }

    // MARK: EDL (SPEC §6.1)

    func testMergeAndRemoveProducesTwoClips() throws {
        let segs = [seg("T1", 100, 110), seg("T2", 110.3, 120), seg("T3", 120, 150, removed: true), seg("T4", 150, 160)]
        let edl = try EDLBuilder.build(segments: segs, silences: [], sourceRange: TimeRange(start: 90, end: 200),
                                       media: media30, settings: settings())
        XCTAssertEqual(edl.clips.count, 2)
        XCTAssertEqual(edl.clips[0].sourceStartFrame, 3000)
        XCTAssertEqual(edl.clips[0].sourceEndFrame, 3600)
        XCTAssertEqual(edl.clips[0].segmentIDs, ["T1", "T2"])
        XCTAssertEqual(edl.clips[1].timelineOffsetFrame, 600)   // 겹침 없이 이어붙임
        XCTAssertEqual(edl.totalFrames, 900)
        XCTAssertEqual(edl.transitions.count, 1)
        XCTAssertEqual(edl.transitions[0].durationFrames, 30)
        XCTAssertFalse(edl.transitions[0].handleShortage)
    }

    func testClampToSourceRange() throws {
        // 패딩이 설교 구간 밖(대표기도·봉헌기도)으로 나가면 안 된다 (SPEC §6.1-5)
        let segs = [seg("T1", 100.1, 120), seg("T2", 180, 199.9)]
        let edl = try EDLBuilder.build(segments: segs, silences: [], sourceRange: TimeRange(start: 100, end: 200),
                                       media: media30, settings: settings(pad: 2))
        XCTAssertEqual(edl.clips.first?.sourceStartFrame, 3000)
        XCTAssertEqual(edl.clips.last?.sourceEndFrame, 6000)
    }

    func testHandleShortageFallsBackToHardCut() throws {
        let segs = [seg("T1", 100, 110), seg("T2", 110, 110.6, removed: true), seg("T3", 110.6, 120)]
        let edl = try EDLBuilder.build(segments: segs, silences: [], sourceRange: TimeRange(start: 0, end: 500),
                                       media: media30, settings: settings())
        XCTAssertEqual(edl.clips.count, 2)
        XCTAssertEqual(edl.transitions[0].durationFrames, 0)
        XCTAssertTrue(edl.transitions[0].handleShortage)
        XCTAssertEqual(edl.handleShortageCount, 1)
    }

    func testHandleShortageShrinksWhenFallbackOff() throws {
        var s = settings()
        s.fallbackToHardCut = false
        let segs = [seg("T1", 100, 110), seg("T2", 110, 110.6, removed: true), seg("T3", 110.6, 120)]
        let edl = try EDLBuilder.build(segments: segs, silences: [], sourceRange: TimeRange(start: 0, end: 500), media: media30, settings: s)
        // 간격 18프레임 × 0.8 = 14.4 → 짝수 14
        XCTAssertEqual(edl.transitions[0].durationFrames, 14)
    }

    func testSnapToSilenceDoesNotCutIntoSpeech() throws {
        var s = settings(pad: 0.25, snap: true)
        s.snapWindow = 1.0
        let segs = [seg("T1", 100, 110), seg("T2", 110, 130, removed: true), seg("T3", 130, 140)]
        let silences = [TimeRange(start: 109.0, end: 109.4),   // 말소리 끝 이전 → 무시해야 함
                        TimeRange(start: 110.2, end: 110.8),   // 끝 경계 후보 (중앙 110.5)
                        TimeRange(start: 129.2, end: 129.6)]   // 시작 경계 후보 (중앙 129.4)
        let edl = try EDLBuilder.build(segments: segs, silences: silences, sourceRange: TimeRange(start: 0, end: 500), media: media30, settings: s)
        XCTAssertEqual(edl.clips[0].sourceEndFrame, 3315)   // 110.5s
        XCTAssertEqual(edl.clips[1].sourceStartFrame, 3882)  // 129.4s
    }

    func testNaturalPausesAreNotCut() throws {
        // 삭제 세그먼트가 없으면 세그먼트 사이 3초 쉼도 자르지 않는다
        let segs = [seg("T1", 100, 110), seg("T2", 113, 120), seg("T3", 121, 130)]
        let edl = try EDLBuilder.build(segments: segs, silences: [], sourceRange: TimeRange(start: 0, end: 500), media: media30, settings: settings())
        XCTAssertEqual(edl.clips.count, 1)
        XCTAssertEqual(edl.clips[0].durationFrames, 900)
    }

    func testAllRemovedThrows() {
        XCTAssertThrowsError(try EDLBuilder.build(segments: [seg("T1", 0, 1, removed: true)], silences: [],
                                                  sourceRange: TimeRange(start: 0, end: 10), media: media30, settings: settings()))
    }

    func testTimelineMapping() throws {
        let segs = [seg("T1", 100, 110), seg("T2", 110, 150, removed: true), seg("T3", 150, 160)]
        let edl = try EDLBuilder.build(segments: segs, silences: [], sourceRange: TimeRange(start: 0, end: 500), media: media30, settings: settings())
        XCTAssertEqual(edl.timelineSeconds(forSource: 105) ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(edl.timelineSeconds(forSource: 120) ?? -1, 10, accuracy: 1e-9)  // 삭제 구간 → 다음 클립 시작
        XCTAssertEqual(edl.timelineSeconds(forSource: 155) ?? -1, 15, accuracy: 1e-9)
    }

    // MARK: 기준 편집 읽기

    func testReferenceReaderParsesUserClipStructure() throws {
        let xml = """
        <fcpxml version="1.14"><resources>
          <asset id="r4" name="Title"/><asset id="r9" name="20260913-주일낮예배 스트리밍"/></resources>
          <library><event><project><sequence><spine>
            <video ref="r4" offset="0s" start="3600s" duration="60400/6000s"/>
            <clip offset="30200/3000s" name="20260913-주일낮예배 스트리밍" start="6487700/3000s" duration="647100/3000s">
              <video ref="r9" offset="0s" duration="84575744/15360s"/>
              <clip lane="-1" offset="1557048531/720000s" start="1556972498/720000s" duration="155303469/720000s"/>
            </clip>
            <transition offset="675800/3000s" duration="1s"/>
            <asset-clip ref="r9" offset="677300/3000s" start="2632s" duration="1967300/3000s"/>
          </spine></sequence></project></event></library></fcpxml>
        """
        let ranges = try ReferenceEDLReader.keptRanges(fcpxml: Data(xml.utf8), assetName: "20260913-주일낮예배 스트리밍")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].start, 2162.5667, accuracy: 1e-3)
        XCTAssertEqual(ranges[0].end, 2378.2667, accuracy: 1e-3)
        XCTAssertEqual(ranges[1].start, 2632, accuracy: 1e-9)
    }

    func testEditComparison() {
        let ref = [TimeRange(start: 0, end: 10), TimeRange(start: 20, end: 30)]
        let pre = [TimeRange(start: 0, end: 12), TimeRange(start: 20, end: 30)]
        let c = EditComparison.compare(reference: ref, predicted: pre, window: TimeRange(start: 0, end: 30))
        XCTAssertEqual(c.referenceRemoved, 10, accuracy: 0.11)
        XCTAssertEqual(c.predictedRemoved, 8, accuracy: 0.11)
        XCTAssertEqual(c.recall, 0.8, accuracy: 0.02)
        XCTAssertEqual(c.precision, 1.0, accuracy: 0.02)
    }
}
