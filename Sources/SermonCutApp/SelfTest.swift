import AppKit
import SermonCutCore
import SwiftUI

/// 앱 자체 점검 모드 — 외부 UI 조작 없이 실제 화면 흐름을 끝까지 돌리고 각 화면을 PNG로 남긴다.
/// 사용: SermonCut.app/Contents/MacOS/SermonCut --selftest 출력폴더 --video 영상 --manuscript 원고 [--seed 작업캐시폴더]
/// 키 입력은 실제 NSEvent를 창에 보내 onKeyPress 처리까지 검증한다.
@MainActor
enum SelfTest {
    struct Options {
        var output: URL
        var video: URL
        var manuscript: URL?
        var seed: URL?
        var inPoint: Double = 2162
        var outPoint: Double = 4950
        var ai = false
    }

    static func options() -> Options? {
        let a = CommandLine.arguments
        func value(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        guard let out = value("--selftest"), let video = value("--video") else { return nil }
        var o = Options(output: URL(fileURLWithPath: out), video: URL(fileURLWithPath: video))
        o.manuscript = value("--manuscript").map { URL(fileURLWithPath: $0) }
        o.seed = value("--seed").map { URL(fileURLWithPath: $0) }
        if let i = value("--in").flatMap(Timecode.parse) { o.inPoint = i }
        if let x = value("--out").flatMap(Timecode.parse) { o.outPoint = x }
        o.ai = a.contains("--ai")
        return o
    }

    static func run(_ o: Options, state: AppState) async {
        var log: [String] = []
        var failures = 0
        func note(_ s: String) { log.append(s); print(s) }
        func check(_ ok: Bool, _ what: String) {
            note((ok ? "✅ " : "❌ ") + what)
            if !ok { failures += 1 }
        }
        func wait(_ what: String, timeout: Double, _ cond: () -> Bool) async -> Bool {
            let start = Date()
            while !cond() {
                if Date().timeIntervalSince(start) > timeout { note("⏱ 시간 초과: \(what)"); return false }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return true
        }
        try? FileManager.default.createDirectory(at: o.output, withIntermediateDirectories: true)
        let started = Date()

        // 1. 영상 열기 → 구간 선택 화면
        state.openVideo(o.video)
        check(await wait("영상 열기", timeout: 20) { state.screen == .rangeSelect }, "영상 열기 → 구간 선택 화면")
        check(await wait("파형", timeout: 60) { state.waveform != nil }, "파형 생성 (\(state.waveform?.peaks.count ?? 0)개 버킷)")

        // 2. 키보드로 In/Out 지정 (I, O, → 이동 검증)
        await settle()
        state.seek(o.inPoint)
        await settle()
        sendKey("i")
        await settle()
        check(abs((state.inPoint ?? -1) - o.inPoint) < 0.1, "I 키로 In 지정 (\(state.inPoint.map { Timecode.format($0) } ?? "-"))")
        sendKey(nil, keyCode: 124) // →
        await settle()
        check(abs(state.currentTime - (o.inPoint + 1)) < 0.2, "→ 키 1초 이동")
        sendKey(nil, keyCode: 124, modifiers: .shift) // ⇧→
        await settle()
        check(abs(state.currentTime - (o.inPoint + 11)) < 0.2, "⇧→ 키 10초 이동")
        state.seek(o.outPoint)
        await settle()
        sendKey("o")
        await settle()
        check(abs((state.outPoint ?? -1) - o.outPoint) < 0.1, "O 키로 Out 지정 (\(state.outPoint.map { Timecode.format($0) } ?? "-"))")
        check(state.sourceRange.map { abs($0.start - (o.inPoint - 2)) < 0.01 && abs($0.end - (o.outPoint + 3)) < 0.01 } ?? false,
              "여유 마진 앞 2초·뒤 3초 적용 (\(state.sourceRange.map { "\(Timecode.format($0.start))~\(Timecode.format($0.end))" } ?? "-"))")
        state.seek(o.inPoint + 600)
        await settle(1.0)
        capture("1-range-select", o)

        // 3. 원고
        state.screen = .manuscript
        if let m = o.manuscript {
            state.loadManuscript(m)
            check(await wait("원고", timeout: 20) { state.manuscript != nil || state.manuscriptError != nil }, "원고 읽기")
            check(state.manuscript?.headings.count ?? 0 > 0, "원고 소제목 \(state.manuscript?.headings.count ?? 0)개, 문장 \(state.manuscript?.sentences.count ?? 0)개")
        }
        await settle(0.8)
        capture("2-manuscript", o)

        // 4. 분석 (캐시 시드가 있으면 전사 생략)
        if let seed = o.seed, let range = state.sourceRange {
            let key = String(format: "%.3f-%.3f", range.start, range.end)
            let work = AppState.cacheRoot.appendingPathComponent("work/" + WaveformGenerator.cacheKey(o.video))
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            for name in ["audio_\(key).wav", "transcript_\(key).json"] {
                let src = seed.appendingPathComponent(name), dst = work.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: src.path), !FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.copyItem(at: src, to: dst)
                    note("  캐시 시드: \(name)")
                }
            }
        }
        state.startAnalysis()
        check(await wait("분석 화면", timeout: 5) { state.screen == .analyzing }, "분석 화면 전환")
        await settle(0.5)
        capture("3-analyzing", o)
        check(await wait("분석 완료", timeout: 900) { state.screen == .editor }, "분석 완료 → 편집 화면")
        guard let project = state.project else {
            note("프로젝트 없음 — 중단")
            finish(log, failures, o, started)
            return
        }
        let removed0 = project.segments.filter(\.isRemoved).count
        note("  세그먼트 \(project.segments.count)개, 삭제 제안 \(removed0)개, 클립 \(state.edl?.clips.count ?? 0)개")
        check(state.edl != nil, "EDL 계산 (예상 길이 \(state.edl.map { Timecode.format(FrameSnapper(media: $0.media).seconds($0.totalFrames)) } ?? "-"))")
        await settle(1.0)
        capture("4-editor", o)

        // 5. 키보드 편집: 유지 세그먼트 하나 선택 → D → 삭제, ⌘Z → 복원, ⇧⌘Z → 다시 삭제
        guard let target = project.segments.first(where: { !$0.isRemoved && $0.start > project.sourceRange.start + 300 }) else {
            finish(log, failures, o, started); return
        }
        state.selection = [target.id]
        await settle()
        focusList()
        sendKey("d")
        await settle()
        check(state.project?.segments.first { $0.id == target.id }?.isRemoved == true, "D 키로 \(target.id) 삭제")
        check(state.project?.segments.first { $0.id == target.id }?.userOverridden == true, "사용자 결정 표시(userOverridden)")
        sendKey("z", modifiers: .command)
        await settle()
        let afterUndo = state.project?.segments.first { $0.id == target.id }
        check(afterUndo?.isRemoved == false && afterUndo?.userOverridden == false, "⌘Z 실행 취소")
        // ⇧⌘Z: 합성 이벤트의 Shift 조합은 NSMenu가 실제 키보드와 다르게 매칭해서, 메뉴 설정 + 동작을 따로 확인한다
        let redoItem = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.first { $0.title == "실행 복귀" }
        check(redoItem?.keyEquivalent == "z" && redoItem?.keyEquivalentModifierMask == [.command, .shift] && redoItem?.isEnabled == true,
              "실행 복귀 메뉴 단축키 ⇧⌘Z 설정")
        state.redo()
        await settle()
        check(state.project?.segments.first { $0.id == target.id }?.isRemoved == true, "실행 복귀 동작")
        // 다중 선택 + ⌘⌫
        let multi = (state.project?.segments ?? []).filter { !$0.isRemoved }.prefix(3).map(\.id)
        state.selection = Set(multi)
        await settle()
        focusList()
        sendKey(nil, keyCode: 51, modifiers: .command) // ⌘⌫
        await settle()
        check(multi.allSatisfy { id in state.project?.segments.first { $0.id == id }?.isRemoved == true }, "다중 선택 ⌘⌫ 일괄 삭제 (\(multi.count)개)")
        state.undo()
        await settle()
        check(multi.allSatisfy { id in state.project?.segments.first { $0.id == id }?.isRemoved == false }, "일괄 삭제 실행 취소")
        // 필터
        state.filter = .removed
        await settle()
        check(state.visibleSegments.allSatisfy(\.isRemoved) && !state.visibleSegments.isEmpty, "삭제만 보기 필터 (\(state.visibleSegments.count)개)")
        await settle(0.6)
        capture("5-editor-removed-filter", o)
        state.filter = .all
        // 설정 변경 → EDL 재계산
        let clipsBefore = state.edl?.clips.count
        state.updateSettings { $0.transitionDuration = 0 }
        await settle()
        check(state.edl?.transitions.allSatisfy { $0.durationFrames == 0 } == true, "디졸브 0초 → 모두 하드컷으로 재계산")
        state.updateSettings { $0.transitionDuration = 1 }
        check(state.edl?.clips.count == clipsBefore, "설정 되돌림")

        // 5b. AI 판정 (실제 API, --ai 일 때만)
        if o.ai {
            // 자동 점검에서는 Keychain 접근 확인 창이 뜨지 않도록 SERMONCUT_API_KEY(SPEC §3.1 개발용 대체)를 쓴다
            check(state.aiConfig.resolveAPIKey() != nil, "\(state.aiConfig.kind.displayName) API 키 확인")
            state.requestAIJudgement()
            check(state.pendingAIEstimate != nil, "AI 예상 비용 확인 창 (\(state.pendingAIEstimate?.calls ?? 0)곳, 약 \(state.pendingAIEstimate?.totalTokens ?? 0) 토큰)")
            await settle(0.8)
            capture("7-ai-confirm", o)
            state.runAIJudgement()
            check(await wait("AI 판정", timeout: 600) { !state.aiRunning && state.aiMessage != nil }, "AI 판정 완료")
            note("  " + (state.aiMessage ?? "").replacingOccurrences(of: "\n", with: " / "))
            let judged = (state.project?.candidates ?? []).filter { $0.ai?.status == .judged }.count
            check(judged == state.project?.candidates?.count, "모든 후보 판정 (\(judged)곳)")
            check(state.canUndo, "AI 판정도 실행 취소 가능")
            state.aiMessage = nil
            await settle(0.8)
            capture("8-editor-after-ai", o)
        }

        // 6. 저장 → 다시 열기 → 내보내기
        let projURL = o.output.appendingPathComponent("selftest.sermoncut")
        check(state.save(to: projURL), "프로젝트 저장 (.sermoncut)")
        let savedSegments = state.project?.segments
        state.openProject(projURL)
        await settle(0.5)
        check(state.screen == .editor && state.project?.segments == savedSegments, "프로젝트 다시 열기 — 편집 상태 동일")
        let xmlURL = o.output.appendingPathComponent("selftest.fcpxml")
        state.exportFCPXML(to: xmlURL)
        let xml = (try? String(contentsOf: xmlURL, encoding: .utf8)) ?? ""
        check(xml.contains("<fcpxml version=\"1.14\">") && xml.contains("<asset-clip"), "FCPXML 내보내기 (\(xml.count)자, 클립 \(xml.components(separatedBy: "<asset-clip").count - 1)개)")
        await settle(1.0)
        capture("6-editor-reopened", o)

        finish(log, failures, o, started)
    }

