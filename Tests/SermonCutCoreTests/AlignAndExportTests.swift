import XCTest
@testable import SermonCutCore

final class AlignAndExportTests: XCTestCase {
    func sentence(_ n: Int, _ text: String, section: Int = 1) -> ManuscriptSentence {
        ManuscriptSentence(id: "M\(n)", text: text, order: n - 1, sectionIndex: section, isScripture: false)
    }

    func seg(_ n: Int, _ s: Double, _ e: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(id: "T\(n)", start: s, end: e, text: text)
    }

    // MARK: 정렬

    func testMonotonicAlignmentWithImprovisation() {
        let sentences = [
            sentence(1, "에스더서 4장은 유다인 학살 음모가 구체화됩니다."),
            sentence(2, "이 소식을 들은 유다인들은 대성통곡했습니다."),
            sentence(3, "우리는 날마다 영적 전쟁을 하며 살아갑니다."),
        ]
        let segments = [
            seg(1, 0, 5, "에스더 4장은 유다인들의 학살 음모가 구체화되고 있어요"),
            seg(2, 5, 9, "지금 우리나라에 코로나가 굉장히 급속도로 퍼집니다"),
            seg(3, 9, 12, "이 소식을 들은 유대인들의 반응은 대성통곡입니다"),
            seg(4, 12, 13, "아멘"),
            seg(5, 13, 18, "우리는 날마다 영적 전쟁을 하면서 살아갑니다"),
        ]
        let r = LocalAligner().align(segments: segments, sentences: sentences)
        XCTAssertEqual(r.map(\.sentenceID), ["M1", nil, "M2", nil, "M3"])
        XCTAssertEqual(r[1].status, .unmatched)
        XCTAssertTrue(r[3].undetermined)   // 너무 짧음
    }

    func testAlignmentDoesNotGoBackwards() {
        // 뒤 문장을 먼저 말한 뒤 앞 문장과 비슷한 말이 나와도 역행 매칭하지 않는다
        let sentences = [sentence(1, "하나님의 주권과 섭리를 믿었습니다."), sentence(2, "에스더는 모르드개에게 명령했습니다.")]
        let segments = [seg(1, 0, 4, "에스더는 모르드개에게 명령했습니다"), seg(2, 4, 8, "하나님의 주권과 섭리를 믿었습니다")]
        let r = LocalAligner().align(segments: segments, sentences: sentences)
        XCTAssertEqual(r.filter { $0.status == .matched }.count, 1)
    }

    // MARK: 삭제 제안

    func testLongUnmatchedRunIsSuggestedShortOneKept() {
        let sentences = (1...6).map { sentence($0, "원고 문장 번호 \($0)번 내용은 이러합니다 가나다라마바사 \($0)") }
        var segs: [TranscriptSegment] = []
        var t = 0.0
        func add(_ text: String, _ d: Double) { segs.append(seg(segs.count + 1, t, t + d, text)); t += d }
        add("원고 문장 번호 1번 내용은 이러합니다 가나다라마바사 1", 5)
        add("잠깐 다른 얘기를 하자면 오늘 날씨가", 6)                 // 짧은 부연 → 유지
        add("원고 문장 번호 2번 내용은 이러합니다 가나다라마바사 2", 5)
        for k in 0..<8 { add("교단 총회 소식을 전하겠습니다 이번 주 월요일 \(k)", 5) } // 40초 탈선 → 삭제
        add("원고 문장 번호 3번 내용은 이러합니다 가나다라마바사 3", 5)
        let align = LocalAligner().align(segments: segs, sentences: sentences)
        let out = RemovalSuggester().apply(segments: segs, alignment: align, sourceRange: TimeRange(start: 0, end: t), hasManuscript: true)
        XCTAssertEqual(out.suggestions.count, 1)
        XCTAssertEqual(out.suggestions[0].range.start, 16, accuracy: 1e-9)
        XCTAssertEqual(out.suggestions[0].range.end, 56, accuracy: 1e-9)
        XCTAssertFalse(out.segments[1].isRemoved)
        XCTAssertTrue(out.segments[5].isRemoved)
        XCTAssertEqual(out.segments[5].unmatchedReason, .improvised)
    }

