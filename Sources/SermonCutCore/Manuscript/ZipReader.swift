import Foundation

/// hwpx/docx 컨테이너용 최소 ZIP 읽기. 새 의존성 없이 시스템 `/usr/bin/unzip`을 ProcessRunner로 쓴다.
public struct ZipReader: Sendable {
    public let archive: URL
    public var locator: BinaryLocator

    public init(archive: URL, locator: BinaryLocator = BinaryLocator()) {
        self.archive = archive
        self.locator = locator
    }

    public func entries() async throws -> [String] {
        let unzip = try locator.url(for: .unzip)
        let r = try await ProcessRunner.run(unzip, ["-Z1", archive.path], toolName: "unzip")
        return r.stdoutString.split(separator: "\n").map { String($0) }
    }

    public func read(_ entry: String) async throws -> Data {
        let unzip = try locator.url(for: .unzip)
        // -p: 표준출력으로, -C: 대소문자 무시 안 함 기본. 경로에 와일드카드 문자가 있으면 이스케이프
        let escaped = entry.replacingOccurrences(of: "[", with: "\\[")
        let r = try await ProcessRunner.run(unzip, ["-p", archive.path, escaped], toolName: "unzip")
        return r.stdout
    }
}
