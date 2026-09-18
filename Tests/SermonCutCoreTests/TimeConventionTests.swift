import XCTest
@testable import SermonCutCore

/// SPEC §4 타임스탬프 규약: 모든 시간은 원본 영상 0초 기준, 보정은 파싱 직후 한 번만.
final class TimeConventionTests: XCTestCase {
    let whisperJSON = """
    {"result":{"language":"ko"},"transcription":[
      {"timestamps":{"from":"00:00:01,250","to":"00:00:04,000"},"offsets":{"from":1250,"to":4000},"text":" 첫 세그먼트입니다",
       "tokens":[{"text":" 첫","offsets":{"from":1250,"to":1800},"p":0.9},{"text":" 세그","offsets":{"from":1800,"to":2600},"p":0.8},
                 {"text":"먼트입니다","offsets":{"from":2600,"to":4000},"p":0.7},{"text":"[_TT_200]","offsets":{"from":4000,"to":4000},"p":0.1}]},
      {"offsets":{"from":4000,"to":9500},"text":" 둘째","tokens":[{"text":" 둘째","offsets":{"from":100,"to":900},"p":0.9}]},
      {"offsets":{"from":9500,"to":9500},"text":" 길이 0은 버림"},
      {"offsets":{"from":9600,"to":9900},"text":"   "}
    ]}
    """

    func testWhisperOffsetIsAppliedOnceAtParse() throws {
        let segs = try TranscriptParser.parse(Data(whisperJSON.utf8), sourceStart: 1234.5)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].id, "T1")
        XCTAssertEqual(segs[0].start, 1234.5 + 1.25, accuracy: 1e-9)   // SPEC §4 필수 테스트
        XCTAssertEqual(segs[0].end, 1234.5 + 4.0, accuracy: 1e-9)
        XCTAssertEqual(segs[1].start, 1234.5 + 4.0, accuracy: 1e-9)
        XCTAssertEqual(segs[0].text, "첫 세그먼트입니다")
    }

    func testWordTimingsAreAbsoluteAndJoined() throws {
        let segs = try TranscriptParser.parse(Data(whisperJSON.utf8), sourceStart: 1234.5)
        let words = try XCTUnwrap(segs[0].words)
        XCTAssertEqual(words.map(\.text), ["첫", "세그먼트입니다"])
        XCTAssertEqual(words[1].start, 1234.5 + 1.8, accuracy: 1e-9)
        XCTAssertEqual(words[1].end, 1234.5 + 4.0, accuracy: 1e-9)
    }

    func testWordTimingsDroppedWhenOutsideSegment() throws {
        // VAD 사용 시 whisper.cpp가 토큰 시간을 원래 시간축으로 안 돌리는 문제 → 단어 타이밍 버림
        let segs = try TranscriptParser.parse(Data(whisperJSON.utf8), sourceStart: 0)
        XCTAssertNil(segs[1].words)
    }

    func testInvalidUTF8IsTolerated() throws {
        var data = Data(#"{"transcription":[{"offsets":{"from":0,"to":1000},"text":"가"#.utf8)
        data.append(0xEA) // 잘린 UTF-8
        data.append(contentsOf: Array(#"나"}]}"#.utf8))
        let segs = try TranscriptParser.parse(data, sourceStart: 10)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 10)
    }

    func testSilenceOffsetIsAppliedOnce() {
        let log = """
        [silencedetect @ 0x1] silence_start: 1.5
        [silencedetect @ 0x1] silence_end: 2.25 | silence_duration: 0.75
        [silencedetect @ 0x1] silence_start: -0.01
        [silencedetect @ 0x1] silence_end: 0.4 | silence_duration: 0.41
        """
        let r = SilenceDetector.parse(log, sourceStart: 1234.5)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].start, 1236.0, accuracy: 1e-9)
        XCTAssertEqual(r[0].end, 1236.75, accuracy: 1e-9)
        XCTAssertEqual(r[1].start, 1234.5, accuracy: 1e-9) // 음수 시작은 0으로
    }

    func testTimecodeParseAndFormat() {
        XCTAssertEqual(Timecode.parse("1:22:33.4") ?? 0, 4953.4, accuracy: 1e-9)
        XCTAssertEqual(Timecode.parse("36:02.567") ?? 0, 2162.567, accuracy: 1e-9)
        XCTAssertEqual(Timecode.parse("4953"), 4953)
        XCTAssertNil(Timecode.parse("a:b"))
        XCTAssertEqual(Timecode.format(2632), "43:52.000")
        XCTAssertEqual(Timecode.format(4953.367, millis: false), "1:22:33")
    }
}
