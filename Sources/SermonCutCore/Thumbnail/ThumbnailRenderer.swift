import AppKit
import CoreText
import Foundation

/// 썸네일 템플릿 팩 = background.png(글자 뺀 배경) + template.json(글자 칸). SPEC §6.7 B안, docs/thumbnail-template.md
public struct ThumbnailTemplate: Codable, Sendable, Equatable {
    public struct Slot: Codable, Sendable, Equatable {
        public var fonts: [String]         // PostScript 이름, 앞에서부터 설치된 것 사용
        public var size: Double            // px
        public var tracking: Double        // 1/1000 em
        public var leading: Double         // px (2줄 이상)
        public var color: [Double]         // 문서 색공간 RGBA 0~1
        public var rightX: Double          // 오른쪽 정렬 기준
        public var baselineY: Double       // 첫 줄 기준선 (위에서부터 px)
    }
    public var width: Int = 2560
    public var height: Int = 1440
    /// "adobeRGB" 또는 "sRGB"
    public var colorSpace: String = "adobeRGB"
    public var title1: Slot                // 1줄 제목
    public var title2: Slot                // 2줄 제목 (첫 줄 기준선)
    public var passage: Slot
    public var label1: Slot                // 예배 구분 (1줄 제목 레이아웃)
    public var label2: Slot                // 예배 구분 (2줄 제목 레이아웃)
    /// 1줄 제목이 이 x보다 왼쪽으로 넘어가면 2줄로 (사진 영역 보호)
    public var titleLeftLimit: Double = 1000

    /// 2026 주일낮예배 PSD 값 (docs/thumbnail-template.md §2)
    public static let sundaySermon2026: ThumbnailTemplate = {
        let s1 = 4.554704732208252, s2 = 6.159036288110902
        let white = [1.0, 1, 1, 1]
        let label = [0.74902, 0.68945, 0.6051, 199.0 / 255]
        return ThumbnailTemplate(
            title1: .init(fonts: ["SF_HambakSnow"], size: 50.00583 * s1, tracking: -60, leading: 0, color: white, rightX: 2534.5024, baselineY: 1012.0926),
            title2: .init(fonts: ["SF_HambakSnow"], size: 50.00583 * s1, tracking: -60, leading: 58.07129 * s1, color: white, rightX: 2534.5024, baselineY: 774.0926),
            passage: .init(fonts: ["PretendardVariable-Bold", "Pretendard-Bold"], size: 20.03765 * s1, tracking: -20, leading: 0,
                           color: [1, 1, 1, 179.0 / 255], rightX: 2498.2590, baselineY: 1218.3625),
            label1: .init(fonts: ["PretendardVariable-Bold", "Pretendard-Bold"], size: 20.03765 * s2, tracking: -20, leading: 0,
                          color: label, rightX: 2488.1550, baselineY: 738.7885),
            label2: .init(fonts: ["PretendardVariable-ExtraBold", "Pretendard-ExtraBold"], size: 20.03765 * s2, tracking: -20, leading: 0,
                          color: label, rightX: 2512.1550, baselineY: 493.7885))
    }()
}

public struct ThumbnailContent: Codable, Sendable, Equatable {
    public var title: String
    /// 사용자가 정한 줄바꿈 ("|" 로 구분). nil이면 자동
    public var titleLines: [String]?
    public var passage: String
    public var label: String

    public init(title: String, titleLines: [String]? = nil, passage: String, label: String) {
        self.title = title
        self.titleLines = titleLines
        self.passage = passage
        self.label = label
    }
}

public enum ThumbnailRenderer {
    public enum Failure: LocalizedError {
        case background(String), font(String), encode
        public var errorDescription: String? {
            switch self {
            case .background(let p): return "썸네일 배경 이미지를 읽지 못했습니다: \(p)"
            case .font(let f): return "썸네일 글꼴이 설치되어 있지 않습니다: \(f)"
            case .encode: return "썸네일 JPG를 만들지 못했습니다."
            }
        }
    }