    func testOpeningReadingIsProtected() {
        let sentences = (1...3).map { sentence($0, "원고 문장 번호 \($0)번 내용은 이러합니다 가나다라마바사") }
        var segs: [TranscriptSegment] = []
        var t = 0.0
        func add(_ text: String, _ d: Double) { segs.append(seg(segs.count + 1, t, t + d, text)); t += d }
        add("에스더 4장 1절 말씀부터 17절까지 제가 읽어드리겠습니다", 10)
        for k in 0..<10 { add("성경 본문 낭독 내용 구절 \(k) 모르드개가 옷을 찢고", 10) }
        add("아멘", 1)
        add("원고 문장 번호 1번 내용은 이러합니다 가나다라마바사", 5)
        let align = LocalAligner().align(segments: segs, sentences: sentences)
        let out = RemovalSuggester().apply(segments: segs, alignment: align, sourceRange: TimeRange(start: 0, end: t), hasManuscript: true)
        XCTAssertEqual(out.readingRange?.end ?? 0, 111, accuracy: 1e-9)
        XCTAssertTrue(out.suggestions.isEmpty)
        XCTAssertFalse(out.segments.contains { $0.isRemoved })
    }

    func testNoManuscriptMeansNoSuggestions() {
        let segs = [seg(1, 0, 100, "아무 말")]
        let out = RemovalSuggester().apply(segments: segs, alignment: LocalAligner().align(segments: segs, sentences: []),
                                           sourceRange: TimeRange(start: 0, end: 100), hasManuscript: false)
        XCTAssertTrue(out.suggestions.isEmpty)
        XCTAssertEqual(out.segments[0].alignStatus, .notAligned)
    }

    func testUserOverrideIsRespected() {
        let sentences = [sentence(1, "원고 문장 번호 일번 내용은 이러합니다 가나다라마바사")]
        var segs = (0..<10).map { seg($0 + 1, Double($0) * 5, Double($0 + 1) * 5, "원고와 전혀 상관없는 다른 이야기 \($0)") }
        segs[3].userOverridden = true
        let out = RemovalSuggester().apply(segments: segs, alignment: LocalAligner().align(segments: segs, sentences: sentences),
                                           sourceRange: TimeRange(start: 0, end: 50), hasManuscript: true)
        XCTAssertFalse(out.segments[3].isRemoved)
        XCTAssertTrue(out.segments[2].isRemoved)
    }

    // MARK: FCPXML

    func makeEDL() throws -> EditDecisionList {
        let media = MediaInfo(durationSeconds: 5506.133333, frameRateNum: 30, frameRateDen: 1, width: 1920, height: 1080,
                              hasAudio: true, audioSampleRate: 48000, audioChannels: 2)
        var s = ExportSettings()
        s.padHead = 0; s.padTail = 0; s.snapToSilence = false
        let segs: [TranscriptSegment] = [
            { var t = TranscriptSegment(id: "T1", start: 2162.5667, end: 2378.2667, text: "a"); return t }(),
            { var t = TranscriptSegment(id: "T2", start: 2378.2667, end: 2632, text: "b"); t.isRemoved = true; return t }(),
            TranscriptSegment(id: "T3", start: 2632, end: 3287.7667, text: "c"),
            { var t = TranscriptSegment(id: "T4", start: 3287.7667, end: 3288.4, text: "d"); t.isRemoved = true; return t }(),
            TranscriptSegment(id: "T5", start: 3288.4, end: 3300, text: "e"),
        ]
        return try EDLBuilder.build(segments: segs, silences: [], sourceRange: TimeRange(start: 2160, end: 4956), media: media, settings: s)
    }

