import Foundation
import SermonCutCore

// Phase 1 CLI 프로토타입. 사용법은 `sermoncut help`.

let usage = """
사용법:
  sermoncut analyze  --video 영상 --in 시작 --out 끝 [--manuscript 원고] [--work 작업폴더] [--project 저장경로]
  sermoncut export   --project 프로젝트.sermoncut --fcpxml 출력.fcpxml [--no-transitions] [--gain dB]
  sermoncut evaluate --project 프로젝트.sermoncut --reference 기준.fcpxml [--gap 초]
  sermoncut realign  --project 프로젝트.sermoncut [--run 초] [--threshold 0.3]
  sermoncut transcript --project 프로젝트.sermoncut [--all]
  sermoncut manuscript 원고파일
  sermoncut waveform --video 영상          (파형 생성 시간 측정, 캐시 없이)
  sermoncut ai       --project 프로젝트.sermoncut [--provider deepseek|claude|openai-compatible] [--model 이름] [--base-url URL] [--yes]
  sermoncut ai-test  [--provider …] [--model …]        (연결 테스트)
  API 키: Keychain(서비스 com.nugabox.sermoncut.apikey) 또는 환경변수 SERMONCUT_API_KEY

시간은 1:22:33.4 / 22:33 / 4953.4 형식 모두 가능. 모든 시간은 원본 영상 0초 기준.
"""

struct Args {
    var command: String
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    init(_ argv: [String]) {
        command = argv.first ?? "help"
        var i = 1
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    options[key] = argv[i + 1]
                    i += 2
                } else {
                    flags.insert(key)
                    i += 1
                }
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func require(_ key: String) throws -> String {
        guard let v = options[key] else { throw SermonCutError.invalidArgument("--\(key) 값이 필요합니다.\n\n\(usage)") }
        return v
    }

    func time(_ key: String) throws -> Double {
        let v = try require(key)
        guard let t = Timecode.parse(v) else { throw SermonCutError.invalidArgument("--\(key) 시간 형식이 잘못됐습니다: \(v)") }
        return t
    }
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String: Int] = [:]
    func report(_ stage: SermonAnalyzer.Stage, _ p: Double) {
        let pct = Int(p * 100) / 10 * 10
        lock.lock(); defer { lock.unlock() }
        if last[stage.rawValue] != pct {
            last[stage.rawValue] = pct
            eprint("  \(stage.rawValue) \(pct)%")
        }
    }
}

// MARK: - 명령

func analyze(_ args: Args) async throws {
    let video = fileURL(try args.require("video"))
    let range = TimeRange(start: try args.time("in"), end: try args.time("out"))
    let manuscript = args.options["manuscript"].map(fileURL)
    let work = fileURL(args.options["work"] ?? "~/Library/Caches/SermonCut/\(video.deletingPathExtension().lastPathComponent)")
    let projectURL = fileURL(args.options["project"] ?? work.appendingPathComponent("project.sermoncut").path)

    var input = SermonAnalyzer.Input(video: video, sourceRange: range, manuscript: manuscript, workDirectory: work)
    input.settings = ExportSettings()
    let printer = ProgressPrinter()
    let started = Date()
    let project = try await SermonAnalyzer().run(input, onStage: { eprint("▶︎ \($0.rawValue)") },
                                                 onProgress: { printer.report($0, $1) })
    try ProjectFile.save(project, to: projectURL)
    eprint(String(format: "완료 (%.0f초)", Date().timeIntervalSince(started)))
    printSummary(project)
    print("프로젝트: \(projectURL.path)")
}

func printSummary(_ p: SermonProject) {
    let segs = p.segments
    let matched = segs.filter { $0.alignStatus == .matched }.count
    let removed = segs.filter(\.isRemoved)
    let removedSeconds = removed.reduce(0) { $0 + $1.duration }
    print("영상: \(p.media.width)x\(p.media.height) \(p.media.frameRateNum)/\(p.media.frameRateDen)fps, \(Timecode.format(p.media.durationSeconds))")
    print("설교 구간: \(Timecode.format(p.sourceRange.start)) ~ \(Timecode.format(p.sourceRange.end)) (\(Timecode.format(p.sourceRange.duration)))")
    print("전사 세그먼트: \(segs.count)개, 무음 구간: \(p.silences.count)개")
    if let m = p.manuscript {
        print("원고: 제목 \(m.title ?? "-") / 본문 \(m.passage ?? "-") / 소제목 \(m.headings.count)개 / 문장 \(m.sentences.count)개")
        print("정렬: 매칭 \(matched)개 (\(segs.isEmpty ? 0 : matched * 100 / segs.count)%)")
    }
    print("삭제 제안: 세그먼트 \(removed.count)개, \(Timecode.format(removedSeconds))")
    for r in runs(p, where: { $0.isRemoved }) {
        let first = p.segments.first { $0.start >= r.start }?.text ?? ""
        print("  ✂︎ \(Timecode.format(r.start)) ~ \(Timecode.format(r.end)) (\(String(format: "%.1f", r.duration))초) \(first.prefix(40))…")
    }
    let review = runs(p, where: { $0.needsReview == true })
    if !review.isEmpty {
        print("확인 필요: \(review.count)곳")
        for r in review {
            let first = p.segments.first { $0.start >= r.start }?.text ?? ""
            print("  ⚠︎ \(Timecode.format(r.start)) ~ \(Timecode.format(r.end)) (\(String(format: "%.1f", r.duration))초) \(first.prefix(40))…")
        }
    }
}

