import Foundation

public struct EDLClip: Codable, Equatable, Sendable {
    /// 원본 기준 프레임 [start, end)
    public var sourceStartFrame: Int
    public var sourceEndFrame: Int
    /// 결과 타임라인 위치 (FCPXML offset — 겹침 없이 이어붙임, docs/fcpxml-reference.md §3)
    public var timelineOffsetFrame: Int
    public var segmentIDs: [String]

    public var durationFrames: Int { sourceEndFrame - sourceStartFrame }
}

public struct EDLTransition: Codable, Equatable, Sendable {
    /// clips[afterClip] 와 clips[afterClip+1] 사이
    public var afterClip: Int
    /// 0이면 하드컷
    public var durationFrames: Int
    /// 핸들 부족으로 하드컷/축소 처리됨 → UI ⚠
    public var handleShortage: Bool
    /// 편집점 사이에 잘려나간 원본 길이(초)
    public var removedSeconds: Double
}

public struct EditDecisionList: Codable, Equatable, Sendable {
    public var media: MediaInfo
    public var clips: [EDLClip]
    public var transitions: [EDLTransition]

    public var totalFrames: Int { clips.reduce(0) { $0 + $1.durationFrames } }
    public var handleShortageCount: Int { transitions.filter(\.handleShortage).count }

    /// 원본 시간 → 결과 타임라인 시간(초). 삭제 구간이면 다음 유지 구간 시작으로 민다 (SPEC §6.6)
    public func timelineSeconds(forSource t: Double) -> Double? {
        let snap = FrameSnapper(media: media)
        let f = snap.frame(t)
        for clip in clips {
            if f < clip.sourceStartFrame { return snap.seconds(clip.timelineOffsetFrame) }
            if f < clip.sourceEndFrame { return snap.seconds(clip.timelineOffsetFrame + f - clip.sourceStartFrame) }
        }
        return nil
    }
}

