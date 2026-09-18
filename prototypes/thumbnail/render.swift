// 썸네일 B안 프로토타입 (Phase 6 참고용, 앱 코드 아님)
// 사용: swiftc -O render.swift -o render && ./render "제목1줄|제목2줄" "본문" "예배구분" out.jpg background.png
// 값 출처: docs/thumbnail-template.md
import AppKit
import CoreText

struct Slot { let lines: [String]; let fonts: [String]; let size: CGFloat; let tracking: CGFloat; let leading: CGFloat
              let rgba: (CGFloat, CGFloat, CGFloat, CGFloat); let rightX: CGFloat; let baselineY: CGFloat }

func font(_ names: [String], _ size: CGFloat) -> CTFont {
    for n in names { let f = CTFontCreateWithName(n as CFString, size, nil)
        if (CTFontCopyPostScriptName(f) as String) == n { return f } }
    fatalError("font not found: \(names)")
}

let args = CommandLine.arguments
let title = args[1].components(separatedBy: "|"), passage = args[2], label = args[3], out = args[4]  // args[5] = 텍스트 없는 배경 PNG (Adobe RGB 값)
guard let bg = NSImage(contentsOfFile: args[5]),
      let cgBG = bg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("bg") }
let W = 2560, H = 1440
let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)!  // PSD 문서 프로필
let bgImg = cgBG.copy(colorSpace: adobe)!  // background.png 픽셀은 Adobe RGB 값
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: adobe, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(bgImg, in: CGRect(x: 0, y: 0, width: W, height: H))

// PSD 값: size × transform scale, tracking(1/1000em), leading × scale, 레이어 불투명도 반영
let s1 = 4.554704732208252, s2 = 6.159036288110902
let twoLine = title.count > 1
let slots = [
  Slot(lines: title, fonts: ["SF_HambakSnow"], size: 50.00583*s1, tracking: -60, leading: 58.07129*s1,
       rgba: (1,1,1,1), rightX: 2534.5024, baselineY: twoLine ? 774.0926 : 1012.0926),
  Slot(lines: [passage], fonts: ["PretendardVariable-Bold","Pretendard-Bold"], size: 20.03765*s1, tracking: -20, leading: 0,
       rgba: (1,1,1,179.0/255), rightX: 2498.2590, baselineY: 1218.3625),
  Slot(lines: [label], fonts: twoLine ? ["PretendardVariable-ExtraBold","Pretendard-ExtraBold"] : ["PretendardVariable-Bold","Pretendard-Bold"],
       size: 20.03765*s2, tracking: -20, leading: 0,
       rgba: (0.74902,0.68945,0.6051,199.0/255), rightX: twoLine ? 2512.1550 : 2488.1550, baselineY: twoLine ? 493.7885 : 738.7885),
]
for slot in slots {
  let f = font(slot.fonts, slot.size)
  for (i, line) in slot.lines.enumerated() {
    let attrs: [NSAttributedString.Key: Any] = [
      .init(kCTFontAttributeName as String): f,
      .init(kCTForegroundColorAttributeName as String): CGColor(colorSpace: adobe, components: [slot.rgba.0, slot.rgba.1, slot.rgba.2, slot.rgba.3])!,
      .init(kCTKernAttributeName as String): slot.tracking / 1000 * slot.size]
    let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attrs))
    let kern = Double(slot.tracking / 1000 * slot.size)
    let w = CTLineGetTypographicBounds(ctLine, nil, nil, nil) - 2 * kern // 실측 보정: 포토샵 오른쪽 정렬 기준점
    let y = slot.baselineY + CGFloat(i) * slot.leading
    ctx.textPosition = CGPoint(x: slot.rightX - CGFloat(w), y: CGFloat(H) - y)
    CTLineDraw(ctLine, ctx)
  }
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: URL(fileURLWithPath: out))
print("wrote", out)
