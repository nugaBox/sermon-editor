import AppKit
import AVFoundation
import SermonCutCore
import SwiftUI

/// 타임라인 확대·이동 상태. zoom 1 = 전체가 한 화면, start = 보이는 구간 시작(원본 0초 기준)
struct TimelineViewport: Equatable {
    var zoom: Double = 1
    var start: Double = 0
}

// MARK: - 확대·축소·이동 (Final Cut Pro: ⌘= / ⌘- / ⇧Z, 트랙패드 핀치·두 손가락 스크롤)

extension AppState {
    /// 확대해도 이보다 짧게는 안 보여준다 (파형 버킷이 초당 약 10개)
    static let minimumVisibleSeconds: Double = 10

    /// 화면별 타임라인 전체 범위: 구간 선택 = 영상 전체, 편집 = 설교 구간
    func timelineBounds(_ s: Screen) -> TimeRange? {
        switch s {
        case .rangeSelect: return duration > 0 ? TimeRange(start: 0, end: duration) : nil
        case .editor: return project?.sourceRange
        default: return nil
        }
    }

    func viewport(_ s: Screen) -> TimelineViewport { s == .editor ? editorViewport : rangeViewport }

    private func setViewport(_ s: Screen, _ v: TimelineViewport) {
        if s == .editor { editorViewport = v } else { rangeViewport = v }
    }

    func maxZoom(_ s: Screen) -> Double {
        guard let b = timelineBounds(s) else { return 1 }
        return max(1, b.duration / Self.minimumVisibleSeconds)
    }

    /// 지금 보이는 구간
    func visibleRange(_ s: Screen) -> TimeRange? {
        guard let b = timelineBounds(s), b.duration > 0 else { return nil }
        let vp = viewport(s)
        let d = b.duration / min(max(vp.zoom, 1), maxZoom(s))
        let start = min(max(vp.start, b.start), b.end - d)
        return TimeRange(start: start, end: start + d)
    }

    /// anchor(원본 시간)가 화면에서 같은 자리에 머물도록 확대·축소. anchor가 없으면 재생 위치(보일 때) 또는 화면 가운데
    func zoomTimeline(_ screen: Screen? = nil, by factor: Double, around anchor: Double? = nil) {
        let s = screen ?? self.screen
        guard let b = timelineBounds(s), let vis = visibleRange(s), factor > 0 else { return }
        let a = anchor ?? (vis.start <= currentTime && currentTime <= vis.end ? currentTime : (vis.start + vis.end) / 2)
        let fraction = (a - vis.start) / vis.duration
        let zoom = min(max(viewport(s).zoom * factor, 1), maxZoom(s))
        let d = b.duration / zoom
        setViewport(s, TimelineViewport(zoom: zoom, start: min(max(a - fraction * d, b.start), b.end - d)))
    }

    /// 확대 비율을 직접 지정 (확대 슬라이더)
    func setTimelineZoom(_ zoom: Double, _ screen: Screen? = nil) {
        let s = screen ?? self.screen
        let current = viewport(s).zoom
        guard current > 0 else { return }
        zoomTimeline(s, by: zoom / current)
    }

    func fitTimeline(_ screen: Screen? = nil) {
        let s = screen ?? self.screen
        guard let b = timelineBounds(s) else { return }
        setViewport(s, TimelineViewport(zoom: 1, start: b.start))
    }

    func panTimeline(_ s: Screen, by seconds: Double) {
        guard let b = timelineBounds(s), let vis = visibleRange(s) else { return }
        var vp = viewport(s)
        vp.start = min(max(vis.start + seconds, b.start), b.end - vis.duration)
        setViewport(s, vp)
    }

    /// 재생 위치가 화면 밖으로 나가면 따라간다 (재생 중에는 한 화면씩 넘김, 멈춰 있으면 가운데로)
    func revealPlayhead() {
        let s = screen
        guard viewport(s).zoom > 1, let b = timelineBounds(s), let vis = visibleRange(s) else { return }
        let t = currentTime
        guard t < vis.start || t > vis.end else { return }
        let start = playbackRate > 0 && t > vis.end ? t - vis.duration * 0.05 : t - vis.duration / 2
        var vp = viewport(s)
        vp.start = min(max(start, b.start), b.end - vis.duration)
        setViewport(s, vp)
    }
}

// MARK: - 스키밍 (Final Cut Pro: S 스키밍, ⇧S 오디오 스키밍)

