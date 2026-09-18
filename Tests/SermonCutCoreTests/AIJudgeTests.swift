import XCTest
@testable import SermonCutCore

/// 실제 API 없이 동작하는 가짜 제공자
final class MockProvider: AIProvider, @unchecked Sendable {
    let displayName = "Mock"
    let model = "mock-1"
    private let lock = NSLock()
    private var responses: [String]
    private(set) var calls: [String] = []
    var failWith: AIError?
    var failTimes = 0

    init(_ responses: [String]) { self.responses = responses }

    func complete(system: String, user: String, maxTokens: Int) async throws -> AICompletion {
        lock.lock(); defer { lock.unlock() }
        calls.append(user)
        if let e = failWith, failTimes > 0 { failTimes -= 1; throw e }
        if let e = failWith, failTimes < 0 { throw e }
        // 후보 구간 첫 줄의 ID로 응답 선택 (병렬 호출이라 순서가 섞인다)
        let first = user.components(separatedBy: "===== 후보 구간 시작 =====\n").last?.split(separator: " ").first.map(String.init) ?? ""
        let text = responses.first { $0.contains("\"key\":\"\(first)\"") } ?? responses.first ?? "{}"
        return AICompletion(text: text, promptTokens: 100, completionTokens: 20)
    }
}

final class AIJudgeTests: XCTestCase {
    /// T1~T20, 5초씩. T6~T13 후보 C1, T16~T18 후보 C2
    func project() -> SermonProject {
        let media = MediaInfo(durationSeconds: 1000, frameRateNum: 30, frameRateDen: 1, width: 1920, height: 1080, hasAudio: true)
        var segs = (1...20).map { TranscriptSegment(id: "T\($0)", start: Double($0 - 1) * 5 + 100, end: Double($0) * 5 + 100, text: "문장 \($0)") }
        for i in segs.indices { segs[i].alignStatus = .matched; segs[i].matchedManuscriptID = "M1" }
        for i in 5...12 { segs[i].alignStatus = .unmatched; segs[i].matchedManuscriptID = nil; segs[i].isRemoved = true; segs[i].unmatchedReason = .improvised }
        for i in 15...17 { segs[i].alignStatus = .unmatched; segs[i].matchedManuscriptID = nil; segs[i].needsReview = true; segs[i].unmatchedReason = .unknown }
        let m = Manuscript(title: "제목", passage: "본문", headings: [],
                           sentences: [ManuscriptSentence(id: "M1", text: "원고 문장", order: 0, sectionIndex: 0, isScripture: false)])
        var p = SermonProject(videoPath: "/tmp/v.mp4", manuscriptPath: nil, media: media, sourceRange: TimeRange(start: 100, end: 200),
                              segments: segs, manuscript: m, silences: [])
        p.candidates = [
            DigressionCandidate(id: "C1", segmentIDs: (6...13).map { "T\($0)" }, range: TimeRange(start: 125, end: 165),
                                localOverlap: 0.05, globalOverlap: 0.3, localRemoved: true),
            DigressionCandidate(id: "C2", segmentIDs: (16...18).map { "T\($0)" }, range: TimeRange(start: 175, end: 190),
                                localOverlap: 0.3, globalOverlap: 0.5, localRemoved: false),
        ]
        return p
    }

