import AppKit
import SermonCutCore
import SwiftUI

/// 메인 에디터 (SPEC §7.1, §7.2): 키보드만으로 완주 가능해야 한다.
struct EditorView: View {
    @Environment(AppState.self) private var state
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            MediaHeader()
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    PlayerView(player: state.player)
                        .background(Color.black)
                        .frame(minWidth: 420, minHeight: 240)
                    TimelineStripView()
                        .frame(height: 28)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    HStack {
                        Text(timecodeWithFrames(state.currentTime, fps: state.media?.fps ?? 30)).monospacedDigit()
                        Spacer()
                        Button { state.togglePlay() } label: {
                            Image(systemName: state.playbackRate == 0 ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
                .frame(minWidth: 420)
                segmentPane
                    .frame(minWidth: 460)
            }
            Divider()
            statusBar
        }
        .alert("AI 판정", isPresented: Binding(get: { state.pendingAIEstimate != nil }, set: { if !$0 { state.pendingAIEstimate = nil } })) {
            Button("실행") { state.runAIJudgement() }
            Button("취소", role: .cancel) { state.pendingAIEstimate = nil }
        } message: {
            if let e = state.pendingAIEstimate {
                Text("탈선 후보 \(e.calls)곳을 \(state.aiConfig.kind.displayName)(\(state.aiConfig.model))로 판정합니다.\n예상 약 \(e.totalTokens.formatted()) 토큰 (입력 \(e.promptTokens.formatted()) · 출력 \(e.completionTokens.formatted())), 호출 \(e.calls)회.\n결과는 제안이며 직접 바꾼 항목은 건드리지 않습니다.")
            }
        }
        .sheet(isPresented: Binding(get: { state.showChapters }, set: { state.showChapters = $0 })) {
            ChaptersView().environment(state)
        }
        .alert("렌더", isPresented: Binding(get: { state.renderMessage != nil }, set: { if !$0 { state.renderMessage = nil } })) {
            Button("열기") { if let u = state.lastRenderURL { NSWorkspace.shared.open(u) }; state.renderMessage = nil }
            Button("Finder에서 보기") { if let u = state.lastRenderURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }; state.renderMessage = nil }
            Button("닫기", role: .cancel) { state.renderMessage = nil }
        } message: {
            Text(state.renderMessage ?? "")
        }
        .alert("AI 판정", isPresented: Binding(get: { state.aiMessage != nil }, set: { if !$0 { state.aiMessage = nil } })) {
            Button("확인") { state.aiMessage = nil }
        } message: {
            Text(state.aiMessage ?? "")
        }
    }

    // MARK: 전사문 목록

    private var segmentPane: some View {
        @Bindable var state = state
        return VStack(spacing: 6) {
            HStack {
                TextField("검색", text: $state.search)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $state.filter) {
                    ForEach(SegmentFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            ScrollViewReader { proxy in
                List(state.visibleSegments, selection: $state.selection) { seg in
                    SegmentRowView(segment: seg, isCurrent: seg.id == state.currentSegmentID,
                                   sentence: sentenceText(seg.matchedManuscriptID))
                        .tag(seg.id)
                        .id(seg.id)
                        .contextMenu {
                            Button(seg.isRemoved ? "복원" : "삭제") { state.toggleRemoved(state.selection.contains(seg.id) ? state.selection : [seg.id]) }
                            Button("여기부터 재생") { state.play(from: seg.start, until: nil) }
                        }
                }
                .listStyle(.inset)
                .focused($listFocused)
                .onAppear { listFocused = true }
                .onKeyPress(phases: .down) { press in handleKey(press) }
                .onChange(of: state.selection) { _, new in
                    // 선택을 옮기면 그 위치로 이동 (재생 중이 아닐 때)
                    if new.count == 1, let id = new.first, state.playbackRate == 0,
                       let seg = state.project?.segments.first(where: { $0.id == id }) {
                        state.seek(seg.start)
                    }
                }
                .onChange(of: state.currentSegmentID) { _, id in
                    if state.playbackRate != 0, let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Text("↑↓ 이동 · D/Delete 삭제·복원 · Space 현재 세그먼트 재생 · ⇧/⌘ 클릭 다중 선택 · ⌘⌫ 선택 삭제 · ⌘Z 실행 취소 · ⌘S 저장")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
    }

    private func sentenceText(_ id: String?) -> String? {
        guard let id else { return nil }
        return state.project?.manuscript?.sentences.first { $0.id == id }?.text
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .delete || press.key == .deleteForward {
            if press.modifiers.contains(.command) { state.remove(state.selection) } else { state.toggleRemoved(state.selection) }
            return .handled
        }
        if press.key == .space {
            if state.playbackRate != 0 {
                state.togglePlay()
            } else if let id = state.selection.first, let seg = state.project?.segments.first(where: { $0.id == id }) {
                state.play(from: seg.start, until: seg.end)
            } else {
                state.togglePlay()
            }
            return .handled
        }
        switch press.characters.lowercased() {
        case "d", "ㅇ":
            state.toggleRemoved(state.selection)
            return .handled
        case "j", "ㅓ": state.shuttle("j"); return .handled
        case "k", "ㅏ": state.shuttle("k"); return .handled
        case "l", "ㅣ": state.shuttle("l"); return .handled
        default: return .ignored
        }
    }

    // MARK: 하단 상태 줄

    private var statusBar: some View {
        let segs = state.project?.segments ?? []
        let removed = segs.filter(\.isRemoved).count
        let review = segs.filter { $0.needsReview == true }.count
        let snap = state.media.map(FrameSnapper.init)
        let total = state.edl.flatMap { edl in snap?.seconds(edl.totalFrames) }
        let original = state.project?.sourceRange.duration ?? 0
        let settings = state.project?.settings ?? ExportSettings()
        return VStack(spacing: 6) {
            HStack(spacing: 14) {
                Text("유지 \(segs.count - removed)개 / 삭제 \(removed)개")
                if review > 0 { Label("확인 필요 \(review)개", systemImage: "exclamationmark.triangle").foregroundStyle(.yellow) }
                Divider().frame(height: 14)
                if let total {
                    Text("예상 \(Timecode.format(total, millis: false)) (−\(Timecode.format(max(0, original - total), millis: false)))")
                        .monospacedDigit()
                }
                if let n = state.edl?.clips.count { Text("클립 \(n)개") }
                if let short = state.edl?.handleShortageCount, short > 0 {
                    Label("핸들 부족 \(short)곳 (하드컷)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if let err = state.edlError { Text(err).foregroundStyle(.red) }
                Spacer()
                if state.isDirty { Text("저장 안 됨").foregroundStyle(.secondary) }
            }
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Text("디졸브")
                    TextField("", value: Binding(get: { settings.transitionDuration },
                                                 set: { v in state.updateSettings { $0.transitionDuration = max(0, v) } }),
                              format: .number.precision(.fractionLength(1)))
                        .frame(width: 40)
                    Text("초")
                }
                Toggle("무음 스냅", isOn: Binding(get: { settings.snapToSilence },
                                               set: { v in state.updateSettings { $0.snapToSilence = v } }))
                HStack(spacing: 4) {
                    Text("패딩")
                    TextField("", value: Binding(get: { settings.padHead },
                                                 set: { v in state.updateSettings { $0.padHead = max(0, v); $0.padTail = max(0, v) } }),
                              format: .number.precision(.fractionLength(2)))
                        .frame(width: 44)
                    Text("초")
                }
                HStack(spacing: 4) {
                    Text("볼륨")
                    TextField("", value: Binding(get: { settings.audioGainDB },
                                                 set: { v in state.updateSettings { $0.audioGainDB = v } }),
                              format: .number.precision(.fractionLength(0)))
                        .frame(width: 36)
                    Text("dB")
                }
                Spacer()
                if state.aiRunning {
                    ProgressView(value: Double(state.aiProgress.done), total: Double(max(1, state.aiProgress.total))) {
                        Text("AI 판정 \(state.aiProgress.done)/\(state.aiProgress.total)").font(.caption)
                    }
                    .frame(width: 160)
                    Button("중지") { state.cancelAI() }
                } else {
                    Button("AI 판정…") { state.requestAIJudgement() }
                        .help("원고를 벗어난 후보 구간을 AI가 판정합니다 (\(state.aiConfig.kind.displayName) · \(state.aiConfig.model))")
                    if !state.failedCandidateIDs.isEmpty {
                        Button("실패 재시도 (\(state.failedCandidateIDs.count))") { state.runAIJudgement(only: state.failedCandidateIDs) }
                    }
                }
                Button("목차…") { state.showChapters = true }
                    .help("유튜브 챕터용 설교 목차 (⌘T)")
                Toggle("내보낸 뒤 FCP로 열기", isOn: Binding(get: { state.openInFCPAfterExport }, set: { state.openInFCPAfterExport = $0 }))
                    .toggleStyle(.checkbox)
                Button("FCPXML 내보내기…") { FilePanels.exportFCPXML(state) }
                    .disabled(state.edl == nil)
                if state.renderRunning {
                    ProgressView(value: state.renderProgress) {
                        Text("\(state.renderPreset == .preview ? "프리뷰" : "최종") 렌더 \(Int(state.renderProgress * 100))%").font(.caption)
                    }
                    .frame(width: 140)
                    Button("중지") { state.cancelRender() }
                } else {
                    Menu("렌더") {
                        Button("프리뷰 (960x540, 빠름)") { FilePanels.render(state, preset: .preview) }
                        Button("최종 MP4 (1080p, H.264 5Mbps)") { FilePanels.render(state, preset: .final) }
                    }
                    .fixedSize()
                    .disabled(state.edl == nil)
                }
            }
        }
        .padding(10)
    }
}

/// 세그먼트 행 시각 규칙 (SPEC §7.3)
struct SegmentRowView: View {
    let segment: TranscriptSegment
    let isCurrent: Bool
    let sentence: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(leftBorder)
                .frame(width: 4)
            Text(Timecode.format(segment.start, millis: false))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.text)
                    .strikethrough(segment.isRemoved)
                    .foregroundStyle(segment.isRemoved ? .secondary : .primary)
                if let sentence, !segment.isRemoved {
                    Text("↳ \(sentence)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.gray.opacity(0.25)))
            }
        }
        .padding(.vertical, 2)
        .background(segment.isRemoved ? Color.gray.opacity(0.18) : Color.clear)
        .help(segment.aiNote ?? "")
        .overlay(alignment: .leading) {
            if segment.alignStatus == .failed {
                RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                    .foregroundStyle(.gray)
            }
        }
    }

    private var leftBorder: Color {
        if isCurrent { return .blue }
        if segment.needsReview == true, !segment.userOverridden { return .yellow }
        return .clear
    }

    /// 자동 삭제만 사유 뱃지, 사용자 삭제는 뱃지 없음
    private var badge: String? {
        guard !segment.userOverridden else { return nil }
        switch segment.unmatchedReason {
        case .improvised?: return segment.isRemoved ? "화제 이탈" : nil
        case .greeting?: return segment.isRemoved ? "인사·기도" : nil
        case .unknown?: return "확인 필요"
        case .filler?: return "필러"
        case .repetition?: return "반복"
        default: return nil
        }
    }
}