extension AppState {
    /// 마우스가 타임라인 위에 있을 때의 원본 시간. 재생 위치(currentTime)는 건드리지 않고
    /// 별도 플레이어(skimPlayer)로 그 프레임·소리를 보여준다. 재생 중에는 스키밍하지 않는다.
    func skim(to t: Double?) {
        guard let t, skimmingEnabled, player.rate == 0 else { endSkim(); return }
        skimTime = t
        if audioSkimmingEnabled {
            // 움직이는 동안 1배속으로 이어 재생, 0.3초 넘게 어긋나면 그 자리로 다시 이동, 멈추면 0.25초 뒤 정지
            skimPlayUntil = Date().addingTimeInterval(0.25)
            let drift = abs(skimPlayer.currentTime().seconds - t)
            if skimPlayer.rate == 0 || drift > 0.3 { chaseSkim(t, thenPlay: true) }
            skimStopTask?.cancel()
            skimStopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self?.skimPlayer.pause()
            }
        } else {
            chaseSkim(t, thenPlay: false)
        }
    }

    func endSkim() {
        guard skimTime != nil || skimPlayer.rate != 0 else { return }
        skimTime = nil
        skimPending = nil
        skimStopTask?.cancel()
        skimPlayer.pause()
    }

    /// 마지막 위치만 따라가는 탐색 — 앞 탐색이 끝나기 전 새 위치가 오면 중간 위치는 건너뛴다
    private func chaseSkim(_ t: Double, thenPlay: Bool) {
        skimPending = t
        skimPlayAfterSeek = thenPlay
        guard skimTask == nil else { return }
        skimTask = Task { [weak self] in
            while let target = self?.skimPending, let player = self?.skimPlayer {
                self?.skimPending = nil
                _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if let self, self.skimPlayAfterSeek, self.skimTime != nil, Date() < self.skimPlayUntil {
                    player.play()
                }
            }
            self?.skimTask = nil
        }
    }

    func toggleSkimming() { skimmingEnabled.toggle() }

    /// 오디오 스키밍은 스키밍이 켜져 있을 때만 동작하므로 켤 때 스키밍도 같이 켠다
    func toggleAudioSkimming() {
        audioSkimmingEnabled.toggle()
        if audioSkimmingEnabled { skimmingEnabled = true }
    }

    /// 두 타임라인(구간 선택·편집)에서 같이 쓰는 단축키. 처리했으면 true
    func handleTimelineKey(_ press: KeyPress) -> Bool {
        let shift = press.modifiers.contains(.shift)
        let command = press.modifiers.contains(.command)
        let c = press.characters.lowercased()
        if command {
            switch c {
            case "=", "+": zoomTimeline(by: 1.5); return true
            case "-", "_": zoomTimeline(by: 1 / 1.5); return true
            default: return false
            }
        }
        switch c {
        case "s", "ㄴ":
            if shift { toggleAudioSkimming() } else { toggleSkimming() }
            return true
        case "z", "ㅋ" where shift:
            fitTimeline()
            return true
        default:
            return false
        }
    }
}

// MARK: - 그리기 도우미

enum TimelineDrawing {
    /// 보이는 구간의 파형을 열 단위 최대값으로 그린다
    static func drawPeaks(_ ctx: GraphicsContext, waveform w: Waveform?, visible: TimeRange, width: CGFloat, height h: CGFloat,
                          color: Color) {
        guard let w, !w.peaks.isEmpty, width > 0, w.duration > 0, visible.duration > 0 else {
            ctx.fill(Path(CGRect(x: 0, y: h / 2 - 0.5, width: width, height: 1)), with: .color(color.opacity(0.5)))
            return
        }
        let perSecond = Double(w.peaks.count) / w.duration
        let cols = Int(width)
        let secondsPerCol = visible.duration / Double(max(cols, 1))
        let peakMax = max(w.peaks.max() ?? 1, 0.05)
        var path = Path()
        for c in 0..<cols {
            let t0 = visible.start + Double(c) * secondsPerCol
            let a = Int(t0 * perSecond)
            let b = max(a + 1, Int((t0 + secondsPerCol) * perSecond))
            guard a >= 0, a < w.peaks.count else { continue }
            var m: Float = 0
            for k in a..<min(b, w.peaks.count) where w.peaks[k] > m { m = w.peaks[k] }
            let amp = CGFloat(m / peakMax) * h / 2
            path.addRect(CGRect(x: CGFloat(c), y: h / 2 - amp, width: 1, height: max(1, amp * 2)))
        }
        ctx.fill(path, with: .color(color))
    }

    /// 눈금 간격: 글자가 약 90px 이상 떨어지는 가장 촘촘한 간격
    static func rulerStep(visibleSeconds: Double, width: CGFloat) -> Double {
        let minimum = visibleSeconds * 90 / Double(max(width, 1))
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        return steps.first { $0 >= minimum } ?? 3600
    }

    /// 확대했을 때 전체 중 어디를 보고 있는지 표시하는 얇은 막대
    static func drawViewportIndicator(_ ctx: GraphicsContext, bounds: TimeRange, visible: TimeRange, width: CGFloat, y: CGFloat) {
        guard bounds.duration > 0, visible.duration < bounds.duration - 0.01 else { return }
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: width, height: 3), cornerRadius: 1.5), with: .color(.secondary.opacity(0.15)))
        let a = CGFloat((visible.start - bounds.start) / bounds.duration) * width
        let w = max(6, CGFloat(visible.duration / bounds.duration) * width)
        ctx.fill(Path(roundedRect: CGRect(x: a, y: y, width: w, height: 3), cornerRadius: 1.5), with: .color(.secondary.opacity(0.6)))
    }
}

/// 타임라인 눈금 (보이는 구간 기준)
struct TimelineRuler: View {
    let visible: TimeRange
    let width: CGFloat

