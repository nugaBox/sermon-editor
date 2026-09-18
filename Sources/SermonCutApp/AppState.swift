import AppKit
import AVFoundation
import Observation
import SermonCutCore
import SwiftUI

enum Screen: Equatable {
    case welcome, rangeSelect, manuscript, analyzing, editor
}

enum SegmentFilter: String, CaseIterable, Identifiable {
    case all = "전체", removed = "삭제만", review = "확인 필요"
    var id: String { rawValue }
}

/// 앱 전역 상태 (단일 창)
@MainActor
@Observable
final class AppState {
    var screen: Screen = .welcome
    var errorMessage: String?

    // MARK: 영상
    var videoURL: URL?
    var media: MediaInfo?
    let player = AVPlayer()
    var currentTime: Double = 0
    var playbackRate: Float = 0
    var waveform: Waveform?
    var waveformProgress: Double = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var stopAt: Double?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?

    // MARK: 설교 구간 (원본 0초 기준)
    var inPoint: Double?
    var outPoint: Double?
    var marginHead: Double = 2
    var marginTail: Double = 3

    // MARK: 원고
    var manuscriptURL: URL?
    var manuscript: Manuscript?
    var manuscriptError: String?

    // MARK: 분석
    var stage: SermonAnalyzer.Stage?
    var stageProgress: Double = 0
    var completedStages: [SermonAnalyzer.Stage] = []
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    // MARK: 편집
    var project: SermonProject? {
        didSet { if oldValue?.segments != project?.segments || oldValue?.settings != project?.settings { recomputeEDL() } }
    }
    var projectURL: URL?
    var isDirty = false
    var selection: Set<String> = []
    var filter: SegmentFilter = .all
    var search = ""
    var edl: EditDecisionList?
    var edlError: String?
    @ObservationIgnored private var undoStack: [[String: SegmentState]] = []
    @ObservationIgnored private var redoStack: [[String: SegmentState]] = []
    var canUndo = false
    var canRedo = false

    struct SegmentState: Equatable { var isRemoved: Bool; var userOverridden: Bool }

    // MARK: AI
    var aiConfig: AIConfig = AppState.loadAIConfig()
    var aiRunning = false
    var aiProgress: (done: Int, total: Int) = (0, 0)
    var aiMessage: String?
    var pendingAIEstimate: AIDigressionJudge.Estimate?
    @ObservationIgnored private var aiTask: Task<Void, Never>?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    // MARK: - 파일 열기

