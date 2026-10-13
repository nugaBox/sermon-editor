import AppKit
import SermonCutCore
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeView: View {
    @Environment(AppState.self) private var state
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 24) {
            // 번들 아이콘(App/AppIcon.icns) — 아이콘 모양 둘레의 투명 여백까지 포함한 크기
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 160, height: 160)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .accessibilityHidden(true)
            Text("SermonCut").font(.system(size: 44, weight: .bold))
            Text("예배 영상에서 설교만 잘라 원고와 대조하고, Final Cut Pro용 편집본을 만듭니다.")
                .font(.title2)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    FilePanels.openVideo(state)
                } label: {
                    Label("영상 열기…", systemImage: "play.rectangle")
                        .font(.title3)
                        .frame(minWidth: 180)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                Button {
                    FilePanels.openProject(state)
                } label: {
                    Label("프로젝트 열기…", systemImage: "folder")
                        .font(.title3)
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
            }
            Text("영상 파일(.mp4 / .mov)이나 프로젝트(.sermoncut)를 여기에 끌어다 놓아도 됩니다.")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Text("© 2026 NUGABOX. All rights reserved.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.pathExtension == "sermoncut" { state.openProject(url) } else { state.openVideo(url) }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
