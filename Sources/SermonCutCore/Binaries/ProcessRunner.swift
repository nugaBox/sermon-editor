import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// 외부 프로세스 실행은 전부 여기를 거친다 (CLAUDE.md 코드 규칙).
/// - 줄 단위 콜백으로 진행률 파싱 가능
/// - Task 취소 시 프로세스를 종료하고 `SermonCutError.cancelled`를 던진다
public enum ProcessRunner {
    public typealias LineHandler = @Sendable (String) -> Void

    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        toolName: String? = nil,
        currentDirectory: URL? = nil,
        allowNonZeroExit: Bool = false,
        onStdoutLine: LineHandler? = nil,
        onStderrLine: LineHandler? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let dir = currentDirectory { process.currentDirectoryURL = dir }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outCollector = StreamCollector(handler: onStdoutLine)
        let errCollector = StreamCollector(handler: onStderrLine)
        outPipe.fileHandleForReading.readabilityHandler = { h in outCollector.append(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in errCollector.append(h.availableData) }

        let name = toolName ?? executable.lastPathComponent
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: SermonCutError.processFailed(tool: name, exitCode: -1,
                                                                        stderrTail: error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        // 남은 데이터 비우기
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outCollector.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errCollector.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        outCollector.flush()
        errCollector.flush()

        if Task.isCancelled { throw SermonCutError.cancelled }
        let result = ProcessResult(exitCode: status, stdout: outCollector.data, stderr: errCollector.data)
        if status != 0 && !allowNonZeroExit {
            let tail = result.stderrString.split(separator: "\n").suffix(8).joined(separator: "\n")
            throw SermonCutError.processFailed(tool: name, exitCode: status, stderrTail: tail)
        }
        return result
    }
}

/// 파이프 데이터를 모으고, 줄이 완성될 때마다 콜백을 부른다. (readabilityHandler는 별도 스레드에서 호출됨)
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pending = Data()
    private let handler: ProcessRunner.LineHandler?

    init(handler: ProcessRunner.LineHandler?) { self.handler = handler }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        buffer.append(chunk)
        if handler != nil {
            pending.append(chunk)
            // \n 또는 \r(ffmpeg 진행 표시) 기준으로 자른다
            while let idx = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = pending[pending.startIndex..<idx]
                lines.append(String(decoding: lineData, as: UTF8.self))
                pending.removeSubrange(pending.startIndex...idx)
            }
        }
        lock.unlock()
        if let handler { lines.filter { !$0.isEmpty }.forEach(handler) }
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if let handler, !rest.isEmpty { handler(String(decoding: rest, as: UTF8.self)) }
    }
}
