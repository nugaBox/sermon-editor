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
        let review = segs.filter { !$0.isRemoved && $0.unmatchedReason == .unknown }.count
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
                Button("FCPXML 내보내기…") { FilePanels.exportFCPXML(state) }
                    .disabled(state.edl == nil)
                Button("프리뷰 렌더") {}
                    .disabled(true)
                    .help("Phase 4에서 추가됩니다")
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
        .overlay(alignment: .leading) {
            if segment.alignStatus == .failed {
                RoundedRectangle(cornerRadius: 3).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                    .foregroundStyle(.gray)
            }
        }
    }

    private var leftBorder: Color {
        if isCurrent { return .blue }
        if segment.unmatchedReason == .unknown { return .yellow }
        if segment.isRemoved, !segment.userOverridden, segment.unmatchedReason == .greeting || segment.unmatchedReason == .improvised {
            return .yellow.opacity(0.7)
        }
        return .clear
    }

    /// 자동 삭제만 사유 뱃지, 사용자 삭제는 뱃지 없음
    private var badge: String? {
        guard !segment.userOverridden else { return nil }
        switch segment.unmatchedReason {
        case .improvised?: return segment.isRemoved ? "화제 이탈" : nil
        case .unknown?: return "확인 필요"
        case .filler?: return "필러"
        case .repetition?: return "반복"
        case .greeting?: return "인사"
        default: return nil
        }
    }
}
