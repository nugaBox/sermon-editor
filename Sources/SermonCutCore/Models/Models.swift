import Foundation

// ★ 규약: 이 파일의 모든 시간값(초)은 "원본 영상 파일의 0초" 기준이다. (SPEC §4)

public struct TimeRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public func contains(_ t: Double) -> Bool { t >= start && t <= end }
}

public struct MediaInfo: Codable, Equatable, Sendable {
    public var durationSeconds: Double
    /// 프레임레이트 분자/분모 (예: 30/1, 30000/1001)
    public var frameRateNum: Int
    public var frameRateDen: Int
    public var width: Int
    public var height: Int
    public var hasAudio: Bool
    public var audioSampleRate: Int?
    public var audioChannels: Int?

    public init(durationSeconds: Double, frameRateNum: Int, frameRateDen: Int, width: Int, height: Int,
                hasAudio: Bool, audioSampleRate: Int? = nil, audioChannels: Int? = nil) {
        self.durationSeconds = durationSeconds
        self.frameRateNum = frameRateNum
        self.frameRateDen = frameRateDen
        self.width = width
        self.height = height
        self.hasAudio = hasAudio
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
    }

    public var fps: Double { Double(frameRateNum) / Double(frameRateDen) }

    /// FCPXML 시간 표기용 (docs/fcpxml-reference.md §1).
    /// 30/1 → 1프레임 = 100/3000s, 30000/1001 → 1001/30000s
    public var frameDurationValue: Int { frameRateDen == 1 ? 100 : frameRateDen }
    public var timescale: Int { frameRateDen == 1 ? frameRateNum * 100 : frameRateNum }
}

public struct WordTiming: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var probability: Double?
}

public enum AlignStatus: String, Codable, Sendable {
    case matched, unmatched, failed, notAligned
}

public enum UnmatchedReason: String, Codable, Sendable {
    case greeting, repetition, filler, improvised, misrecognized, unknown
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [WordTiming]?
    // 정렬 결과
    public var matchedManuscriptID: String?
    public var alignStatus: AlignStatus
    public var unmatchedReason: UnmatchedReason?
    public var confidence: Double?
    // 사용자 결정 (최종 권한)
    public var isRemoved: Bool
    public var userOverridden: Bool
    /// 확인 필요 표시 (노란 테두리). 삭제·유지 모두에 붙을 수 있다
    public var needsReview: Bool?
    /// AI 판정 사유 등 한 줄 메모
    public var aiNote: String?

    public init(id: String, start: Double, end: Double, text: String, words: [WordTiming]? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.matchedManuscriptID = nil
        self.alignStatus = .notAligned
        self.unmatchedReason = nil
        self.confidence = nil
        self.isRemoved = false
        self.userOverridden = false
    }

    public var duration: Double { end - start }
}

public struct ManuscriptSentence: Codable, Identifiable, Equatable, Sendable {
    public var id: String          // "M1"
    public var text: String
    public var order: Int
    /// 속한 소제목(대지) 번호. 0 = 첫 소제목 이전(서론)
    public var sectionIndex: Int
    /// 성경 인용 단독 문단에서 나온 문장
    public var isScripture: Bool
}

public struct ManuscriptHeading: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    /// 이 소제목 바로 다음 문장 ID (없으면 nil)
    public var firstSentenceID: String?
}

public struct Manuscript: Codable, Equatable, Sendable {
    public var title: String?
    public var passage: String?
    public var headings: [ManuscriptHeading]
    public var sentences: [ManuscriptSentence]
}

public struct ExportSettings: Codable, Equatable, Sendable {
    public var transitionDuration: Double = 1.0
    public var padHead: Double = 0.25
    public var padTail: Double = 0.25
    public var snapToSilence: Bool = true
    public var silenceThresholdDB: Double = -35
    public var minSilenceDuration: Double = 0.3
    public var fallbackToHardCut: Bool = true
    public var audioGainDB: Double = 12
    /// 이 간격보다 가까운 유지 구간은 하나로 합친다 (SPEC §6.1-2)
    public var mergeGap: Double = 0.5
    /// 무음 스냅 탐색 범위 (SPEC §6.1-4)
    public var snapWindow: Double = 1.0

    public init() {}
}

/// Phase 6 대비 자리만 잡아둔다 (값은 nil 허용).
public struct TemplateClip: Codable, Equatable, Sendable {
    public var url: URL
    public var duration: Double?
}

public struct SermonProject: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var id: UUID
    public var videoPath: String
    public var manuscriptPath: String?
    public var media: MediaInfo
    public var sourceRange: TimeRange
    public var segments: [TranscriptSegment]
    public var manuscript: Manuscript?
    public var silences: [TimeRange]
    public var settings: ExportSettings
    /// 탈선 후보 구간 (로컬 제안 + AI 판정)
    public var candidates: [DigressionCandidate]?
    /// 목차: 사용자가 붙여넣은 목차, 화면 목차 전환, 사용자가 고친 대지 시작(원본 초)
    public var chapterOutlineText: String?
    public var overlayChanges: [ChapterBuilder.OverlayChange]?
    public var screenOutline: [String]?
    public var chapterTimeOverrides: [Int: Double]?
    /// 썸네일 글자 (Phase 6)
    public var thumbnail: ThumbnailContent?
    public var headClip: TemplateClip?
    public var tailClip: TemplateClip?
    public var bgmTrack: TemplateClip?
    public var createdAt: Date
    public var updatedAt: Date

    public init(videoPath: String, manuscriptPath: String?, media: MediaInfo, sourceRange: TimeRange,
                segments: [TranscriptSegment], manuscript: Manuscript?, silences: [TimeRange],
                settings: ExportSettings = ExportSettings()) {
        self.id = UUID()
        self.videoPath = videoPath
        self.manuscriptPath = manuscriptPath
        self.media = media
        self.sourceRange = sourceRange
        self.segments = segments
        self.manuscript = manuscript
        self.silences = silences
        self.settings = settings
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

/// 원고 매칭이 없는 연속 구간 = 탈선(광고·근황·시사…) 후보
public struct DigressionCandidate: Codable, Equatable, Sendable, Identifiable {
    public var id: String                  // "C1"
    public var segmentIDs: [String]
    public var range: TimeRange
    public var localOverlap: Double
    public var globalOverlap: Double
    /// 로컬 규칙의 판단 (true = 삭제 제안)
    public var localRemoved: Bool
    public var ai: AIJudgement?
}

public struct AIJudgement: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case judged, failed }
    public var status: Status
    public var digression: Bool
    public var startID: String?
    public var endID: String?
    public var category: String?
    public var confidence: Double?
    public var reason: String?
    public var error: String?
    public var model: String?
}
