import Foundation

/// AI 판정 (SPEC §3.3 2단계의 이 앱 버전)
///
/// 로컬 규칙이 찾은 탈선 후보 구간마다, 앞뒤 문맥·주변 원고와 함께 AI에 보내
/// ① 설교 주제에서 벗어난 이야기인지 ② 그렇다면 정확히 어디서 시작해 어디서 끝나는지를 받는다.
/// 결과는 제안일 뿐이며 사용자가 최종 결정한다(userOverridden 세그먼트는 건드리지 않음).
public struct AIDigressionJudge: Sendable {
    public struct Config: Sendable {
        public var contextSegments = 6
        public var manuscriptWindow = 6
        public var maxConcurrent = 3
        public var maxRetries = 2
        public var maxTokens = 4000
        /// 이 신뢰도 미만이면 "확인 필요"
        public var reviewBelowConfidence = 0.6
        public init() {}
    }

    public struct Estimate: Sendable {
        public var calls: Int
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int { promptTokens + completionTokens }
    }

    public struct Report: Sendable {
        public var judged = 0
        public var failed = 0
        public var promptTokens = 0
        public var completionTokens = 0
        public var errors: [String] = []
    }

    public var config: Config
    public init(config: Config = Config()) { self.config = config }

    // MARK: - 비용 추정 (호출 전 사용자 확인용)

    public func estimate(_ p: SermonProject, only ids: Set<String>? = nil) -> Estimate {
        let targets = (p.candidates ?? []).filter { c in ids.map { $0.contains(c.id) } ?? true }
        var prompt = 0
        for c in targets {
            let req = makePrompt(p, c)
            // 한국어는 대략 1.2자당 1토큰 (DeepSeek/Claude 토크나이저 실측 근사)
            prompt += Int(Double(req.system.count + req.user.count) / 1.2)
        }
        // 추론 모델은 답보다 생각이 길다 — 호출당 약 900토큰
        return Estimate(calls: targets.count, promptTokens: prompt, completionTokens: targets.count * 900)
    }

    // MARK: - 판정

