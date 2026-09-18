import SermonCutCore
import SwiftUI

/// 설정 (⌘,) — AI 제공자, 모델, API 키(Keychain), 연결 테스트 (SPEC §3.1, §3.2)
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var keyInput = ""
    @State private var storedKey: String?
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var state = state
        Form {
            Section("AI 판정") {
                Picker("제공자", selection: Binding(get: { state.aiConfig.kind }, set: { kind in
                    state.aiConfig = AIConfig(kind: kind)
                    reloadKey()
                })) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if state.aiConfig.kind == .openAICompatible {
                    TextField("Base URL", text: $state.aiConfig.baseURL)
                }
                TextField("모델", text: $state.aiConfig.model, prompt: Text(state.aiConfig.kind.defaultModel))
                HStack {
                    SecureField("API 키", text: $keyInput, prompt: Text(storedKey.map(KeychainStore.masked) ?? "키 입력"))
                    Button("저장") {
                        let k = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty else { return }
                        KeychainStore.save(k, account: state.aiConfig.kind.keychainAccount)
                        keyInput = ""
                        reloadKey()
                    }
                    .disabled(keyInput.isEmpty)
                    Button("삭제") {
                        KeychainStore.delete(account: state.aiConfig.kind.keychainAccount)
                        reloadKey()
                    }
                    .disabled(storedKey == nil)
                }
                Text(storedKey == nil ? "저장된 키가 없습니다." : "Keychain에 저장됨 (\(KeychainStore.masked(storedKey ?? "")))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("연결 테스트") { test() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            Section {
                Text("API 키는 macOS Keychain에만 저장되며 프로젝트 파일·로그에 남지 않습니다. 개발용으로 환경변수 SERMONCUT_API_KEY가 있으면 그것을 먼저 씁니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear(perform: reloadKey)
        .onChange(of: state.aiConfig) { _, _ in state.saveAIConfig() }
    }

    private func reloadKey() {
        storedKey = KeychainStore.read(account: state.aiConfig.kind.keychainAccount)
        testResult = nil
    }

    private func test() {
        testing = true
        testResult = nil
        let config = state.aiConfig
        Task {
            let started = Date()
            do {
                let provider = try config.makeProvider()
                let r = try await provider.complete(system: "JSON만 출력하십시오.", user: "{\"ok\": true} 를 그대로 출력", maxTokens: 2000)
                testResult = String(format: "✅ 성공 %.1f초 — %@", Date().timeIntervalSince(started), r.text)
            } catch {
                testResult = "❌ " + error.localizedDescription
            }
            testing = false
        }
    }
}
