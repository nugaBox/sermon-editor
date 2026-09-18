import XCTest
@testable import SermonCutCore

final class RenderPlanTests: XCTestCase {
    let media = MediaInfo(durationSeconds: 5506.133333, frameRateNum: 30, frameRateDen: 1, width: 1920, height: 1080, hasAudio: true)

    func edl() throws -> EditDecisionList {
        var s = ExportSettings()
        s.padHead = 0; s.padTail = 0; s.snapToSilence = false
        var segs = [TranscriptSegment(id: "T1", start: 100, end: 110, text: "a"),
                    TranscriptSegment(id: "T2", start: 110, end: 130, text: "b"),
                    TranscriptSegment(id: "T3", start: 130, end: 150, text: "c"),
                    TranscriptSegment(id: "T4", start: 150, end: 150.6, text: "d"),
                    TranscriptSegment(id: "T5", start: 150.6, end: 160, text: "e")]
        segs[1].isRemoved = true
        segs[3].isRemoved = true
        return try EDLBuilder.build(segments: segs, silences: [], sourceRange: TimeRange(start: 0, end: 1000), media: media, settings: s)
    }

    func testPlanUsesHandlesSoLengthMatchesFCPXML() throws {
        let e = try edl()
        // 클립: 100-110, 130-150, 150.6-160 / 편집점1 디졸브 30f, 편집점2 간격 0.6초 → 하드컷
        XCTAssertEqual(e.clips.count, 3)
        let plan = FFmpegRenderer.plan(edl: e, options: .init(preset: .preview, audioGainDB: 12))
        XCTAssertEqual(plan.duration, FrameSnapper(media: media).seconds(e.totalFrames), accuracy: 1e-6)   // 39.4초
        XCTAssertEqual(plan.inputs[0].start, 100, accuracy: 1e-9)
        XCTAssertEqual(plan.inputs[0].duration, 10.5, accuracy: 1e-9)      // 뒤 핸들 0.5초
        XCTAssertEqual(plan.inputs[1].start, 129.5, accuracy: 1e-9)        // 앞 핸들 0.5초
        XCTAssertEqual(plan.inputs[1].duration, 20.5, accuracy: 1e-9)      // 뒤는 하드컷이라 핸들 없음
        XCTAssertTrue(plan.filter.contains("xfade=transition=fade:duration=1.000000:offset=9.500000"))
        XCTAssertTrue(plan.filter.contains("[vx1][v2]concat=n=2:v=1:a=0"))
        XCTAssertTrue(plan.filter.contains("volume=12.0dB"))
        XCTAssertTrue(plan.filter.contains("scale=960:540"))
        XCTAssertTrue(plan.filter.hasSuffix("[aout]"))
    }

    func testFinalPresetKeepsResolution() throws {
        let plan = FFmpegRenderer.plan(edl: try edl(), options: .init(preset: .final, audioGainDB: 0))
        XCTAssertTrue(plan.filter.contains("scale=1920:1080"))
    }
}
