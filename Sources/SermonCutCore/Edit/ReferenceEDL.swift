import Foundation

/// 사용자가 FCP에서 직접 편집해 내보낸 FCPXML에서 "원본 영상의 어느 구간을 남겼는지"를 읽는다. (검증·학습용)
public enum ReferenceEDLReader {
    /// - Parameter assetName: 원본 영상 에셋 이름 (보통 파일명에서 확장자 뺀 것)
    /// - Returns: 원본 기준 유지 구간(초), 시간 순
    public static func keptRanges(fcpxml data: Data, assetName: String) throws -> [TimeRange] {
        final class Delegate: NSObject, XMLParserDelegate {
            let target: String
            var assetNames: [String: String] = [:]
            var depth = 0
            var spineDepth: Int?
            struct Pending { var start: Double; var duration: Double; var name: String?; var ref: String?; var videoRef: String? }
            var pending: Pending?
            var pendingDepth = 0
            var found: [(Pending)] = []
            init(target: String) { self.target = target }

            func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
                depth += 1
                if el == "asset", let id = a["id"] { assetNames[id] = a["name"] ?? "" }
                if el == "spine", spineDepth == nil { spineDepth = depth }
                if let sd = spineDepth, depth == sd + 1, el == "clip" || el == "asset-clip",
                   let d = a["duration"].flatMap(ReferenceEDLReader.seconds) {
                    pending = Pending(start: a["start"].flatMap(ReferenceEDLReader.seconds) ?? 0, duration: d,
                                      name: a["name"], ref: a["ref"], videoRef: nil)
                    pendingDepth = depth
                }
                if pending != nil, depth == pendingDepth + 1, el == "video" || el == "asset-clip", pending?.videoRef == nil {
                    pending?.videoRef = a["ref"]
                }
            }

            func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
                if let p = pending, depth == pendingDepth {
                    let refName = (p.ref ?? p.videoRef).flatMap { assetNames[$0] }
                    if refName == target || p.name == target { found.append(p) }
                    pending = nil
                }
                if let sd = spineDepth, depth == sd, el == "spine" { spineDepth = -1 }
                depth -= 1
            }
        }
        let parser = XMLParser(data: data)
        let d = Delegate(target: assetName)
        parser.delegate = d
        guard parser.parse() else {
            throw SermonCutError.invalidArgument("기준 FCPXML을 읽지 못했습니다: \(parser.parserError?.localizedDescription ?? "")")
        }
        return d.found.map { TimeRange(start: $0.start, end: $0.start + $0.duration) }.sorted { $0.start < $1.start }
    }

    /// "6487700/3000s", "2632s", "0s"
    static func seconds(_ text: String) -> Double? {
        guard text.hasSuffix("s") else { return nil }
        let body = text.dropLast()
        let parts = body.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        return Double(body)
    }
}

/// 제안 결과를 기준 편집과 비교
public struct EditComparison: Sendable {
    public var window: TimeRange
    /// 기준이 삭제한 시간 / 우리가 삭제한 시간 / 둘 다 삭제한 시간 (초)
    public var referenceRemoved: Double
    public var predictedRemoved: Double
    public var bothRemoved: Double
    /// 삭제 판단이 일치한 시간 비율
    public var agreement: Double

    public var recall: Double { referenceRemoved > 0 ? bothRemoved / referenceRemoved : 1 }
    public var precision: Double { predictedRemoved > 0 ? bothRemoved / predictedRemoved : 1 }

    /// kept 구간 목록 두 개를 0.1초 격자로 비교
    public static func compare(reference: [TimeRange], predicted: [TimeRange], window: TimeRange) -> EditComparison {
        let step = 0.1
        var refRm = 0.0, preRm = 0.0, both = 0.0, agree = 0.0, total = 0.0
        var t = window.start + step / 2
        func kept(_ list: [TimeRange], _ t: Double) -> Bool { list.contains { $0.start <= t && t < $0.end } }
        while t < window.end {
            let r = !kept(reference, t), p = !kept(predicted, t)
            if r { refRm += step }
            if p { preRm += step }
            if r && p { both += step }
            if r == p { agree += step }
            total += step
            t += step
        }
        return EditComparison(window: window, referenceRemoved: refRm, predictedRemoved: preRm, bothRemoved: both,
                              agreement: total > 0 ? agree / total : 1)
    }
}