    private static func finish(_ log: [String], _ failures: Int, _ o: Options, _ started: Date) {
        var log = log
        log.append(String(format: "\n결과: 실패 %d건, 소요 %.0f초", failures, Date().timeIntervalSince(started)))
        try? log.joined(separator: "\n").write(to: o.output.appendingPathComponent("selftest.log"), atomically: true, encoding: .utf8)
        print(log.last ?? "")
        NSApp.terminate(nil)
        exit(failures == 0 ? 0 : 1)
    }

    private static func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil } }

    /// 창에 실제 키 이벤트를 보낸다 (현재 포커스된 뷰의 onKeyPress/메뉴 단축키까지 거침)
    private static func sendKey(_ chars: String?, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let codes: [String: UInt16] = ["i": 34, "o": 31, "d": 2, "z": 6, "j": 38, "k": 40, "l": 37]
        let code = chars.flatMap { codes[$0] } ?? keyCode
        // 실제 키보드처럼 Shift가 눌리면 글자는 대문자로 온다
        var text = modifiers.contains(.shift) ? (chars ?? "").uppercased() : (chars ?? "")
        if chars == nil {
            switch keyCode {
            case 124: text = String(UnicodeScalar(NSRightArrowFunctionKey).map(Character.init) ?? " ")
            case 123: text = String(UnicodeScalar(NSLeftArrowFunctionKey).map(Character.init) ?? " ")
            case 51: text = "\u{8}"
            default: break
            }
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: text,
                                           charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { continue }
            // 앱 이벤트 경로로 보낸다 (⌘ 단축키는 메뉴 key equivalent → 없으면 키 창의 first responder)
            NSApp.sendEvent(e)
        }
    }

    /// 목록(NSTableView)에 키보드 포커스
    private static func focusList() {
        guard let window, let content = window.contentView else { return }
        func find(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        if let table = find(content) { window.makeFirstResponder(table) }
    }

    /// 자기 창을 PNG로 저장
    private static func capture(_ name: String, _ o: Options) {
        guard let window, let view = window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // 창 배경을 깔고 합성 (투명 배경이면 다크 모드 흰 글자가 안 보임)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        rep.draw(in: view.bounds)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
           let data = out.representation(using: .png, properties: [:]) {
            try? data.write(to: o.output.appendingPathComponent("\(name).png"))
        }
    }
}
