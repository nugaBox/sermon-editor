import Foundation
import ImageIO

/// 매주 똑같이 쓰는 인트로/아웃트로/썸네일 재료 (SPEC Phase 6)
///
/// 폴더 구조 (~/Library/Application Support/SermonCut/templates/<이름>/):
///   template.json   썸네일 글자 칸 (없으면 2026 주일낮예배 기본값)
///   background.png  썸네일 배경 (글자 레이어를 뺀 PSD 합성본)
///   intro.mp3       인트로 음악 (갓피플NCB-ToTheLord-10s)
///   outro.mp3       아웃트로 음악 (갓피플NCB-Hope-15s)
///   end-poster.jpg  끝 화면 (매년 바뀜)
public struct TemplatePack: Sendable, Equatable {
    public var folder: URL

    public init(folder: URL) { self.folder = folder }

    public static var root: URL {
        WhisperOptions.defaultModelsDirectory().deletingLastPathComponent().appendingPathComponent("templates")
    }
    public static var defaultPack: TemplatePack { TemplatePack(folder: root.appendingPathComponent("sunday")) }

    public var background: URL { folder.appendingPathComponent("background.png") }
    public var introAudio: URL { folder.appendingPathComponent("intro.mp3") }
    public var outroAudio: URL { folder.appendingPathComponent("outro.mp3") }
    public var endPoster: URL { folder.appendingPathComponent("end-poster.jpg") }
    public var templateJSON: URL { folder.appendingPathComponent("template.json") }

    public var thumbnailTemplate: ThumbnailTemplate {
        (try? JSONDecoder().decode(ThumbnailTemplate.self, from: Data(contentsOf: templateJSON))) ?? .sundaySermon2026
    }

    func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
    public var hasThumbnail: Bool { exists(background) }
    public var hasIntroOutro: Bool { exists(introAudio) && exists(outroAudio) && exists(endPoster) }

    /// 빠진 재료 목록 (한국어)
    public var missing: [String] {
        var m: [String] = []
        if !exists(background) { m.append("썸네일 배경(background.png)") }
        if !exists(introAudio) { m.append("인트로 음악(intro.mp3)") }
        if !exists(outroAudio) { m.append("아웃트로 음악(outro.mp3)") }
        if !exists(endPoster) { m.append("끝 화면(end-poster.jpg)") }
        return m
    }

    /// 파일 하나를 팩에 복사 (확장자는 대상 이름을 따름)
    public func install(_ source: URL, as target: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
    }
}

/// Photoshop 자동화 (SPEC §6.7 A안). 설치된 Photoshop을 AppleScript `do javascript`로 구동한다.
public enum PhotoshopBridge {
    public static let bundleIDs = ["com.adobe.Photoshop"]

    /// PSD에서 글자 레이어만 숨긴 합성본을 PNG로 (배경 갱신용, 원본 PSD는 저장하지 않고 닫음)
    public static func exportBackground(psd: URL, to png: URL, locator: BinaryLocator = BinaryLocator()) async throws {
        let js = """
        var f = new File(\(jsString(psd.path)));
        var doc = app.open(f);
        function hideText(layers) {
          for (var i = 0; i < layers.length; i++) {
            var l = layers[i];
            if (l.typename == 'LayerSet') { hideText(l.layers); }
            else if (l.kind == LayerKind.TEXT) { l.visible = false; }
          }
        }
        hideText(doc.layers);
        var opts = new PNGSaveOptions();
        doc.saveAs(new File(\(jsString(png.path))), opts, true, Extension.LOWERCASE);
        doc.close(SaveOptions.DONOTSAVECHANGES);
        'ok';
        """
        try await run(js)
    }

    static func run(_ javascript: String) async throws {
        let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
        let escaped = javascript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // Photoshop 첫 실행은 수 분 걸릴 수 있어 AppleEvent 대기 시간을 늘린다 (기본 2분이면 시간 초과)
        let script = "with timeout of 900 seconds\ntell application id \"com.adobe.Photoshop\" to do javascript \"\(escaped)\"\nend timeout"
        try await ProcessRunner.run(osascript, ["-e", script], toolName: "Photoshop")
    }

    static func jsString(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

extension TemplatePack {
    /// FCPXML 앞뒤 구성 재료 (음악 길이·이미지 크기 측정)
    public func bookends(thumbnail: URL, locator: BinaryLocator = BinaryLocator()) async throws -> FCPXMLExporter.Bookends {
        func still(_ u: URL) throws -> FCPXMLExporter.Bookends.Still {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
                throw SermonCutError.invalidArgument("이미지를 읽지 못했습니다: \(u.lastPathComponent)")
            }
            return .init(url: u, width: w, height: h)
        }
        func audio(_ u: URL) async throws -> FCPXMLExporter.Bookends.Audio {
            let ffprobe = try locator.url(for: .ffprobe)
            let r = try await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", u.path], toolName: "ffprobe")
            guard let root = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
                  let a = (root["streams"] as? [[String: Any]])?.first(where: { ($0["codec_type"] as? String) == "audio" }),
                  let d = ((root["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init) else {
                throw SermonCutError.invalidArgument("음악 파일을 읽지 못했습니다: \(u.lastPathComponent)")
            }
            let rate = (a["sample_rate"] as? String).flatMap(Int.init) ?? 44100
            // mp3는 헤더 추정 길이가 실제보다 짧다(인트로 9.73초 vs 실제 10.06초) → 끝까지 디코딩해 샘플 수로 잰다
            let ffmpeg = try locator.url(for: .ffmpeg)
            let pcm = try await ProcessRunner.run(ffmpeg, ["-nostdin", "-v", "error", "-i", u.path, "-ac", "1", "-f", "s16le", "-"], toolName: "ffmpeg")
            let decoded = Double(pcm.stdout.count / 2) / Double(rate)
            return .init(url: u, duration: decoded > 0 ? decoded : d, sampleRate: rate, channels: a["channels"] as? Int ?? 2)
        }
        guard hasIntroOutro else { throw SermonCutError.invalidArgument("템플릿 재료가 없습니다: " + missing.joined(separator: ", ")) }
        return FCPXMLExporter.Bookends(thumbnail: try still(thumbnail), introAudio: try await audio(introAudio),
                                       endPoster: try still(endPoster), outroAudio: try await audio(outroAudio))
    }
}