func runs(_ p: SermonProject, where include: (TranscriptSegment) -> Bool) -> [TimeRange] {
    var runs: [TimeRange] = []
    for s in p.segments where include(s) {
        if var last = runs.last, s.start - last.end < 2 {
            last.end = s.end
            runs[runs.count - 1] = last
        } else {
            runs.append(TimeRange(start: s.start, end: s.end))
        }
    }
    return runs
}

func export(_ args: Args) throws {
    let project = try ProjectFile.load(fileURL(try args.require("project")))
    let out = fileURL(try args.require("fcpxml"))
    var settings = project.settings
    if args.flags.contains("no-transitions") { settings.transitionDuration = 0 }
    if let g = args.options["gain"], let v = Double(g) { settings.audioGainDB = v }

    let edl = try EDLBuilder.build(segments: project.segments, silences: project.silences, sourceRange: project.sourceRange,
                                   media: project.media, settings: settings)
    let video = URL(fileURLWithPath: project.videoPath)
    var options = FCPXMLExporter.Options(eventName: "SermonCut", projectName: video.deletingPathExtension().lastPathComponent + " (SermonCut)",
                                         audioGainDB: settings.audioGainDB)
    options.chapterMarkers = ChapterMarkers.fromManuscript(project).map { ($0.sourceSeconds, $0.title) }
    let xml = FCPXMLExporter().export(edl: edl, videoURL: video, options: options)
    do { try xml.write(to: out, atomically: true, encoding: .utf8) } catch {
        throw SermonCutError.fileWriteFailed(path: out.path, reason: error.localizedDescription)
    }
    printEDL(edl)
    print("FCPXML: \(out.path)")
}

func printEDL(_ edl: EditDecisionList) {
    let snap = FrameSnapper(media: edl.media)
    print("클립 \(edl.clips.count)개, 결과 길이 \(Timecode.format(snap.seconds(edl.totalFrames))), 핸들 부족 \(edl.handleShortageCount)곳")
    for (i, c) in edl.clips.enumerated() {
        let t = edl.transitions.first { $0.afterClip == i }
        var line = String(format: "  %2d  %@ ~ %@  (%@)", i + 1,
                          Timecode.format(snap.seconds(c.sourceStartFrame)), Timecode.format(snap.seconds(c.sourceEndFrame)),
                          Timecode.format(snap.seconds(c.durationFrames)))
        if let t {
            line += t.durationFrames > 0 ? "  → 디졸브 \(t.durationFrames)f" : "  → 하드컷"
            if t.handleShortage { line += " ⚠핸들부족" }
            line += String(format: " (삭제 %.1f초)", t.removedSeconds)
        }
        print(line)
    }
}

