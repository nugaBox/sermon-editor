import AVKit
import SermonCutCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Group {
            switch state.screen {
            case .welcome: WelcomeView()
            case .rangeSelect: RangeSelectView()
            case .manuscript: ManuscriptPickerView()
            case .analyzing: AnalyzeProgressView()
            case .editor: EditorView()
            }
        }
        .alert("오류", isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })) {
            Button("확인") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

/// 상단 정보 줄: 파일명 │ 길이 │ 해상도 │ fps
struct MediaHeader: View {
    @Environment(AppState.self) private var state
    var body: some View {
        HStack(spacing: 10) {
            Text(state.videoURL?.lastPathComponent ?? "").font(.headline).lineLimit(1)
            if let m = state.media {
                Divider().frame(height: 14)
                Text(Timecode.format(m.durationSeconds, millis: false)).monospacedDigit()
                Divider().frame(height: 14)
                Text("\(m.width)x\(m.height)")
                Divider().frame(height: 14)
                Text(String(format: "%.2ffps", m.fps))
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// AVKit 플레이어 (조작부 없음 — 키보드는 화면별로 처리)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

/// "1:02:23:12" (시:분:초:프레임)
func timecodeWithFrames(_ t: Double, fps: Double) -> String {
    let total = max(0, t)
    let whole = Int(total)
    let frames = Int(((total - Double(whole)) * fps).rounded(.down))
    let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
    return String(format: "%02d:%02d:%02d:%02d", h, m, s, frames)
}
