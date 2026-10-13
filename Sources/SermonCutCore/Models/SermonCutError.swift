import Foundation

/// 앱 전체에서 쓰는 에러. 사용자에게는 `errorDescription`(한국어)을 그대로 보여준다.
public enum SermonCutError: LocalizedError, Equatable {
    case binaryNotFound(tool: String)
    case processFailed(tool: String, exitCode: Int32, stderrTail: String)
    case cancelled
    case mediaProbeFailed(reason: String)
    case noVideoStream
    case invalidRange(start: Double, end: Double)
    case transcriptParseFailed(reason: String)
    case manuscriptUnreadable(fileName: String, reason: String)
    case unsupportedManuscript(fileExtension: String)
    case hwpBinaryNotSupported
    case emptyEditDecisionList
    case fileWriteFailed(path: String, reason: String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let tool):
            return "\(tool) 실행 파일을 찾을 수 없습니다. 설정에서 경로를 지정하거나 Homebrew로 설치해 주세요."
        case .processFailed(let tool, let code, let tail):
            return "\(tool) 실행이 실패했습니다 (종료 코드 \(code)).\n\(tail)"
        case .cancelled:
            return "작업이 취소되었습니다."
        case .mediaProbeFailed(let reason):
            return "영상 정보를 읽지 못했습니다: \(reason)"
        case .noVideoStream:
            return "영상 트랙이 없는 파일입니다."
        case .invalidRange(let s, let e):
            return "설교 구간이 올바르지 않습니다 (시작 \(Timecode.format(s)), 끝 \(Timecode.format(e)))."
        case .transcriptParseFailed(let reason):
            return "전사 결과를 해석하지 못했습니다: \(reason)"
        case .manuscriptUnreadable(let name, let reason):
            return "\(name) 파일을 읽지 못했습니다(\(reason)). 한글에서 '다른 이름으로 저장 → 서식 없는 텍스트(.txt)'로 저장한 뒤 다시 시도하거나, 원고 없이 진행할 수 있습니다."
        case .unsupportedManuscript(let ext):
            return ".\(ext) 형식의 원고는 지원하지 않습니다. hwpx, docx, txt, md 파일을 선택해 주세요."
        case .hwpBinaryNotSupported:
            return ".hwp 파일은 읽을 수 없습니다. 한글에서 '다른 이름으로 저장 → HWPX'로 저장한 뒤 다시 선택해 주세요."
        case .emptyEditDecisionList:
            return "남길 구간이 하나도 없습니다. 삭제 표시를 확인해 주세요."
        case .fileWriteFailed(let path, let reason):
            return "파일을 저장하지 못했습니다: \(path) (\(reason))"
        case .invalidArgument(let message):
            return message
        }
    }
}