func evaluate(_ args: Args) throws {
    let project = try ProjectFile.load(fileURL(try args.require("project")))
    let refURL = fileURL(try args.require("reference"))
    let refData = try Data(contentsOf: refURL.hasDirectoryPath || refURL.pathExtension == "fcpxmld"
                           ? refURL.appendingPathComponent("Info.fcpxml") : refURL)
    let assetName = URL(fileURLWithPath: project.videoPath).deletingPathExtension().lastPathComponent
    let reference = try ReferenceEDLReader.keptRanges(fcpxml: refData, assetName: assetName)
    guard let first = reference.first, let last = reference.last else {
        throw SermonCutError.invalidArgument("기준 FCPXML에서 \(assetName) 클립을 찾지 못했습니다.")
    }
    let edl = try EDLBuilder.build(segments: project.segments, silences: project.silences, sourceRange: project.sourceRange,
                                   media: project.media, settings: project.settings)
    let snap = FrameSnapper(media: project.media)
    let predicted = edl.clips.map { TimeRange(start: snap.seconds($0.sourceStartFrame), end: snap.seconds($0.sourceEndFrame)) }
    // 비교 범위: 기준 편집의 첫 클립 시작 ~ 마지막 클립 끝 (설교 구간 바깥은 비교 안 함)
    let window = TimeRange(start: first.start, end: last.end)
    let cmp = EditComparison.compare(reference: reference, predicted: predicted, window: window)

    print("비교 범위: \(Timecode.format(window.start)) ~ \(Timecode.format(window.end)) (\(Timecode.format(window.duration)))")
    print(String(format: "기준 삭제 %.1f초 / 제안 삭제 %.1f초 / 겹침 %.1f초", cmp.referenceRemoved, cmp.predictedRemoved, cmp.bothRemoved))
    print(String(format: "재현율(기준 삭제 중 맞춘 비율) %.1f%% · 정밀도(제안 삭제 중 맞은 비율) %.1f%% · 전체 일치 %.1f%%",
                 cmp.recall * 100, cmp.precision * 100, cmp.agreement * 100))
    print("\n기준 삭제 구간 vs 제안:")
    let refGaps = gaps(reference)
    let preGaps = gaps(predicted.filter { $0.end > window.start && $0.start < window.end })
    for g in refGaps {
        let hits = preGaps.filter { $0.end > g.start && $0.start < g.end }
        let desc = hits.isEmpty ? "✗ 놓침" : hits.map { h in
            String(format: "%@~%@ (시작 %+.1f초, 끝 %+.1f초)", Timecode.format(h.start), Timecode.format(h.end), h.start - g.start, h.end - g.end)
        }.joined(separator: ", ")
        print("  기준 \(Timecode.format(g.start))~\(Timecode.format(g.end)) (\(String(format: "%.1f", g.duration))초) → \(desc)")
    }
    let extras = preGaps.filter { p in !refGaps.contains { $0.end > p.start && $0.start < p.end } && p.duration >= 1.0 }
    if !extras.isEmpty {
        print("\n기준에는 없는 제안 삭제 (1초 이상):")
        for e in extras {
            let text = project.segments.filter { $0.start >= e.start - 0.5 && $0.end <= e.end + 0.5 }.map(\.text).joined(separator: " ")
            print("  \(Timecode.format(e.start))~\(Timecode.format(e.end)) (\(String(format: "%.1f", e.duration))초) \(text.prefix(60))")
        }
    }
    if let tol = args.options["gap"].flatMap(Double.init) {
        let small = preGaps.filter { $0.duration < tol }
        print("\n\(tol)초 미만 짧은 컷: \(small.count)곳")
    }
}

func gaps(_ kept: [TimeRange]) -> [TimeRange] {
    zip(kept, kept.dropFirst()).compactMap { a, b in b.start - a.end > 0.05 ? TimeRange(start: a.end, end: b.start) : nil }
}

func realign(_ args: Args) throws {
    let url = fileURL(try args.require("project"))
    var project = try ProjectFile.load(url)
    var analyzer = SermonAnalyzer()
    if let r = args.options["run"].flatMap(Double.init) { analyzer.suggester.config.minRunSeconds = r }
    if let t = args.options["threshold"].flatMap(Double.init) { analyzer.aligner.config.matchThreshold = t }
    if let b = args.options["bridge"].flatMap(Double.init) { analyzer.suggester.config.bridgeMatchedSeconds = b }
    project = analyzer.realign(project)
    try ProjectFile.save(project, to: url)
    printSummary(project)
}

func transcript(_ args: Args) throws {
    let p = try ProjectFile.load(fileURL(try args.require("project")))
    let sentences = Dictionary(uniqueKeysWithValues: (p.manuscript?.sentences ?? []).map { ($0.id, $0.text) })
    for s in p.segments {
        let mark = s.isRemoved ? "✂︎" : (s.alignStatus == .matched ? "✓" : (s.needsReview == true ? "⚠︎" : "·"))
        var line = "\(mark) \(Timecode.format(s.start)) \(s.id) [\(String(format: "%.2f", s.confidence ?? 0))] \(s.text)"
        if args.flags.contains("all"), let m = s.matchedManuscriptID, let t = sentences[m] { line += "\n      ↳ \(m): \(t)" }
        print(line)
    }
}

func manuscript(_ args: Args) async throws {
    guard let path = args.positional.first else { throw SermonCutError.invalidArgument(usage) }
    let m = try await ManuscriptLoader().load(fileURL(path))
    print("제목: \(m.title ?? "-")\n본문: \(m.passage ?? "-")")
    print("소제목 \(m.headings.count)개:")
    for h in m.headings { print("  \(h.number). \(h.title)  (첫 문장 \(h.firstSentenceID ?? "-"))") }
    print("문장 \(m.sentences.count)개:")
    for s in m.sentences { print("  \(s.id) [\(s.sectionIndex)\(s.isScripture ? " 성경" : "")] \(s.text)") }
}

