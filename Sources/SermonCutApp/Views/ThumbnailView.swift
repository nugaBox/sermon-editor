import AppKit
import SermonCutCore
import SwiftUI
import UniformTypeIdentifiers

/// 썸네일 + 인트로/아웃트로 템플릿 (SPEC §6.7, Phase 6)
struct ThumbnailView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var saved: String?

    private let labels = ["주일낮예배 설교", "주일오후예배 설교", "수요예배 설교", "부활절 감사예배 설교", "종려주일 예배 설교",
                          "어린이주일 예배 설교", "어버이주일 예배 설교", "추수감사주일 예배 설교", "성탄절 예배 설교", "송구영신예배 설교"]

    var body: some View {
        @Bindable var state = state
        let content = state.thumbnailContent
        let lines = (try? ThumbnailRenderer.titleLines(content, template: state.templatePack.thumbnailTemplate)) ?? [content.title]
        VStack(alignment: .leading, spacing: 12) {
            Text("썸네일 · 인트로/아웃트로").font(.title2.bold())
            HStack(alignment: .top, spacing: 16) {
                Form {
                    TextField("제목", text: Binding(get: { content.title }, set: { v in state.updateThumbnail { $0.title = v; $0.titleLines = nil } }))
                    HStack {
                        Text("줄바꿈")
                        Picker("", selection: Binding(get: { lines.count > 1 ? 2 : 1 }, set: { n in
                            state.updateThumbnail { t in
                                if n == 1 { t.titleLines = [t.title] } else { t.titleLines = nil }
                            }
                        })) {
                            Text("1줄").tag(1)
                            Text("2줄").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                        Text(lines.joined(separator: " ⏎ ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if lines.count > 1 {
                        TextField("둘째 줄 시작 단어", text: Binding(get: { lines.last ?? "" }, set: { second in
                            state.updateThumbnail { t in
                                let first = t.title.hasSuffix(second) ? String(t.title.dropLast(second.count)).trimmingCharacters(in: .whitespaces) : lines.first ?? t.title
                                t.titleLines = [first, second]
                            }
                        }))
                    }
                    TextField("본문", text: Binding(get: { content.passage }, set: { v in state.updateThumbnail { $0.passage = v } }))
                    Picker("예배", selection: Binding(get: { content.label }, set: { v in state.updateThumbnail { $0.label = v } })) {
                        ForEach(Array(Set(labels + [content.label])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    TextField("예배 (직접 입력)", text: Binding(get: { content.label }, set: { v in state.updateThumbnail { $0.label = v } }))
                    Toggle("FCPXML·최종 MP4에 인트로/아웃트로 넣기", isOn: $state.useTemplate)
                }
                .formStyle(.grouped)
                .frame(width: 380)

                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        if let img = state.thumbnailPreview {
                            Image(nsImage: img).resizable().aspectRatio(16 / 9, contentMode: .fit)
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.15)).aspectRatio(16 / 9, contentMode: .fit)
                                .overlay(Text(state.thumbnailError ?? "미리보기 없음").font(.caption).foregroundStyle(.secondary).padding())
                        }
                    }
                    .frame(width: 480)
                    HStack {
                        Button("썸네일 저장…") { saveThumbnail() }
                        if let saved { Text(saved).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    templateBox
                }
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 560)
        .onAppear { state.renderThumbnailPreview() }
    }

    private var templateBox: some View {
        let pack = state.templatePack
        _ = state.templateRevision
        return GroupBox("템플릿 재료 (매주 같은 파일)") {
            VStack(alignment: .leading, spacing: 6) {
                row("썸네일 배경", pack.background, types: [.png, .jpeg])
                row("인트로 음악", pack.introAudio, types: [.mp3, .audio])
                row("아웃트로 음악", pack.outroAudio, types: [.mp3, .audio])
                row("끝 화면 (매년)", pack.endPoster, types: [.jpeg, .png])
                HStack {
                    Button("Photoshop으로 배경 다시 뽑기…") { extractBackground() }
                        .help("PSD의 글자 레이어만 숨긴 합성본을 배경으로 설치합니다. Photoshop 로그인 창이 뜨면 직접 처리해 주세요.")
                    Button("폴더 열기") { NSWorkspace.shared.open(pack.folder) }
                }
                if !pack.missing.isEmpty {
                    Text("없음: " + pack.missing.joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480)
    }

    private func row(_ label: String, _ url: URL, types: [UTType]) -> some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        return HStack {
            Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(exists ? .green : .orange)
            Text(label).frame(width: 110, alignment: .leading)
            Text(exists ? url.lastPathComponent : "없음").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("바꾸기…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = types
                if panel.runModal() == .OK, let src = panel.url { state.installTemplateFile(src, as: url) }
            }
        }
    }

    private func saveThumbnail() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        let base = state.videoURL?.deletingPathExtension().lastPathComponent ?? "설교"
        panel.nameFieldStringValue = base + "-Title.jpg"
        panel.directoryURL = state.videoURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { saved = try state.writeThumbnail(to: url).lastPathComponent } catch { state.errorMessage = error.localizedDescription }
    }

    private func extractBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "psd") ?? .image]
        panel.message = "썸네일 PSD 선택 (원본은 수정하지 않습니다)"
        guard panel.runModal() == .OK, let psd = panel.url else { return }
        let pack = state.templatePack
        Task {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sermoncut-bg-\(UUID().uuidString).png")
            do {
                try await PhotoshopBridge.exportBackground(psd: psd, to: tmp)
                state.installTemplateFile(tmp, as: pack.background)
                try? FileManager.default.removeItem(at: tmp)
            } catch {
                state.errorMessage = "Photoshop으로 배경을 뽑지 못했습니다: \(error.localizedDescription)"
            }
        }
    }
}
