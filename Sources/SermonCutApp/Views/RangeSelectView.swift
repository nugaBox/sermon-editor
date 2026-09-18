import SermonCutCore
import SwiftUI

/// 설교 구간 선택 (SPEC §6.0, §7.0)
struct RangeSelectView: View {
    @Environment(AppState.self) private var state
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var state = state
        let fps = state.media?.fps ?? 30
        VStack(spacing: 0) {
            MediaHeader()
            Divider()
            PlayerView(player: state.player)
                .frame(minHeight: 300)
                .background(Color.black)
            Divider()
            WaveformView(mode: .rangeSelect)
                .frame(height: 120)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                timeField("현재", state.currentTime, fps: fps)
                timeField("In", state.inPoint, fps: fps)
                timeField("Out", state.outPoint, fps: fps)
                if let i = state.inPoint, let o = state.outPoint, o > i {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("길이").font(.caption).foregroundStyle(.secondary)
                        Text(Timecode.format(o - i, millis: false)).monospacedDigit().font(.title3)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    Text("여유 앞")
                    TextField("", value: $state.marginHead, format: .number.precision(.fractionLength(1)))
                        .frame(width: 44)
                    Text("초 · 뒤")
                    TextField("", value: $state.marginTail, format: .number.precision(.fractionLength(1)))
                        .frame(width: 44)
                    Text("초")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            autoFindBar
                .padding(.horizontal, 12)
                .padding(.top, 6)
            HStack {
                Text("I / O: 구간 지정 · ←/→ 1초 · ⇧ 10초 · ⌥ 1프레임 · J/K/L 역재생/정지/재생 · Space 재생")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.waveform == nil {
                    ProgressView(value: state.waveformProgress) { Text("파형 만드는 중").font(.caption) }
                        .frame(width: 160)
                }
                Spacer()
                Button("처음으로") { state.screen = .welcome }
                Button("다음 → 원고 선택") { state.screen = .manuscript }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.sourceRange == nil)
            }
            .padding(12)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    /// 🔍 설교 구간 자동 찾기 — 후보만 보여주고 적용은 사용자가 누른다 (SPEC §6.0)
    @ViewBuilder
    private var autoFindBar: some View {
        HStack(alignment: .center, spacing: 10) {
            if state.rangeScanRunning {
                ProgressView(value: state.rangeScanProgress.screen) { Text("화면 글자 읽는 중").font(.caption) }
                    .frame(width: 150)
                ProgressView(value: state.rangeScanProgress.audio) { Text("음성 빠른 전사").font(.caption) }
                    .frame(width: 150)
                Button("중지") { state.cancelAutoFind() }
            } else {
                Button { state.autoFindRange() } label: { Label("설교 구간 자동 찾기", systemImage: "magnifyingglass") }
                    .help("화면의 ‘성경 봉독’·설교 자막·‘봉헌’ 화면과 봉독 안내 음성으로 후보를 찾습니다 (약 3~4분, 결과는 저장됨)")
            }
            if let r = state.rangeResult {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array((r.starts + r.ends).enumerated()), id: \.offset) { _, c in
                            let isStart = r.starts.contains(c)
                            Button {
                                state.seek(c.time)
                            } label: {
                                Text("\(isStart ? "▶︎" : "◀︎") \(Timecode.format(c.time, millis: false)) \(c.label)")
                                    .font(.caption).lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .tint(isStart ? .green : .orange)
                            .contextMenu {
                                Button("In으로 지정") { state.setIn(c.time) }
                                Button("Out으로 지정") { state.setOut(c.time) }
                            }
                        }
                    }
                }
                if let s = r.suggested {
                    Button("추천 구간 적용 (\(Timecode.format(s.start, millis: false)) ~ \(Timecode.format(s.end, millis: false)))") {
                        state.applySuggestedRange()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        let option = press.modifiers.contains(.option)
        switch press.key {
        case .leftArrow:
            if option { state.stepFrame(-1) } else { state.nudge(shift ? -10 : -1) }
            return .handled
        case .rightArrow:
            if option { state.stepFrame(1) } else { state.nudge(shift ? 10 : 1) }
            return .handled
        case .space:
            state.togglePlay()
            return .handled
        default:
            break
        }
        switch press.characters.lowercased() {
        case "i", "ㅑ": state.setIn(); return .handled
        case "o", "ㅐ": state.setOut(); return .handled
        case "j", "ㅓ": state.shuttle("j"); return .handled
        case "k", "ㅏ": state.shuttle("k"); return .handled
        case "l", "ㅣ": state.shuttle("l"); return .handled
        default: return .ignored
        }
    }

    private func timeField(_ label: String, _ t: Double?, fps: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(t.map { timecodeWithFrames($0, fps: fps) } ?? "--:--:--:--")
                .monospacedDigit()
                .font(.title3)
        }
    }
}