func waveform(_ args: Args) async throws {
    let video = fileURL(try args.require("video"))
    let started = Date()
    let w = try await WaveformGenerator().generate(video: video, cacheDirectory: nil)
    let peak = w.peaks.max() ?? 0
    print(String(format: "버킷 %d개 (%.1f초 분량), 최대 %.2f, 소요 %.1f초", w.peaks.count, w.duration, peak, Date().timeIntervalSince(started)))
}

func aiConfig(_ args: Args) throws -> AIConfig {
    let kind = try args.options["provider"].map { raw -> AIProviderKind in
        guard let k = AIProviderKind(rawValue: raw) else { throw SermonCutError.invalidArgument("알 수 없는 provider: \(raw)") }
        return k
    } ?? .deepseek
    return AIConfig(kind: kind, model: args.options["model"], baseURL: args.options["base-url"])
}

func aiTest(_ args: Args) async throws {
    let config = try aiConfig(args)
    let provider = try config.makeProvider()
    let started = Date()
    let r = try await provider.complete(system: "JSON만 출력하십시오.", user: "{\"ok\": true} 를 그대로 출력", maxTokens: 2000)
    print(String(format: "%@ / %@ 연결 성공 (%.1f초, 입력 %d·출력 %d 토큰): %@", provider.displayName, provider.model,
                 Date().timeIntervalSince(started), r.promptTokens, r.completionTokens, r.text))
}

func ai(_ args: Args) async throws {
    let url = fileURL(try args.require("project"))
    var project = try ProjectFile.load(url)
    if project.candidates == nil { project = SermonAnalyzer().realign(project) }
    let judge = AIDigressionJudge()
    let est = judge.estimate(project)
    print("AI 판정 대상: 탈선 후보 \(est.calls)곳, 예상 약 \(est.promptTokens + est.completionTokens) 토큰 (입력 \(est.promptTokens), 출력 \(est.completionTokens))")
    guard est.calls > 0 else { return }
    if !args.flags.contains("yes") {
        print("계속하려면 --yes 를 붙여 다시 실행하세요.")
        return
    }
    let provider = try aiConfig(args).makeProvider()
    let started = Date()
    let (p, report) = try await judge.judge(project, provider: provider) { done, total in eprint("  \(done)/\(total)") }
    project = p
    try ProjectFile.save(project, to: url)
    print(String(format: "완료 %.0f초: 판정 %d · 실패 %d · 실제 사용 입력 %d / 출력 %d 토큰", Date().timeIntervalSince(started),
                 report.judged, report.failed, report.promptTokens, report.completionTokens))
    for e in report.errors { print("  ⚠︎ \(e)") }
    let segs = Dictionary(uniqueKeysWithValues: project.segments.map { ($0.id, $0) })
    for c in project.candidates ?? [] {
        guard let a = c.ai else { continue }
        let local = c.localRemoved ? "로컬:삭제" : "로컬:확인필요"
        if a.status == .failed { print("  \(c.id) \(Timecode.format(c.range.start, millis: false)) \(local) → 실패"); continue }
        var line = "  \(c.id) \(Timecode.format(c.range.start, millis: false))~\(Timecode.format(c.range.end, millis: false)) \(local) → "
        if a.digression, let s = a.startID.flatMap({ segs[$0] }), let e = a.endID.flatMap({ segs[$0] }) {
            line += "탈선 \(Timecode.format(s.start, millis: false))~\(Timecode.format(e.end, millis: false)) [\(a.category ?? "-")]"
        } else {
            line += "유지 [\(a.category ?? "-")]"
        }
        line += String(format: " (%.2f) %@", a.confidence ?? 0, a.reason ?? "")
        print(line)
    }
    printSummary(project)
}

// MARK: - 진입점

let args = Args(Array(CommandLine.arguments.dropFirst()))
do {
    switch args.command {
    case "analyze": try await analyze(args)
    case "export": try export(args)
    case "evaluate": try evaluate(args)
    case "realign": try realign(args)
    case "transcript": try transcript(args)
    case "manuscript": try await manuscript(args)
    case "waveform": try await waveform(args)
    case "ai": try await ai(args)
    case "ai-test": try await aiTest(args)
    default: print(usage)
    }
} catch {
    eprint("오류: \(error.localizedDescription)")
    exit(1)
}
