import SermonCutCore
import SwiftUI

/// 원고 선택 + 파싱 결과 미리보기 (선택사항)
struct ManuscriptPickerView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            MediaHeader()
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("설교 원고").font(.title2.bold())
                    Text("원고와 대조해 원고를 벗어난 구간(광고·근황·시사 이야기 등)을 삭제 후보로 표시합니다. 원고 없이도 진행할 수 있습니다.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("원고 파일 선택…") { FilePanels.chooseManuscript(state) }
                        if state.manuscriptURL != nil {
                            Button("원고 빼기") { state.clearManuscript() }
                        }
                    }
                    if let url = state.manuscriptURL {
                        Label(url.lastPathComponent, systemImage: "doc.text")
                    }
                    if let err = state.manuscriptError {
                        Text(err).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    if let range = state.sourceRange {
                        GroupBox("분석 구간 (여유 포함)") {
                            Text("\(Timecode.format(range.start, millis: false)) ~ \(Timecode.format(range.end, millis: false))  (\(Timecode.format(range.duration, millis: false)))")
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Spacer()
                    HStack {
                        Button("← 구간 선택") { state.screen = .rangeSelect }
                        Spacer()
                        Button(state.manuscript == nil ? "원고 없이 분석 시작" : "분석 시작") { state.startAnalysis() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(state.manuscriptURL != nil && state.manuscript == nil && state.manuscriptError == nil)
                    }
                }
                .frame(width: 360)
                Divider()
                preview
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let m = state.manuscript {
            VStack(alignment: .leading, spacing: 8) {
                Text("미리보기").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("제목").foregroundStyle(.secondary); Text(m.title ?? "-") }
                    GridRow { Text("본문").foregroundStyle(.secondary); Text(m.passage ?? "-") }
                    GridRow { Text("소제목").foregroundStyle(.secondary); Text(m.headings.isEmpty ? "없음" : m.headings.map { "\($0.number). \($0.title)" }.joined(separator: "\n")) }
                    GridRow { Text("문장").foregroundStyle(.secondary); Text("\(m.sentences.count)개") }
                }
                List(m.sentences) { s in
                    HStack(alignment: .top) {
                        Text(s.id).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Text(s.text).foregroundStyle(s.isScripture ? Color.blue : Color.primary)
                    }
                }
            }
        } else {
            VStack {
                Spacer()
                Text(state.manuscriptURL == nil ? "원고를 선택하면 여기에 파싱 결과가 보입니다." : "원고를 읽는 중…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// 단계별 진행률 + 취소
struct AnalyzeProgressView: View {
    @Environment(AppState.self) private var state
    private let stages: [SermonAnalyzer.Stage] = [.probe, .extractAudio, .transcribe, .silence, .manuscript, .align]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("분석 중").font(.title.bold())
            Text("46분 설교 기준 약 5분 걸립니다 (대부분 음성 전사). 결과는 캐시되어 다시 열면 바로 불러옵니다.")
                .foregroundStyle(.secondary)
            ForEach(stages.filter { $0 != .manuscript || state.manuscript != nil }, id: \.rawValue) { s in
                HStack(spacing: 10) {
                    Group {
                        if state.completedStages.contains(s) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if state.stage == s {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 20)
                    Text(s.rawValue).frame(width: 120, alignment: .leading)
                    if state.stage == s, [.extractAudio, .transcribe].contains(s) {
                        ProgressView(value: state.stageProgress).frame(width: 240)
                        Text("\(Int(state.stageProgress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("취소") { state.cancelAnalysis() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(40)
        .frame(maxWidth: 600, maxHeight: .infinity)
    }
}