    public func judge(_ project: SermonProject, provider: AIProvider, only ids: Set<String>? = nil,
                      progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> (SermonProject, Report) {
        var p = project
        let targets = (p.candidates ?? []).filter { c in ids.map { $0.contains(c.id) } ?? true }
        var report = Report()
        let total = targets.count
        let requests = targets.map { ($0.id, makePrompt(p, $0)) }

        // 동시 호출 수 제한
        var results: [String: Result<(AIJudgement, AICompletion), Error>] = [:]
        try await withThrowingTaskGroup(of: (String, Result<(AIJudgement, AICompletion), Error>).self) { group in
            var iterator = requests.makeIterator()
            func addNext() -> Bool {
                guard let (id, req) = iterator.next() else { return false }
                group.addTask { (id, await self.call(provider, req)) }
                return true
            }
            for _ in 0..<config.maxConcurrent { if !addNext() { break } }
            var done = 0
            while let (id, r) = try await group.next() {
                try Task.checkCancellation()
                results[id] = r
                done += 1
                progress?(done, total)
                _ = addNext()
            }
        }

        for c in targets {
            guard let r = results[c.id], let idx = p.candidates?.firstIndex(where: { $0.id == c.id }) else { continue }
            switch r {
            case .success(let (j, usage)):
                var j = j
                j.model = provider.model
                p.candidates?[idx].ai = j
                report.judged += 1
                report.promptTokens += usage.promptTokens
                report.completionTokens += usage.completionTokens
            case .failure(let e):
                if (e as? SermonCutError) == .cancelled { throw e }
                p.candidates?[idx].ai = AIJudgement(status: .failed, digression: false, error: e.localizedDescription, model: provider.model)
                report.failed += 1
                report.errors.append("\(c.id): \(e.localizedDescription)")
            }
        }
        p = Self.apply(p, contextSegments: config.contextSegments, reviewBelow: config.reviewBelowConfidence)
        p.updatedAt = Date()
        return (p, report)
    }

    private func call(_ provider: AIProvider, _ req: (system: String, user: String, allowed: [String])) async -> Result<(AIJudgement, AICompletion), Error> {
        var lastError: Error = AIError.emptyResponse
        for attempt in 0...config.maxRetries {
            if Task.isCancelled { return .failure(SermonCutError.cancelled) }
            do {
                let completion = try await provider.complete(system: req.system, user: req.user, maxTokens: config.maxTokens)
                let judgement = try Self.parse(completion.text, allowed: req.allowed)
                return .success((judgement, completion))
            } catch let e as AIError where e.isRetryable && attempt < config.maxRetries {
                lastError = e
                try? await Task.sleep(nanoseconds: UInt64(pow(3.0, Double(attempt)) * 1_000_000_000))
            } catch {
                return .failure(error)
            }
        }
        return .failure(lastError)
    }

    // MARK: - 프롬프트

    static let systemPrompt = """
    당신은 한국 교회 주일 설교 영상의 편집을 돕는 도구입니다.
    편집자는 설교 원고와 실제 설교 음성 전사문을 비교해, 설교 주제에서 벗어난 "탈선 구간"만 잘라냅니다.

    편집 기준
    - 남긴다: 원고에 없더라도 설교 본문·주제·적용과 이어지는 말. 부연 설명, 본문 이야기 풀어 말하기, 예화, 권면, 결단 촉구, 성경 인용·봉독, 결론 기도.
    - 자른다: 설교 흐름과 무관한 이야기. 교회 광고·행사·소식, 교인 근황·방문자 소개·기도 제목 나눔, 시사·정치·사회 이슈(감염병, 정부, 대통령, 재판 등),
      교단·총회·노회·다른 교회 사정, 설교 시작 전 인사·신앙고백·설교 전 기도.
    - 한두 문장만 스쳐 지나가는 곁말은 자르지 않는다. 다른 화제가 하나의 이야기로 이어질 때만 자른다.
    - 경계: 탈선이 실제로 시작되는 세그먼트와, 설교 내용으로 돌아오기 직전 세그먼트를 고른다.
      표시된 후보 구간보다 좁을 수도(앞뒤 일부가 설교 내용인 경우), 앞뒤 문맥 쪽으로 넓을 수도 있다.
    - 전사문에는 음성 인식 오류가 있다(예: 에스더 → 예수, 모르드개 → 모르두개). 오류 자체는 판단 근거가 아니다.

    반드시 JSON 객체 하나만 출력하고 설명이나 코드펜스를 붙이지 마십시오.
    """

    func makePrompt(_ p: SermonProject, _ c: DigressionCandidate) -> (system: String, user: String, allowed: [String]) {
        let segs = p.segments
        let index = Dictionary(uniqueKeysWithValues: segs.enumerated().map { ($1.id, $0) })
        let first = c.segmentIDs.first.flatMap { index[$0] } ?? 0
        let last = c.segmentIDs.last.flatMap { index[$0] } ?? first
        let lo = max(0, first - config.contextSegments), hi = min(segs.count - 1, last + config.contextSegments)

        func line(_ s: TranscriptSegment) -> String { "\(s.id) [\(Timecode.format(s.start, millis: false))] \(s.text)" }
        var transcript: [String] = []
        if lo < first { transcript.append("(앞 문맥)") ; transcript += segs[lo..<first].map(line) }
        transcript.append("===== 후보 구간 시작 =====")
        transcript += segs[first...last].map(line)
        transcript.append("===== 후보 구간 끝 =====")
        if last < hi { transcript.append("(뒤 문맥)"); transcript += segs[(last + 1)...hi].map(line) }

        // 주변 원고: 앞뒤 매칭 문장 기준
        var manuscriptLines: [String] = []
        if let m = p.manuscript, !m.sentences.isEmpty {
            let order = Dictionary(uniqueKeysWithValues: m.sentences.map { ($0.id, $0.order) })
            let before = segs[..<first].last { $0.alignStatus == .matched }?.matchedManuscriptID.flatMap { order[$0] } ?? 0
            let after = segs[(last + 1)...].first { $0.alignStatus == .matched }?.matchedManuscriptID.flatMap { order[$0] } ?? m.sentences.count - 1
            let a = max(0, min(before, after) - config.manuscriptWindow / 2)
            let b = min(m.sentences.count - 1, max(before, after) + config.manuscriptWindow / 2)
            let slice = m.sentences[a...b]
            manuscriptLines = (slice.count > 16 ? Array(slice.prefix(8)) + Array(slice.suffix(8)) : Array(slice)).map { "\($0.id): \($0.text)" }
        }

        var user = "[설교 정보]\n제목: \(p.manuscript?.title ?? "알 수 없음")\n본문: \(p.manuscript?.passage ?? "알 수 없음")\n"
        if let h = p.manuscript?.headings, !h.isEmpty { user += "대지: " + h.map { "\($0.number). \($0.title)" }.joined(separator: " / ") + "\n" }
        if !manuscriptLines.isEmpty { user += "\n[이 부분 주변의 설교 원고]\n" + manuscriptLines.joined(separator: "\n") + "\n" }
        user += "\n[전사문]\n" + transcript.joined(separator: "\n") + "\n"
        user += """

        질문: 위 전사문(후보 구간과 앞뒤 문맥)에 설교 주제에서 벗어난 탈선 구간이 있습니까?
        탈선이 없으면 digression=false, start·end는 null.
        confidence는 "탈선일 확률"이 아니라 **이 판정(digression 값)이 맞다는 확신**입니다. 판정이 확실하면 탈선이든 아니든 1에 가깝게 쓰십시오.
        출력 형식:
        {"digression": true, "start": "T번호", "end": "T번호", "category": "announcement|church_news|personal|social_issue|politics|denomination|greeting|prayer|elaboration|other", "confidence": 0.0~1.0, "reason": "한국어 한 문장"}
        """
        return (Self.systemPrompt, user, segs[lo...hi].map(\.id))
    }

    static func parse(_ text: String, allowed: [String]) throws -> AIJudgement {
        let o = try JSONExtractor.object(text)
        guard let digression = o["digression"] as? Bool else { throw AIError.invalidJSON(text) }
        func id(_ key: String) -> String? {
            guard let v = o[key] as? String, allowed.contains(v) else { return nil }
            return v
        }
        var start = id("start"), end = id("end")
        if digression, start == nil || end == nil { throw AIError.invalidJSON("start/end가 전사문 ID가 아님: \(text)") }
        if let s = start, let e = end, let si = allowed.firstIndex(of: s), let ei = allowed.firstIndex(of: e), si > ei { swap(&start, &end) }
        let confidence = (o["confidence"] as? NSNumber)?.doubleValue ?? (o["confidence"] as? String).flatMap(Double.init)
        return AIJudgement(status: .judged, digression: digression, startID: digression ? start : nil, endID: digression ? end : nil,
                           category: o["category"] as? String, confidence: confidence, reason: o["reason"] as? String)
    }

    // MARK: - 적용

    /// AI 판정을 세그먼트에 반영. 판정이 없거나 실패한 후보는 로컬 판단을 유지하되 "확인 필요"로 표시.
    public static func apply(_ project: SermonProject, contextSegments: Int = 6, reviewBelow: Double = 0.6) -> SermonProject {
        var p = project
        let index = Dictionary(uniqueKeysWithValues: p.segments.enumerated().map { ($1.id, $0) })
        for c in p.candidates ?? [] {
            guard let ai = c.ai else { continue }
            let first = c.segmentIDs.first.flatMap { index[$0] } ?? 0
            let last = c.segmentIDs.last.flatMap { index[$0] } ?? first
            let lo = max(0, first - contextSegments), hi = min(p.segments.count - 1, last + contextSegments)
            switch ai.status {
            case .failed:
                // 정렬 실패: 로컬 판단은 그대로 두고 확인 필요 + 사유
                for i in first...last where !p.segments[i].userOverridden {
                    p.segments[i].needsReview = true
                    p.segments[i].aiNote = "AI 판정 실패 — \(ai.error ?? "")"
                }
            case .judged:
                let review = (ai.confidence ?? 1) < reviewBelow
                let cut: ClosedRange<Int>? = {
                    guard ai.digression, let s = ai.startID.flatMap({ index[$0] }), let e = ai.endID.flatMap({ index[$0] }) else { return nil }
                    return max(lo, min(s, e))...min(hi, max(s, e))
                }()
                let reason = reasonFor(ai.category)
                // 후보 구간 + AI가 넓힌 범위를 다시 결정
                let span = min(first, cut?.lowerBound ?? first)...max(last, cut?.upperBound ?? last)
                for i in span where !p.segments[i].userOverridden {
                    if let cut, cut.contains(i) {
                        p.segments[i].isRemoved = true
                        p.segments[i].unmatchedReason = reason
                        p.segments[i].needsReview = review ? true : nil
                        p.segments[i].aiNote = ai.reason
                    } else if (first...last).contains(i) {
                        // 후보였지만 AI가 설교 내용으로 판단 → 유지
                        p.segments[i].isRemoved = false
                        p.segments[i].unmatchedReason = nil
                        p.segments[i].needsReview = review ? true : nil
                        p.segments[i].aiNote = ai.digression ? nil : ai.reason
                    }
                }
            }
        }
        return p
    }

    static func reasonFor(_ category: String?) -> UnmatchedReason {
        switch category {
        case "greeting", "prayer": return .greeting
        default: return .improvised
        }
    }
}
