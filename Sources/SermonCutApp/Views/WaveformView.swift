import SermonCutCore
import SwiftUI

/// Canvas 파형 + In/Out 마커 + 재생 위치 (구간 선택 화면). 확대·스키밍은 Timeline.swift
struct WaveformView: View {
    enum Mode { case rangeSelect }
    let mode: Mode
    @Environment(AppState.self) private var state
    @State private var drag: DragKind?

    enum DragKind { case inMarker, outMarker, newRange(anchor: Double), seek }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let bounds = state.timelineBounds(.rangeSelect) ?? TimeRange(start: 0, end: 1)
            let vis = state.visibleRange(.rangeSelect) ?? bounds
            let x: (Double) -> CGFloat = { CGFloat(($0 - vis.start) / max(vis.duration, 0.001)) * width }
            let time: (CGFloat) -> Double = { min(max(bounds.start, vis.start + Double($0 / max(width, 1)) * vis.duration), bounds.end) }
            let h = geo.size.height - 20
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    TimelineDrawing.drawPeaks(ctx, waveform: state.waveform, visible: vis, width: size.width, height: h,
                                              color: .secondary.opacity(0.7))
                    TimelineDrawing.drawViewportIndicator(ctx, bounds: bounds, visible: vis, width: size.width, y: size.height - 3)
                }
                // 선택 구간
                if let i = state.inPoint, let o = state.outPoint, o > i {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: max(1, x(o) - x(i)), height: h)
                        .offset(x: x(i))
                }
                if let i = state.inPoint { marker(x(i), label: "I", height: h, color: .green) }
                if let o = state.outPoint { marker(x(o), label: "O", height: h, color: .orange) }
                // 자동 찾기 후보 (▼ 시작 초록 / 끝 주황)
                if let r = state.rangeResult {
                    ForEach(Array(r.starts.enumerated()), id: \.offset) { _, c in candidateMark(x(c.time), color: .green) }
                    ForEach(Array(r.ends.enumerated()), id: \.offset) { _, c in candidateMark(x(c.time), color: .orange) }
                }
                // 재생 위치
                Rectangle().fill(Color.red).frame(width: 1.5, height: h).offset(x: x(state.currentTime))
                if let t = state.skimTime { SkimmerLine(x: x(t), height: h, time: t) }
                TimelineRuler(visible: vis, width: width).offset(y: h + 1)
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let t = time(g.location.x)
                    if drag == nil {
                        if let i = state.inPoint, abs(x(i) - g.startLocation.x) < 8 { drag = .inMarker }
                        else if let o = state.outPoint, abs(x(o) - g.startLocation.x) < 8 { drag = .outMarker }
                        else { drag = .seek }
                    }
                    switch drag {
                    case .inMarker: state.inPoint = min(t, (state.outPoint ?? bounds.end) - 1); state.seek(t)
                    case .outMarker: state.outPoint = max(t, (state.inPoint ?? 0) + 1); state.seek(t)
                    case .seek:
                        if abs(g.translation.width) > 6 {
                            drag = .newRange(anchor: time(g.startLocation.x))
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
            .timelineInteractions(state, screen: .rangeSelect)
        }
    }

    private func marker(_ x: CGFloat, label: String, height: CGFloat, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(label).font(.caption2.bold()).foregroundStyle(.white)
                .padding(.horizontal, 3).background(color)
            Rectangle().fill(color).frame(width: 2, height: height - 14)
        }
        .offset(x: x - 1)
    }

    private func candidateMark(_ x: CGFloat, color: Color) -> some View {
        Image(systemName: "arrowtriangle.down.fill")
            .font(.system(size: 9))
            .foregroundStyle(color)
            .offset(x: x - 4, y: -2)
    }
}

/// 편집 화면 타임라인: 설교 구간 안에서 유지/삭제/확인 필요 + 파형 + 편집점 + 현재 위치
struct TimelineStripView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let bounds = state.timelineBounds(.editor) ?? TimeRange(start: 0, end: 1)
            let vis = state.visibleRange(.editor) ?? bounds
            let x: (Double) -> CGFloat = { CGFloat(($0 - vis.start) / max(vis.duration, 0.001)) * width }
            let h = geo.size.height - 20
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    guard let p = state.project else { return }
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: h)), with: .color(.green.opacity(0.28)))
                    for s in p.segments where s.end >= vis.start && s.start <= vis.end {
                        let rect = CGRect(x: x(s.start), y: 0, width: max(1, x(s.end) - x(s.start)), height: h)
                        if s.isRemoved {
                            ctx.fill(Path(rect), with: .color(.gray.opacity(0.75)))
                        } else if s.needsReview == true {
                            ctx.fill(Path(rect), with: .color(.yellow.opacity(0.5)))
                        }
                    }
                    TimelineDrawing.drawPeaks(ctx, waveform: state.waveform, visible: vis, width: size.width, height: h,
                                              color: .primary.opacity(0.45))
                    // 편집점(클립 경계)
                    if let edl = state.edl {
                        let snap = FrameSnapper(media: edl.media)
                        for (i, c) in edl.clips.enumerated() {
                            let a = x(snap.seconds(c.sourceStartFrame))
                            guard a >= -3, a <= size.width + 3 else { continue }
                            // 핸들 부족(하드컷 폴백) 편집점은 주황색으로 (SPEC §6.2)
                            let short = i > 0 && edl.transitions.first { $0.afterClip == i - 1 }?.handleShortage == true
                            ctx.fill(Path(CGRect(x: a - (short ? 1 : 0.5), y: 0, width: short ? 3 : 1.5, height: h)),
                                     with: .color(short ? .orange : .black.opacity(0.6)))
                        }
                    }
                    for c in state.chapters {
                        guard let t = c.sourceTime else { continue }
                        ctx.fill(Path(CGRect(x: x(t) - 1.5, y: 0, width: 3, height: 8)), with: .color(.orange))
                    }
                    let px = x(state.currentTime)
                    ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: h)), with: .color(.red))
                    TimelineDrawing.drawViewportIndicator(ctx, bounds: bounds, visible: vis, width: size.width, y: size.height - 3)
                }
                if let t = state.skimTime { SkimmerLine(x: x(t), height: h, time: t) }
                TimelineRuler(visible: vis, width: width).offset(y: h + 1)
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let t = vis.start + Double(g.location.x / max(width, 1)) * vis.duration
                state.seek(min(max(bounds.start, t), bounds.end))
            })
            .timelineInteractions(state, screen: .editor)
        }
    }
}