    func testFCPXMLStructureMatchesVerifiedForm() throws {
        let edl = try makeEDL()
        var opt = FCPXMLExporter.Options(eventName: "SermonCut", projectName: "테스트 & <프로젝트>", audioGainDB: 12)
        opt.chapterMarkers = [(2700, "1. 위기의 순간")]
        let xml = FCPXMLExporter().export(edl: edl, videoURL: URL(fileURLWithPath: "/tmp/20260913-주일낮예배 스트리밍.mp4"), options: opt)
        XCTAssertTrue(xml.contains("<fcpxml version=\"1.14\">"))
        XCTAssertTrue(xml.contains("frameDuration=\"100/3000s\""))
        XCTAssertTrue(xml.contains("start=\"6487700/3000s\" duration=\"647100/3000s\""))   // 완성본 클립 1과 동일
        XCTAssertTrue(xml.contains("<transition name=\"교차 디졸브\" offset=\"645600/3000s\" duration=\"3000/3000s\">"))
        XCTAssertTrue(xml.contains("uid=\"FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265\""))
        XCTAssertTrue(xml.contains("<adjust-volume amount=\"12dB\"/>"))
        XCTAssertTrue(xml.contains("테스트 &amp; &lt;프로젝트&gt;"))
        XCTAssertTrue(xml.contains("<chapter-marker start=\"8100000/3000s\""))
        // 두 번째 편집점은 간격 0.63초(병합 기준 0.5초 초과, 디졸브 1초 미만) → 하드컷 (transition 1개만)
        XCTAssertEqual(xml.components(separatedBy: "<transition ").count - 1, 1)
        XCTAssertEqual(edl.handleShortageCount, 1)
    }

    /// FCP가 설치돼 있으면 번들 DTD로 검증
    func testFCPXMLValidatesAgainstFinalCutDTD() async throws {
        let dtdDir = "/Applications/Final Cut Pro Creator Studio.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_14.dtd"
        let alt = "/Applications/Final Cut Pro.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_14.dtd"
        guard let dtd = [dtdDir, alt].first(where: FileManager.default.fileExists) else {
            throw XCTSkip("Final Cut Pro DTD 없음")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sermoncut-dtd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dtdCopy = tmp.appendingPathComponent("fcpxml.dtd")    // 경로 공백 회피
        try FileManager.default.copyItem(atPath: dtd, toPath: dtdCopy.path)
        var opt = FCPXMLExporter.Options(eventName: "E", projectName: "P", audioGainDB: 12)
        opt.chapterMarkers = [(2700, "1. 제목")]
        let xmlURL = tmp.appendingPathComponent("out.fcpxml")
        try FCPXMLExporter().export(edl: try makeEDL(), videoURL: URL(fileURLWithPath: "/tmp/a b.mp4"), options: opt)
            .write(to: xmlURL, atomically: true, encoding: .utf8)
        let xmllint = try BinaryLocator().url(for: .xmllint)
        let r = try await ProcessRunner.run(xmllint, ["--noout", "--dtdvalid", dtdCopy.path, xmlURL.path], allowNonZeroExit: true)
        XCTAssertEqual(r.exitCode, 0, r.stderrString)
    }

    func testProcessRunnerCancellation() async throws {
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"])
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let started = Date()
        do {
            _ = try await task.value
            XCTFail("취소돼야 함")
        } catch let e as SermonCutError {
            XCTAssertEqual(e, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testProcessRunnerStreamsLines() async throws {
        final class Box: @unchecked Sendable { var lines: [String] = []; let lock = NSLock() }
        let box = Box()
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'a\\nb\\n'; printf 'c' 1>&2; exit 0"],
                                            onStdoutLine: { l in box.lock.lock(); box.lines.append(l); box.lock.unlock() })
        XCTAssertEqual(box.lines, ["a", "b"])
        XCTAssertEqual(r.stderrString, "c")
    }

    func testProcessFailureIsReportedInKorean() async {
        do {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo 문제 >&2; exit 3"], toolName: "sh")
            XCTFail()
        } catch let e as SermonCutError {
            XCTAssertEqual(e, .processFailed(tool: "sh", exitCode: 3, stderrTail: "문제"))
            XCTAssertTrue(e.localizedDescription.contains("실패"))
        } catch { XCTFail("\(error)") }
    }

    func testMediaProbeParseIgnoresCoverArt() throws {
        let json = """
        {"streams":[{"codec_type":"video","r_frame_rate":"30/1","width":1920,"height":1080,"disposition":{"attached_pic":0}},
                    {"codec_type":"audio","sample_rate":"48000","channels":2},
                    {"codec_type":"video","r_frame_rate":"90000/1","width":1920,"height":1080,"disposition":{"attached_pic":1}}],
         "format":{"duration":"2164.233333"}}
        """
        let m = try MediaProbe.parse(Data(json.utf8))
        XCTAssertEqual(m.frameRateNum, 30)
        XCTAssertEqual(m.frameRateDen, 1)
        XCTAssertEqual(m.durationSeconds, 2164.233333, accuracy: 1e-6)
        XCTAssertEqual(m.audioSampleRate, 48000)
    }
}