    func testParseValidatesIDs() throws {
        let j = try AIDigressionJudge.parse(#"```json {"digression": true, "start": "T8", "end": "T7", "category": "politics", "confidence": "0.9", "reason": "정치"} ```"#,
                                            allowed: ["T6", "T7", "T8"])
        XCTAssertEqual(j.startID, "T7")   // 순서 뒤집힘 교정
        XCTAssertEqual(j.endID, "T8")
        XCTAssertEqual(j.confidence ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertThrowsError(try AIDigressionJudge.parse(#"{"digression": true, "start": "T99", "end": "T8"}"#, allowed: ["T8"]))
        XCTAssertThrowsError(try AIDigressionJudge.parse("모르겠습니다", allowed: []))
        let keep = try AIDigressionJudge.parse(#"{"digression": false, "start": null, "end": null, "confidence": 1}"#, allowed: [])
        XCTAssertFalse(keep.digression)
    }

    func testJudgeNarrowsCutAndKeepsOnTopicCandidate() async throws {
        let provider = MockProvider([
            #"{"key":"T6","digression": true, "start": "T8", "end": "T12", "category": "politics", "confidence": 0.95, "reason": "정치 이야기"}"#,
            #"{"key":"T16","digression": false, "start": null, "end": null, "category": "elaboration", "confidence": 0.9, "reason": "본문 부연"}"#,
        ])
        let (p, report) = try await AIDigressionJudge().judge(project(), provider: provider)
        XCTAssertEqual(report.judged, 2)
        XCTAssertEqual(provider.calls.count, 2)
        let removed = p.segments.filter(\.isRemoved).map(\.id)
        XCTAssertEqual(removed, ["T8", "T9", "T10", "T11", "T12"])     // T6,T7,T13은 AI가 설교 내용으로 봐서 복원
        XCTAssertNil(p.segments[5].needsReview)
        XCTAssertEqual(p.segments[7].aiNote, "정치 이야기")
        XCTAssertFalse(p.segments[15].isRemoved)                        // C2 유지
        XCTAssertNil(p.segments[15].needsReview)                        // 확신 높음 → 확인 필요 해제
        XCTAssertEqual(p.candidates?[0].ai?.model, "mock-1")
        // 프롬프트에 문맥·원고 포함
        XCTAssertTrue(provider.calls.contains { $0.contains("(앞 문맥)") && $0.contains("M1: 원고 문장") && $0.contains("제목: 제목") })
    }

    func testJudgeCanExtendIntoContext() async throws {
        let provider = MockProvider([
            #"{"key":"T6","digression": true, "start": "T4", "end": "T13", "category": "church_news", "confidence": 0.8, "reason": "소식"}"#,
            #"{"key":"T16","digression": false, "confidence": 0.3, "reason": "애매"}"#,
        ])
        let (p, _) = try await AIDigressionJudge().judge(project(), provider: provider)
        XCTAssertTrue(p.segments[3].isRemoved)                          // T4: 앞 문맥까지 확장
        XCTAssertEqual(p.segments[15].needsReview, true)                // 확신 0.3 → 확인 필요
    }

    func testFailureIsIsolatedAndRetried() async throws {
        let provider = MockProvider([#"{"digression": false, "confidence": 1}"#])
        provider.failWith = .http(status: 500, message: "boom")
        provider.failTimes = 1                                           // 첫 호출만 실패 → 재시도로 성공
        var cfg = AIDigressionJudge.Config()
        cfg.maxConcurrent = 1
        let (_, ok) = try await AIDigressionJudge(config: cfg).judge(project(), provider: provider, only: ["C1"])
        XCTAssertEqual(ok.judged, 1)
        XCTAssertEqual(provider.calls.count, 2)

        let broken = MockProvider([])
        broken.failWith = .http(status: 401, message: "bad key")         // 재시도 안 함
        broken.failTimes = -1
        let (p, report) = try await AIDigressionJudge().judge(project(), provider: broken)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(broken.calls.count, 2)
        XCTAssertEqual(p.candidates?[0].ai?.status, .failed)
        XCTAssertTrue(p.segments[5].isRemoved)                           // 로컬 판단 유지
        XCTAssertEqual(p.segments[5].needsReview, true)                  // + 확인 필요
        XCTAssertTrue(p.segments[5].aiNote?.contains("AI 판정 실패") == true)
    }

    func testUserDecisionsAreNeverOverwritten() async throws {
        var proj = project()
        proj.segments[9].userOverridden = true
        proj.segments[9].isRemoved = false
        let provider = MockProvider([#"{"key":"T6","digression": true, "start": "T6", "end": "T13", "confidence": 1}"#,
                                     #"{"key":"T16","digression": false, "confidence": 1}"#])
        let (p, _) = try await AIDigressionJudge().judge(proj, provider: provider)
        XCTAssertFalse(p.segments[9].isRemoved)
        XCTAssertTrue(p.segments[8].isRemoved)
    }

    func testEstimateCountsCalls() {
        let e = AIDigressionJudge().estimate(project())
        XCTAssertEqual(e.calls, 2)
        XCTAssertGreaterThan(e.promptTokens, 100)
    }

    func testMissingKeyMessageIsKorean() {
        XCTAssertTrue(AIError.missingAPIKey("DeepSeek").localizedDescription.contains("API 키가 없습니다"))
        XCTAssertTrue(AIError.http(status: 402, message: "").localizedDescription.contains("잔액"))
        XCTAssertEqual(KeychainStore.masked("sk-1234567890abcd"), "sk-••••••••abcd")
    }
}
