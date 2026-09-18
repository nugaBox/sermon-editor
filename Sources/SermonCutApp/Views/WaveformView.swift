import SermonCutCore
import SwiftUI

/// Canvas 파형 + In/Out 마커 + 재생 위치 (구간 선택 화면)
struct WaveformView: View {
    enum Mode { case rangeSelect }
    let mode: Mode
    @Environment(AppState.self) private var state
    @State private var drag: DragKind?

    enum DragKind { case inMarker, outMarker, newRange(anchor: Double), seek }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = max(state.duration, 0.001)
            let x: (Double) -> CGFloat = { CGFloat($0 / duration) * width }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    drawWaveform(ctx, size: size)
                }
                // 선택 구간
                if let i = state.inPoint, let o = state.outPoint, o > i {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: max(1, x(o) - x(i)), height: geo.size.height - 16)
                        .offset(x: x(i))
                }
                if let i = state.inPoint { marker(x(i), label: "I", height: geo.size.height - 16, color: .green) }
                if let o = state.outPoint { marker(x(o), label: "O", height: geo.size.height - 16, color: .orange) }
                // 재생 위치
                Rectangle().fill(Color.red).frame(width: 1.5, height: geo.size.height - 16).offset(x: x(state.currentTime))
                ruler(width: width, duration: duration).offset(y: geo.size.height - 14)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let t = min(max(0, Double(g.location.x / width) * duration), duration)
                    if drag == nil {
                        let startT = Double(g.startLocation.x / width) * duration
                        if let i = state.inPoint, abs(x(i) - g.startLocation.x) < 8 { drag = .inMarker }
                        else if let o = state.outPoint, abs(x(o) - g.startLocation.x) < 8 { drag = .outMarker }
                        else { drag = .seek; _ = startT }
                    }
                    switch drag {
                    case .inMarker: state.inPoint = min(t, (state.outPoint ?? duration) - 1); state.seek(t)
                    case .outMarker: state.outPoint = max(t, (state.inPoint ?? 0) + 1); state.seek(t)
                    case .seek:
                        if abs(g.translation.width) > 6 {
                            drag = .newRange(anchor: Double(g.startLocation.x / width) * duration)
                        } else {
                            state.seek(t)
                        }
                    case .newRange(let anchor):
                        state.inPoint = min(anchor, t)
                        state.outPoint = max(anchor, t)
                    case nil: break
                    }
                }
                .onEnded { _ in drag = nil })
        }
    }

    private func drawWaveform(_ ctx: GraphicsContext, size: CGSize) {
        let h = size.height - 16
        guard let w = state.waveform, !w.peaks.isEmpty, size.width > 0 else {
            ctx.fill(Path(CGRect(x: 0, y: h / 2 - 0.5, width: size.width, height: 1)), with: .color(.secondary.opacity(0.4)))
            return
        }
        let cols = Int(size.width)
        let perCol = Double(w.peaks.count) / Double(max(cols, 1)) * (w.duration / max(state.duration, w.duration))
        var path = Path()
        let peakMax = max(w.peaks.max() ?? 1, 0.05)
        for c in 0..<cols {
            let a = Int(Double(c) * perCol), b = min(w.peaks.count, max(a + 1, Int(Double(c + 1) * perCol)))
            guard a < w.peaks.count else { break }
            var m: Float = 0
            for k in a..<b where w.peaks[k] > m { m = w.peaks[k] }
            let amp = CGFloat(m / peakMax) * h / 2
            path.addRect(CGRect(x: CGFloat(c), y: h / 2 - amp, width: 1, height: max(1, amp * 2)))
        }
        ctx.fill(path, with: .color(.secondary.opacity(0.7)))
    }

    private func marker(_ x: CGFloat, label: String, height: CGFloat, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.caption2.bold()).foregroundStyle(.white)
                .padding(.horizontal, 3).background(color)
            Rectangle().fill(color).frame(width: 2, height: height - 14)
        }
        .offset(x: x - 1)
    }

    private func ruler(width: CGFloat, duration: Double) -> some View {
        let step: Double = duration > 3600 ? 900 : (duration > 1200 ? 300 : 60)
        return ZStack(alignment: .leading) {
            ForEach(Array(stride(from: 0.0, through: duration, by: step)), id: \.self) { t in
                Text(Timecode.format(t, millis: false))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .offset(x: CGFloat(t / duration) * width + 2)
            }
        }
    }
}

/// 편집 화면 타임라인 스트립: 설교 구간 안에서 유지/삭제/확인 필요/현재 위치
struct TimelineStripView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard let p = state.project else { return }
                let r = p.sourceRange
                let x: (Double) -> CGFloat = { CGFloat(($0 - r.start) / max(r.duration, 0.001)) * size.width }
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.green.opacity(0.35)))
                for s in p.segments {
                    let rect = CGRect(x: x(s.start), y: 0, width: max(1, x(s.end) - x(s.start)), height: size.height)
                    if s.isRemoved {
                        ctx.fill(Path(rect), with: .color(.gray.opacity(0.85)))
                    } else if s.needsReview == true {
                        ctx.fill(Path(rect), with: .color(.yellow.opacity(0.6)))
                    }
                }
                // 편집점(클립 경계)
                if let edl = state.edl {
                    let snap = FrameSnapper(media: edl.media)
                    for (i, c) in edl.clips.enumerated() {
                        let a = x(snap.seconds(c.sourceStartFrame))
                        // 핸들 부족(하드컷 폴백) 편집점은 주황색으로 (SPEC §6.2)
                        let short = i > 0 && edl.transitions.first { $0.afterClip == i - 1 }?.handleShortage == true
                        ctx.fill(Path(CGRect(x: a - (short ? 1 : 0), y: 0, width: short ? 3 : 1, height: size.height)),
                                 with: .color(short ? .orange : .black.opacity(0.5)))
                    }
                }
                for m in ChapterMarkers.fromManuscript(p) {
                    let a = x(m.sourceSeconds)
                    ctx.fill(Path(CGRect(x: a - 1, y: 0, width: 3, height: 6)), with: .color(.orange))
                }
                let px = x(state.currentTime)
                ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.red))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard let r = state.project?.sourceRange else { return }
                let t = r.start + Double(g.location.x / geo.size.width) * r.duration
                state.seek(min(max(r.start, t), r.end))
            })
        }
    }
}
