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