/// 킵 구간 계산 — SPEC §6.1 순서를 그대로 따른다.
public enum EDLBuilder {
    public static func build(segments: [TranscriptSegment], silences: [TimeRange], sourceRange: TimeRange,
                             media: MediaInfo, settings: ExportSettings) throws -> EditDecisionList {
        // 1. 유지 세그먼트만 (시간 순). 삭제 세그먼트가 사이에 있는 곳에서만 끊는다 —
        //    세그먼트 사이의 자연스러운 쉼(VAD 공백)은 자르지 않는다.
        let ordered = segments.sorted { $0.start < $1.start }
        guard ordered.contains(where: { !$0.isRemoved }) else { throw SermonCutError.emptyEditDecisionList }

        // 2. 연속 유지 세그먼트 → keepRanges, 그다음 간격이 mergeGap 미만이면 병합
        //    (말소리 경계도 보관: 무음 스냅 방향 제한용)
        struct Range { var start: Double; var end: Double; var speechStart: Double; var speechEnd: Double; var ids: [String] }
        var ranges: [Range] = []
        var breakBefore = true
        for s in ordered {
            if s.isRemoved { breakBefore = true; continue }
            if !breakBefore, var last = ranges.last {
                last.end = max(last.end, s.end)
                last.speechEnd = max(last.speechEnd, s.end)
                last.ids.append(s.id)
                ranges[ranges.count - 1] = last
            } else if var last = ranges.last, s.start - last.end < settings.mergeGap {
                last.end = max(last.end, s.end)
                last.speechEnd = max(last.speechEnd, s.end)
                last.ids.append(s.id)
                ranges[ranges.count - 1] = last
            } else {
                ranges.append(Range(start: s.start, end: s.end, speechStart: s.start, speechEnd: s.end, ids: [s.id]))
            }
            breakBefore = false
        }

        // 3. 패딩
        for i in ranges.indices {
            ranges[i].start -= settings.padHead
            ranges[i].end += settings.padTail
        }

        // 4. 무음 스냅: 경계를 ±snapWindow 안의 가장 가까운 무음 중앙으로.
        //    말소리를 자르지 않도록 시작은 말소리 시작 이전, 끝은 말소리 끝 이후의 무음만 본다.
        if settings.snapToSilence && !silences.isEmpty {
            for i in ranges.indices {
                let r = ranges[i]
                if let c = nearestSilenceCenter(to: r.start, in: silences, window: settings.snapWindow, where: { $0 <= r.speechStart + 0.05 }) {
                    ranges[i].start = c
                }
                if let c = nearestSilenceCenter(to: r.end, in: silences, window: settings.snapWindow, where: { $0 >= r.speechEnd - 0.05 }) {
                    ranges[i].end = c
                }
            }
        }

        // 패딩·스냅으로 겹치게 된 구간 다시 병합
        var merged: [Range] = []
        for r in ranges {
            if var last = merged.last, r.start <= last.end {
                last.end = max(last.end, r.end)
                last.speechEnd = max(last.speechEnd, r.speechEnd)
                last.ids += r.ids
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }

        // 5. ★ sourceRange 밖으로 벗어나지 않게 클램프 (대표기도·봉헌기도가 딸려 들어오는 것 방지)
        merged = merged.compactMap { r in
            var r = r
            r.start = max(r.start, sourceRange.start, 0)
            r.end = min(r.end, sourceRange.end, media.durationSeconds)
            return r.end > r.start ? r : nil
        }
        guard !merged.isEmpty else { throw SermonCutError.emptyEditDecisionList }

        // 7. 프레임 양자화 (6은 양자화된 값으로 검증해야 정확하므로 순서를 붙여서 처리)
        let snap = FrameSnapper(media: media)
        let mediaFrames = Int((media.durationSeconds * media.fps).rounded(.down))
        var clips: [EDLClip] = []
        var offset = 0
        for r in merged {
            let s = snap.frame(r.start), e = min(snap.frame(r.end), mediaFrames)
            guard e > s else { continue }
            if let last = clips.last, s <= last.sourceEndFrame {
                // 양자화로 붙어버린 경우 합친다
                clips[clips.count - 1].sourceEndFrame = max(last.sourceEndFrame, e)
                clips[clips.count - 1].segmentIDs += r.ids
                offset = clips[clips.count - 1].timelineOffsetFrame + clips[clips.count - 1].durationFrames
                continue
            }
            clips.append(EDLClip(sourceStartFrame: s, sourceEndFrame: e, timelineOffsetFrame: offset, segmentIDs: r.ids))
            offset += e - s
        }
        guard !clips.isEmpty else { throw SermonCutError.emptyEditDecisionList }

        // 6. 디졸브 핸들 검증 (SPEC §6.2)
        let transitions = HandleValidator.transitions(for: clips, media: media, settings: settings)
        return EditDecisionList(media: media, clips: clips, transitions: transitions)
    }

    static func nearestSilenceCenter(to t: Double, in silences: [TimeRange], window: Double,
                                     where allowed: (Double) -> Bool) -> Double? {
        var best: Double?
        var bestDist = Double.infinity
        for s in silences {
            let c = (s.start + s.end) / 2
            let d = abs(c - t)
            if d <= window, d < bestDist, allowed(c) {
                best = c
                bestDist = d
            }
        }
        return best
    }
}

/// 디졸브는 편집점 양쪽 소재(삭제하려던 구간)를 끌어 쓴다.
/// 잘려나간 간격이 전환 길이보다 짧으면 하드컷(기본) 또는 전환을 줄인다.
public enum HandleValidator {
    public static func transitions(for clips: [EDLClip], media: MediaInfo, settings: ExportSettings) -> [EDLTransition] {
        let snap = FrameSnapper(media: media)
        let mediaFrames = Int((media.durationSeconds * media.fps).rounded(.down))
        // 편집점 중앙 정렬을 위해 짝수 프레임으로
        let wanted = evenFrames(snap.frame(settings.transitionDuration))
        var result: [EDLTransition] = []
        for i in 0..<max(0, clips.count - 1) {
            let a = clips[i], b = clips[i + 1]
            let gapFrames = b.sourceStartFrame - a.sourceEndFrame
            let removed = snap.seconds(gapFrames)
            var duration = wanted
            var shortage = false
            // 소재 자체의 끝/처음을 넘는지도 확인
            let tailRoom = mediaFrames - a.sourceEndFrame
            let headRoom = b.sourceStartFrame
            if gapFrames < wanted || tailRoom < wanted / 2 || headRoom < wanted / 2 {
                shortage = true
                if settings.fallbackToHardCut {
                    duration = 0
                } else {
                    let limit = min(gapFrames, tailRoom * 2, headRoom * 2)
                    duration = evenFrames(Int(Double(limit) * 0.8))
                    if duration < 2 { duration = 0 }
                }
            }
            result.append(EDLTransition(afterClip: i, durationFrames: duration, handleShortage: shortage, removedSeconds: removed))
        }
        return result
    }

    static func evenFrames(_ f: Int) -> Int { max(0, f - f % 2) }
}