    var body: some View {
        let step = TimelineDrawing.rulerStep(visibleSeconds: visible.duration, width: width)
        let first = (visible.start / step).rounded(.up) * step
        ZStack(alignment: .leading) {
            ForEach(Array(stride(from: first, through: visible.end, by: step)), id: \.self) { t in
                Text(Timecode.format(t, millis: false))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: CGFloat((t - visible.start) / visible.duration) * width + 2)
            }
        }
        .frame(width: width, alignment: .leading)
        .clipped()
    }
}

/// 스키머 선 + 시간 표시
struct SkimmerLine: View {
    let x: CGFloat
    let height: CGFloat
    let time: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.pink).frame(width: 1.5, height: height).offset(x: x - 0.75)
            Text(Timecode.format(time, millis: false))
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(Color.pink))
                .fixedSize()
                .offset(x: x + 4, y: 0)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 뷰어 (재생 위치 + 스키밍)

/// 스키밍 중이면 스키밍 플레이어 화면을, 아니면 재생 위치 화면을 보여준다
struct ViewerView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            PlayerView(player: state.player)
            PlayerView(player: state.skimPlayer)
                .opacity(state.skimTime == nil ? 0 : 1)
        }
    }
}

// MARK: - 타임라인 컨트롤 (스키밍 토글·확대 슬라이더)

struct TimelineControls: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let s = state.screen
        let maxZoom = state.maxZoom(s)
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { state.skimmingEnabled }, set: { state.skimmingEnabled = $0 })) {
                Label("스키밍", systemImage: "hand.point.up.left")
            }
            .toggleStyle(.button)
            .help("스키밍 (S): 타임라인에 마우스를 올리면 그 위치 영상을 보여줍니다")
            Toggle(isOn: Binding(get: { state.audioSkimmingEnabled }, set: { v in
                state.audioSkimmingEnabled = v
                if v { state.skimmingEnabled = true }
            })) {
                Label("오디오", systemImage: "waveform")
            }
            .toggleStyle(.button)
            .help("오디오 스키밍 (⇧S): 마우스를 움직이는 동안 그 위치 소리를 들려줍니다")
            Divider().frame(height: 16)
            Button { state.zoomTimeline(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("축소 (⌘-)")
            Slider(value: Binding(get: { log(max(state.viewport(s).zoom, 1)) / log(max(maxZoom, 1.0001)) },
                                  set: { v in state.setTimelineZoom(exp(v * log(max(maxZoom, 1.0001)))) }),
                   in: 0...1)
                .frame(width: 120)
                .disabled(maxZoom <= 1)
            Button { state.zoomTimeline(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.borderless)
                .help("확대 (⌘+) · 트랙패드 핀치 · 두 손가락 좌우로 이동")
            Button("전체") { state.fitTimeline() }
                .buttonStyle(.borderless)
                .help("전체 보기 (⇧Z)")
        }
        .controlSize(.small)
    }
}

// MARK: - 트랙패드 핀치·스크롤 받기

/// 타임라인 영역 위의 핀치(확대)·두 손가락 스크롤(이동)을 받는다.
/// SwiftUI 제스처를 가리지 않도록 클릭은 통과시키고(hitTest nil), 창의 이벤트를 보고 영역 안인지만 확인한다.
struct TimelineEventCatcher: NSViewRepresentable {
    /// 가로 이동량(포인트, 오른쪽으로 쓸면 +)
    var onScroll: (CGFloat) -> Void
    /// 배율 변화(+면 확대)와 영역 안 가로 위치 비율 0~1
    var onMagnify: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.onScroll = onScroll
        v.onMagnify = onMagnify
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var onMagnify: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, event.window === self.window, self.bounds.width > 0 else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                if event.type == .magnify {
                    self.onMagnify?(event.magnification, p.x / self.bounds.width)
                } else {
                    // 트랙패드는 가로, 마우스 휠은 세로 값을 가로 이동으로
                    var d = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                    if !event.hasPreciseScrollingDeltas { d *= 10 }
                    self.onScroll?(d)
                }
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            super.removeFromSuperview()
        }
    }
}

extension View {
    /// 타임라인 공통 상호작용: 핀치 확대, 두 손가락 스크롤 이동, 마우스 올리면 스키밍
    func timelineInteractions(_ state: AppState, screen: Screen) -> some View {
        GeometryReader { geo in
            self
                .background(TimelineEventCatcher(
                    onScroll: { dx in
                        guard let vis = state.visibleRange(screen), geo.size.width > 0 else { return }
                        state.panTimeline(screen, by: -Double(dx / geo.size.width) * vis.duration)
                    },
                    onMagnify: { m, fraction in
                        guard let vis = state.visibleRange(screen) else { return }
                        state.zoomTimeline(screen, by: 1 + Double(m), around: vis.start + Double(fraction) * vis.duration)
                    }))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        guard let vis = state.visibleRange(screen), geo.size.width > 0 else { return }
                        state.skim(to: vis.start + Double(min(max(p.x, 0), geo.size.width) / geo.size.width) * vis.duration)
                    case .ended:
                        state.skim(to: nil)
                    }
                }
        }
    }
}
