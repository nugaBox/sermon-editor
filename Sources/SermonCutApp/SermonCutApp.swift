import AppKit
import SermonCutCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct SermonCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("SermonCut", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear {
                    delegate.state = state
                    if let o = SelfTest.options() {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            await SelfTest.run(o, state: state)
                        }
                    }
                }
        }
        // 메뉴 항목의 disabled 상태는 @Observable 변경을 즉시 따라가지 않아 단축키가 막히는 문제가 있어(셀프테스트로 발견),
        // 조건은 각 동작 안에서 검사한다.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("영상 열기…") { FilePanels.openVideo(state) }
                    .keyboardShortcut("o")
                Button("프로젝트 열기…") { FilePanels.openProject(state) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("저장") { FilePanels.save(state) }
                    .keyboardShortcut("s")
                Button("다른 이름으로 저장…") { FilePanels.save(state, forceNew: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("FCPXML 내보내기…") { if state.edl != nil { FilePanels.exportFCPXML(state) } }
                    .keyboardShortcut("e")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("실행 취소") { state.undo() }
                    .keyboardShortcut("z")
                Button("실행 복귀") { state.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("편집점") {
                Button("선택 항목 삭제") { if state.screen == .editor { state.remove(state.selection) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("삭제/복원 전환") { if state.screen == .editor { state.toggleRemoved(state.selection) } }
                Divider()
                Button("AI 판정…") { if state.screen == .editor { state.requestAIJudgement() } }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environment(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM 실행 파일로 띄워도 일반 앱처럼 Dock·메뉴·키보드 포커스를 갖도록
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in
            guard let state = self.state else { return }
            if url.pathExtension == "sermoncut" { state.openProject(url) } else { state.openVideo(url) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state, state.isDirty, state.project != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "저장하지 않은 변경 사항이 있습니다."
        alert.informativeText = "종료하기 전에 프로젝트를 저장할까요?"
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "저장 안 함")
        alert.addButton(withTitle: "취소")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return FilePanels.save(state) ? .terminateNow : .terminateCancel
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}

extension UTType {
    static let sermonCutProject = UTType(exportedAs: "com.nugabox.sermoncut.project", conformingTo: .json)
}

/// 파일 대화상자 (AppKit)
@MainActor
enum FilePanels {
    static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]
    static let manuscriptTypes: [UTType] = ["hwpx", "hwp", "docx", "txt", "md"].compactMap { UTType(filenameExtension: $0) } + [.plainText]

    static func openVideo(_ state: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = videoTypes
        panel.message = "예배 전체가 녹화된 영상 파일을 선택하세요"
        if panel.runModal() == .OK, let url = panel.url { state.openVideo(url) }
    }

    static func openProject(_ state: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sermoncut") ?? .json]
        if panel.runModal() == .OK, let url = panel.url { state.openProject(url) }
    }

    static func chooseManuscript(_ state: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = manuscriptTypes
        panel.message = "설교 원고 (hwpx, docx, txt, md)"
        if panel.runModal() == .OK, let url = panel.url { state.loadManuscript(url) }
    }

    @discardableResult
    static func save(_ state: AppState, forceNew: Bool = false) -> Bool {
        guard state.project != nil else { return false }
        if !forceNew, state.projectURL != nil { return state.save() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sermoncut") ?? .json]
        panel.nameFieldStringValue = (state.videoURL?.deletingPathExtension().lastPathComponent ?? "설교") + ".sermoncut"
        panel.directoryURL = state.videoURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return state.save(to: url)
    }

    static func exportFCPXML(_ state: AppState) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fcpxml") ?? .xml]
        panel.nameFieldStringValue = (state.videoURL?.deletingPathExtension().lastPathComponent ?? "설교") + " (SermonCut).fcpxml"
        panel.directoryURL = state.videoURL?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { state.exportFCPXML(to: url) }
    }
}
