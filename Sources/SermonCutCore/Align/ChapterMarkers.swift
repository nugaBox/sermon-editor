import Foundation

public struct ChapterMarker: Codable, Equatable, Sendable {
    /// 원본 기준 초
    public var sourceSeconds: Double
    public var title: String
}

/// 목차(유튜브 챕터) — Phase 1 예비 구현: 원고 소제목 + 정렬 결과.
/// Phase 5b에서 붙여넣기 목차·화면 오버레이 OCR·AI와 결합한다 (SPEC §6.6).
public enum ChapterMarkers {
    public static func fromManuscript(_ p: SermonProject) -> [ChapterMarker] {
        guard let m = p.manuscript else { return [] }
        var result: [ChapterMarker] = []
        for h in m.headings {
            guard let first = h.firstSentenceID, let order = m.sentences.first(where: { $0.id == first })?.order else { continue }
            // 이 대지에 속한 문장 중 가장 먼저 매칭된(유지된) 세그먼트
            let ids = Set(m.sentences.filter { $0.order >= order && $0.sectionIndex == h.number }.map(\.id))
            if let seg = p.segments.first(where: { !$0.isRemoved && $0.matchedManuscriptID.map(ids.contains) == true }) {
                result.append(ChapterMarker(sourceSeconds: seg.start, title: "\(h.number). \(h.title)"))
            }
        }
        return result
    }
}
