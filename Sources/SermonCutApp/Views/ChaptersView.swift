import AppKit
import SermonCutCore
import SwiftUI

/// 설교 목차(유튜브 챕터) 창 (SPEC §6.6)
struct ChaptersView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        @Bindable var state = state
        let chapters = state.chapters
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("설교 목차").font(.title2.bold())
                Spacer()
                if state.overlayScanRunning {
                    ProgressView(value: state.overlayScanProgress) { Text("화면 목차 읽는 중").font(.caption) }.frame(width: 160)
                } else {
                    Button("화면 목차 다시 읽기") { state.scanOverlay(force: true) }
                        .help("녹화 화면 오른쪽 아래 목차 박스에서 강조가 바뀌는 시점을 찾습니다")
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("목차 붙여넣기 (선택)").font(.headline)
                    Text("비워 두면 원고 소제목 → 화면 목차 순서로 제목을 씁니다. 번호·시간은 붙어 있어도 됩니다.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: Binding(get: { state.project?.chapterOutlineText ?? "" },
                                             set: { state.setChapterOutline($0) }))
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .border(Color.secondary.opacity(0.3))
                    Grid(alignment: .leading, verticalSpacing: 6) {
                        GridRow {
                            Text("첫 줄")
                            TextField("", text: Binding(get: { state.chapterOptions.firstLine ?? "" },
                                                        set: { state.chapterOptions.firstLine = $0.isEmpty ? nil : $0 }))
                        }
                        GridRow {
                            Text("인트로 길이")
                            HStack {
                                TextField("", value: $state.chapterOptions.introDuration, format: .number.precision(.fractionLength(3)))
                                    .frame(width: 80)
                                Text("초 (썸네일 화면)")
                            }
                        }
                    }
                }
                .frame(width: 300)

                VStack(alignment: .leading, spacing: 6) {
                    Text("대지 시작 (결과 영상 기준)").font(.headline)
                    if chapters.isEmpty {
                        Text("원고 소제목, 화면 목차, 붙여넣은 목차가 없습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(chapters) { c in
                        HStack(spacing: 8) {
                            Text(c.outputTime.map(ChapterBuilder.displayClock) ?? "--:--")
                                .font(.body.monospacedDigit()).frame(width: 64, alignment: .leading)
                            Text("\(c.number). \(c.title)").lineLimit(1)
                            Spacer()
                            Text(c.timeSource.rawValue).font(.caption).foregroundStyle(.secondary)
                            Button { state.nudgeChapter(c, by: -1) } label: { Image(systemName: "minus") }.buttonStyle(.borderless)
                            Button { state.nudgeChapter(c, by: 1) } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                            Button { if let t = c.sourceTime { state.play(from: t, until: t + 8) } } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless).help("이 대지 시작 8초 듣기")
                            Button { state.setChapterHere(c) } label: { Image(systemName: "scope") }
                                .buttonStyle(.borderless).help("현재 재생 위치를 이 대지 시작으로")
                        }
                        if let w = c.warning { Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }
                    Divider()
                    Text("유튜브 설명란").font(.headline)
                    let text = ChapterBuilder.youtubeText(chapters, options: state.chapterOptions)
                    Text(text).font(.body.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(Color.secondary.opacity(0.08))
                    HStack {
                        Button(copied ? "복사됨 ✓" : "복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            copied = true
                        }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        if state.project?.chapterTimeOverrides?.isEmpty == false {
                            Button("직접 고친 시간 되돌리기") { state.resetChapterOverrides() }
                        }
                        Spacer()
                        Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
                .frame(minWidth: 420)
            }
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 460)
    }
}

extension ChapterBuilder {
    static func displayClock(_ t: Double) -> String { clock(t) }
}