    /// 제목 줄 결정: 사용자가 정했으면 그대로, 아니면 1줄 폭이 사진을 덮으면 2줄 (두 줄 폭이 가장 비슷해지는 띄어쓰기)
    public static func titleLines(_ content: ThumbnailContent, template t: ThumbnailTemplate) throws -> [String] {
        if let lines = content.titleLines, !lines.isEmpty { return lines }
        let title = content.title.trimmingCharacters(in: .whitespaces)
        let font = try makeFont(t.title1)
        if Double(t.title1.rightX) - width(title, font: font, tracking: t.title1.tracking) >= t.titleLeftLimit { return [title] }
        let words = title.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [title] }
        var best: (lines: [String], diff: Double) = ([title], .infinity)
        for i in 1..<words.count {
            let a = words[..<i].joined(separator: " "), b = words[i...].joined(separator: " ")
            let d = abs(width(a, font: font, tracking: t.title2.tracking) - width(b, font: font, tracking: t.title2.tracking))
            if d < best.diff { best = ([a, b], d) }
        }
        return best.lines
    }

    /// JPG 데이터 (문서 색공간 프로필 포함)
    public static func render(_ content: ThumbnailContent, template t: ThumbnailTemplate, background: URL) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(background as CFURL, nil),
              let bg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw Failure.background(background.path) }
        let space = (t.colorSpace == "adobeRGB" ? CGColorSpace(name: CGColorSpace.adobeRGB1998) : CGColorSpace(name: CGColorSpace.sRGB))
            ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: t.width, height: t.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.encode }
        // 배경 PNG에 프로필이 없으면 픽셀 값을 문서 색공간 값으로 해석
        let bgImage = bg.colorSpace?.name == nil ? (bg.copy(colorSpace: space) ?? bg) : bg
        ctx.draw(bgImage, in: CGRect(x: 0, y: 0, width: t.width, height: t.height))

        let lines = try titleLines(content, template: t)
        let twoLine = lines.count > 1
        try draw(lines, slot: twoLine ? t.title2 : t.title1, ctx: ctx, space: space, height: t.height)
        try draw([content.passage], slot: t.passage, ctx: ctx, space: space, height: t.height)
        try draw([content.label], slot: twoLine ? t.label2 : t.label1, ctx: ctx, space: space, height: t.height)

        guard let image = ctx.makeImage() else { throw Failure.encode }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { throw Failure.encode }
        return data
    }

    static func makeFont(_ slot: ThumbnailTemplate.Slot) throws -> CTFont {
        for name in slot.fonts {
            let f = CTFontCreateWithName(name as CFString, slot.size, nil)
            if (CTFontCopyPostScriptName(f) as String) == name { return f }
        }
        throw Failure.font(slot.fonts.joined(separator: " / "))
    }

    /// 포토샵 오른쪽 정렬과 같게: 폭 − 2×자간 (실측 보정, docs/thumbnail-template.md §3)
    static func width(_ text: String, font: CTFont, tracking: Double) -> Double {
        let kern = tracking / 1000 * Double(CTFontGetSize(font))
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font, .init(kCTKernAttributeName as String): kern]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        return CTLineGetTypographicBounds(line, nil, nil, nil) - 2 * kern
    }

    static func draw(_ lines: [String], slot: ThumbnailTemplate.Slot, ctx: CGContext, space: CGColorSpace, height: Int) throws {
        let font = try makeFont(slot)
        let comps = slot.color.map { CGFloat($0) }
        guard let color = CGColor(colorSpace: space, components: comps) else { return }
        let kern = slot.tracking / 1000 * slot.size
        for (i, text) in lines.enumerated() where !text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): color,
                .init(kCTKernAttributeName as String): kern,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            let w = width(text, font: font, tracking: slot.tracking)
            let y = slot.baselineY + Double(i) * slot.leading
            ctx.textPosition = CGPoint(x: slot.rightX - w, y: Double(height) - y)
            CTLineDraw(line, ctx)
        }
    }

    /// 원고·화면에서 기본 내용 만들기: 제목 끝 "(7)" 제거, 예배 구분은 화면 자막 "주일낮예배 설교 | 강해 (7)"의 앞부분
    public static func defaultContent(manuscript: Manuscript?, screen: RangeFinder.Metadata?) -> ThumbnailContent {
        let title = manuscript?.title ?? screen?.title ?? ""
        let passage = manuscript?.passage ?? screen?.passage ?? ""
        let label = screen?.serviceLabel?.components(separatedBy: CharacterSet(charactersIn: "|｜")).first?
            .trimmingCharacters(in: .whitespaces) ?? "주일낮예배 설교"
        return ThumbnailContent(title: title, passage: passage, label: label.isEmpty ? "주일낮예배 설교" : label)
    }
}