    func openVideo(_ url: URL) {
        Task {
            do {
                let media = try await MediaProbe().probe(url)
                reset()
                videoURL = url
                self.media = media
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                screen = .rangeSelect
                loadWaveform(url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openProject(_ url: URL) {
        do {
            let p = try ProjectFile.load(url)
            let video = URL(fileURLWithPath: p.videoPath)
            guard FileManager.default.fileExists(atPath: video.path) else {
                errorMessage = "원본 영상을 찾을 수 없습니다: \(p.videoPath)"
                return
            }
            reset()
            videoURL = video
            media = p.media
            project = p
            projectURL = url
            inPoint = p.sourceRange.start
            outPoint = p.sourceRange.end
            manuscript = p.manuscript
            manuscriptURL = p.manuscriptPath.map { URL(fileURLWithPath: $0) }
            player.replaceCurrentItem(with: AVPlayerItem(url: video))
            seek(p.sourceRange.start)
            screen = .editor
            loadWaveform(video)
        } catch {
            errorMessage = "프로젝트 파일을 열지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func reset() {
        analysisTask?.cancel()
        waveformTask?.cancel()
        player.pause()
        waveform = nil
        waveformProgress = 0
        inPoint = nil; outPoint = nil
        manuscript = nil; manuscriptURL = nil; manuscriptError = nil
        project = nil; projectURL = nil; isDirty = false
        selection = []
        undoStack = []; redoStack = []; updateUndoFlags()
        completedStages = []; stage = nil
    }

    private func loadWaveform(_ url: URL) {
        waveformTask = Task {
            let cache = Self.cacheRoot.appendingPathComponent("waveforms")
            do {
                let w = try await WaveformGenerator().generate(video: url, cacheDirectory: cache) { p in
                    Task { @MainActor [weak self] in self?.waveformProgress = p }
                }
                waveform = w
            } catch is CancellationError {
            } catch {
                errorMessage = "파형을 만들지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    static var cacheRoot: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("SermonCut")
    }

    // MARK: - 재생

    var duration: Double { media?.durationSeconds ?? 0 }
    var frameDuration: Double { media.map { Double($0.frameRateDen) / Double($0.frameRateNum) } ?? 1.0 / 30 }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        playbackRate = player.rate
        if let stop = stopAt, t >= stop {
            player.pause()
            stopAt = nil
            playbackRate = 0
        }
    }

    func seek(_ t: Double) {
        let clamped = min(max(0, t), duration)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func nudge(_ delta: Double) { seek(currentTime + delta) }

    func stepFrame(_ n: Int) {
        player.pause()
        player.currentItem?.step(byCount: n)
    }

    /// J/K/L: 누를 때마다 배속 증가
    func shuttle(_ key: Character) {
        stopAt = nil
        switch key {
        case "k":
            player.pause()
        case "l":
            let r = player.rate
            player.rate = r > 0 ? min(r * 2, 8) : 1
        case "j":
            let r = player.rate
            let canReverse = player.currentItem?.canPlayReverse ?? false
            if canReverse {
                player.rate = r < 0 ? max(r * 2, -8) : -1
            } else {
                player.pause()
                nudge(-5)
            }
        default: break
        }
        playbackRate = player.rate
    }

    func togglePlay() {
        stopAt = nil
        if player.rate != 0 { player.pause() } else { player.play() }
        playbackRate = player.rate
    }

    func play(from start: Double, until end: Double?) {
        seek(start)
        stopAt = end
        player.play()
        playbackRate = player.rate
    }

    // MARK: - 구간 선택

    func setIn(_ t: Double? = nil) {
        inPoint = t ?? currentTime
        if let o = outPoint, let i = inPoint, o <= i { outPoint = nil }
    }

    func setOut(_ t: Double? = nil) {
        outPoint = t ?? currentTime
        if let o = outPoint, let i = inPoint, o <= i { inPoint = nil }
    }

    /// 여유 마진까지 포함한 실제 분석 구간
    var sourceRange: TimeRange? {
        guard let i = inPoint, let o = outPoint, o > i else { return nil }
        return TimeRange(start: max(0, i - marginHead), end: min(duration, o + marginTail))
    }

    // MARK: - 원고

    func loadManuscript(_ url: URL) {
        manuscriptURL = url
        manuscript = nil
        manuscriptError = nil
        Task {
            do {
                manuscript = try await ManuscriptLoader().load(url)
            } catch {
                manuscriptError = error.localizedDescription
            }
        }
    }

    func clearManuscript() {
        manuscriptURL = nil
        manuscript = nil
        manuscriptError = nil
    }

    // MARK: - 분석

    func startAnalysis() {
        guard let video = videoURL, let range = sourceRange else { return }
        screen = .analyzing
        completedStages = []
        stage = nil
        stageProgress = 0
        let work = Self.cacheRoot.appendingPathComponent("work/" + WaveformGenerator.cacheKey(video))
        let input = SermonAnalyzer.Input(video: video, sourceRange: range,
                                         manuscript: manuscript == nil ? nil : manuscriptURL, workDirectory: work)
        analysisTask = Task {
            do {
                let p = try await SermonAnalyzer().run(input, onStage: { s in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let cur = self.stage { self.completedStages.append(cur) }
                        self.stage = s
                        self.stageProgress = 0
                    }
                }, onProgress: { s, v in
                    Task { @MainActor [weak self] in
                        if self?.stage == s { self?.stageProgress = v }
                    }
                })
                project = p
                isDirty = true
                selection = []
                undoStack = []; redoStack = []; updateUndoFlags()
                screen = .editor
                seek(p.sourceRange.start)
            } catch {
                if Task.isCancelled || (error as? SermonCutError) == .cancelled {
                    screen = .manuscript
                } else {
                    errorMessage = error.localizedDescription
                    screen = .manuscript
                }
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    // MARK: - 편집 (사용자 결정이 최종)

    var visibleSegments: [TranscriptSegment] {
        guard let segs = project?.segments else { return [] }
        return segs.filter { s in
            switch filter {
            case .all: break
            case .removed: if !s.isRemoved { return false }
            case .review: if s.needsReview != true { return false }
            }
            return search.isEmpty || s.text.localizedCaseInsensitiveContains(search)
        }
    }

    /// 선택 항목 삭제/복원 토글. 하나라도 유지 상태면 모두 삭제, 모두 삭제 상태면 모두 복원.
    func toggleRemoved(_ ids: Set<String>) {
        guard var p = project, !ids.isEmpty else { return }
        let targets = p.segments.indices.filter { ids.contains(p.segments[$0].id) }
        let removeAll = targets.contains { !p.segments[$0].isRemoved }
        setRemoved(ids, removeAll, in: &p)
    }

    func remove(_ ids: Set<String>) {
        guard var p = project, !ids.isEmpty else { return }
        setRemoved(ids, true, in: &p)
    }

    private func setRemoved(_ ids: Set<String>, _ value: Bool, in p: inout SermonProject) {
        var before: [String: SegmentState] = [:]
        for i in p.segments.indices where ids.contains(p.segments[i].id) {
            let s = p.segments[i]
            before[s.id] = SegmentState(isRemoved: s.isRemoved, userOverridden: s.userOverridden)
            if s.isRemoved != value {
                p.segments[i].isRemoved = value
                p.segments[i].userOverridden = true
            }
        }
        guard before.values.contains(where: { $0.isRemoved != value }) else { return }
        undoStack.append(before)
        redoStack.removeAll()
        p.updatedAt = Date()
        project = p
        isDirty = true
        updateUndoFlags()
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        if let current = apply(snapshot) { redoStack.append(current) }
        updateUndoFlags()
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        if let current = apply(snapshot) { undoStack.append(current) }
        updateUndoFlags()
    }

    /// 스냅샷 상태로 되돌리고, 되돌리기 직전 상태를 돌려준다
    private func apply(_ snapshot: [String: SegmentState]) -> [String: SegmentState]? {
        guard var p = project else { return nil }
        var current: [String: SegmentState] = [:]
        for i in p.segments.indices {
            let id = p.segments[i].id
            guard let s = snapshot[id] else { continue }
            current[id] = SegmentState(isRemoved: p.segments[i].isRemoved, userOverridden: p.segments[i].userOverridden)
            p.segments[i].isRemoved = s.isRemoved
            p.segments[i].userOverridden = s.userOverridden
        }
        project = p
        isDirty = true
        selection = Set(snapshot.keys)
        return current
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func updateSettings(_ change: (inout ExportSettings) -> Void) {
        guard var p = project else { return }
        change(&p.settings)
        project = p
        isDirty = true
    }

    private func recomputeEDL() {
        guard let p = project else { edl = nil; return }
        do {
            edl = try EDLBuilder.build(segments: p.segments, silences: p.silences, sourceRange: p.sourceRange,
                                       media: p.media, settings: p.settings)
            edlError = nil
        } catch {
            edl = nil
            edlError = error.localizedDescription
        }
    }

    /// 현재 재생 위치의 세그먼트
    var currentSegmentID: String? {
        project?.segments.first { $0.start <= currentTime && currentTime < $0.end }?.id
    }

    // MARK: - AI 판정 (SPEC §3.3 — 호출 전 예상 비용 확인, 실패 격리)

    static func loadAIConfig() -> AIConfig {
        guard let data = UserDefaults.standard.data(forKey: "aiConfig"),
              let c = try? JSONDecoder().decode(AIConfig.self, from: data) else { return .default }
        return c
    }

    func saveAIConfig() {
        if let data = try? JSONEncoder().encode(aiConfig) { UserDefaults.standard.set(data, forKey: "aiConfig") }
    }

    var failedCandidateIDs: Set<String> {
        Set((project?.candidates ?? []).filter { $0.ai?.status == .failed }.map(\.id))
    }

    /// 1단계: 예상 비용을 계산해 확인 창을 띄운다
    func requestAIJudgement() {
        guard let p = project else { return }
        let est = AIDigressionJudge().estimate(p)
        guard est.calls > 0 else {
            aiMessage = p.manuscript == nil ? "원고가 없어 AI 판정할 후보가 없습니다." : "AI로 판정할 탈선 후보가 없습니다."
            return
        }
        pendingAIEstimate = est
    }

    /// 2단계: 확인 후 실행. only가 있으면 그 후보만(실패 재시도)
    func runAIJudgement(only ids: Set<String>? = nil) {
        guard let p = project, !aiRunning else { return }
        pendingAIEstimate = nil
        let config = aiConfig
        aiRunning = true
        aiProgress = (0, ids?.count ?? p.candidates?.count ?? 0)
        aiTask = Task {
            defer { aiRunning = false }
            do {
                let provider = try config.makeProvider()
                let (result, report) = try await AIDigressionJudge().judge(p, provider: provider, only: ids) { done, total in
                    Task { @MainActor [weak self] in self?.aiProgress = (done, total) }
                }
                // 판정 중 사용자가 바꾼 결정은 보존
                var merged = result
                if let current = project {
                    let userMade = Dictionary(uniqueKeysWithValues: current.segments.filter(\.userOverridden).map { ($0.id, $0) })
                    for i in merged.segments.indices { if let u = userMade[merged.segments[i].id] { merged.segments[i] = u } }
                }
                let before = project.map { Dictionary(uniqueKeysWithValues: $0.segments.map { ($0.id, SegmentState(isRemoved: $0.isRemoved, userOverridden: $0.userOverridden)) }) }
                project = merged
                if let before { undoStack.append(before); redoStack.removeAll(); updateUndoFlags() }
                isDirty = true
                var msg = "AI 판정 완료: \(report.judged)곳 (입력 \(report.promptTokens) · 출력 \(report.completionTokens) 토큰)"
                if report.failed > 0 { msg += "\n실패 \(report.failed)곳 — 로컬 판단을 유지하고 '확인 필요'로 표시했습니다. [실패 재시도]로 다시 시도할 수 있습니다." }
                aiMessage = msg
            } catch {
                if (error as? SermonCutError) != .cancelled { aiMessage = error.localizedDescription }
            }
        }
    }

    func cancelAI() { aiTask?.cancel() }

    // MARK: - 저장/내보내기

    func save(to url: URL? = nil) -> Bool {
        guard let p = project else { return false }
        guard let target = url ?? projectURL else { return false }
        do {
            try ProjectFile.save(p, to: target)
            projectURL = target
            isDirty = false
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func exportFCPXML(to url: URL) {
        guard let p = project, let edl else {
            errorMessage = edlError ?? "내보낼 편집 결과가 없습니다."
            return
        }
        let video = URL(fileURLWithPath: p.videoPath)
        var options = FCPXMLExporter.Options(eventName: "SermonCut",
                                             projectName: video.deletingPathExtension().lastPathComponent + " (SermonCut)",
                                             audioGainDB: p.settings.audioGainDB)
        options.chapterMarkers = ChapterMarkers.fromManuscript(p).map { ($0.sourceSeconds, $0.title) }
        let xml = FCPXMLExporter().export(edl: edl, videoURL: video, options: options)
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = SermonCutError.fileWriteFailed(path: url.path, reason: error.localizedDescription).localizedDescription
        }
    }
}
