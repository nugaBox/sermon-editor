import XCTest
@testable import SermonCutCore

final class TemplateTests: XCTestCase {
    func fontsInstalled() -> Bool {
        (try? ThumbnailRenderer.makeFont(ThumbnailTemplate.sundaySermon2026.title1)) != nil
    }

    func testTitleLineBreakMatchesUserThumbnail() throws {
        try XCTSkipUnless(fontsInstalled(), "SF함박눈 글꼴 없음")
        let t = ThumbnailTemplate.sundaySermon2026
        let c = ThumbnailContent(title: "믿음의 사람이 세상을 돌파한다", passage: "에스더 4장 1~17절", label: "주일낮예배 설교")
        XCTAssertEqual(try ThumbnailRenderer.titleLines(c, template: t), ["믿음의 사람이", "세상을 돌파한다"])   // 09/13 썸네일과 동일
        let short = ThumbnailContent(title: "은혜", passage: "", label: "")
        XCTAssertEqual(try ThumbnailRenderer.titleLines(short, template: t), ["은혜"])
        var forced = c
        forced.titleLines = ["믿음의 사람이 세상을 돌파한다"]
        XCTAssertEqual(try ThumbnailRenderer.titleLines(forced, template: t).count, 1)
    }

    func testDefaultContentFromScreenLabel() {
        var screen = RangeFinder.Metadata()
        screen.title = "화면 제목"
        screen.passage = "요한복음 3장"
        screen.serviceLabel = "주일오후예배 설교 | 강해 (3)"
        let c = ThumbnailRenderer.defaultContent(manuscript: nil, screen: screen)
        XCTAssertEqual(c.title, "화면 제목")
        XCTAssertEqual(c.label, "주일오후예배 설교")
        let fallback = ThumbnailRenderer.defaultContent(manuscript: nil, screen: nil)
        XCTAssertEqual(fallback.label, "주일낮예배 설교")
    }

    func testFCPXMLWithBookendsMatchesUserStructureAndDTD() async throws {
        let media = MediaInfo(durationSeconds: 5506.133333, frameRateNum: 30, frameRateDen: 1, width: 1920, height: 1080,
                              hasAudio: true, audioSampleRate: 48000, audioChannels: 2)
        let edl = EditDecisionList.fromKeptRanges([TimeRange(start: 2162.5667, end: 2378.2667), TimeRange(start: 2632, end: 3287.7667)], media: media)
        var opt = FCPXMLExporter.Options(eventName: "E", projectName: "P", audioGainDB: 12)
        opt.bookends = .init(thumbnail: .init(url: URL(fileURLWithPath: "/tmp/t.jpg"), width: 2560, height: 1440),
                             introAudio: .init(url: URL(fileURLWithPath: "/tmp/i.mp3"), duration: 443520.0 / 44100, sampleRate: 44100, channels: 2),
                             endPoster: .init(url: URL(fileURLWithPath: "/tmp/e.jpg"), width: 1920, height: 1080),
                             outroAudio: .init(url: URL(fileURLWithPath: "/tmp/o.mp3"), duration: 664704.0 / 44100, sampleRate: 44100, channels: 2))
        let xml = FCPXMLExporter().export(edl: edl, videoURL: URL(fileURLWithPath: "/tmp/v.mp4"), options: opt)
        // 09/13 완성본과 같은 값 (docs/fcpxml-reference.md §3)
        XCTAssertTrue(xml.contains("<video ref=\"r7\" offset=\"0s\" start=\"3600s\" duration=\"30200/3000s\">"))
        XCTAssertTrue(xml.contains("<transition name=\"색상으로 페이드\" offset=\"26500/3000s\" duration=\"7400/3000s\">"))
        XCTAssertTrue(xml.contains("<asset-clip ref=\"r2\" offset=\"30200/3000s\""))                // 설교 첫 클립은 인트로 뒤
        XCTAssertTrue(xml.contains("duration=\"443520/44100s\""))
        XCTAssertTrue(xml.contains("name=\"o\" duration=\"45200/3000s\""))                           // 아웃트로 음악 15.067초
        XCTAssertTrue(xml.contains("duration=\"44100/3000s\"/>"))                                     // 끝 화면 14.7초
        XCTAssertTrue(xml.contains("uid=\"FxPlug:F779C565-486D-4633-8035-0374B4DB8F5C\""))

        let dtdPath = "/Applications/Final Cut Pro Creator Studio.app/Contents/Frameworks/Interchange.framework/Versions/A/Resources/FCPXMLv1_14.dtd"
        guard FileManager.default.fileExists(atPath: dtdPath) else { throw XCTSkip("DTD 없음") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-bookends-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(atPath: dtdPath, toPath: tmp.appendingPathComponent("d.dtd").path)
        try xml.write(to: tmp.appendingPathComponent("x.fcpxml"), atomically: true, encoding: .utf8)
        let r = try await ProcessRunner.run(try BinaryLocator().url(for: .xmllint),
                                            ["--noout", "--dtdvalid", tmp.appendingPathComponent("d.dtd").path, tmp.appendingPathComponent("x.fcpxml").path],
                                            allowNonZeroExit: true)
        XCTAssertEqual(r.exitCode, 0, r.stderrString)
    }

    func testRenderPlanWithBookendsLength() {
        let media = MediaInfo(durationSeconds: 5506, frameRateNum: 30, frameRateDen: 1, width: 1920, height: 1080, hasAudio: true)
        let edl = EditDecisionList.fromKeptRanges([TimeRange(start: 100, end: 200)], media: media)
        var o = FFmpegRenderer.Options(preset: .preview, audioGainDB: 0)
        o.bookends = .init(thumbnail: .init(url: URL(fileURLWithPath: "/tmp/t.jpg"), width: 2560, height: 1440),
                           introAudio: .init(url: URL(fileURLWithPath: "/tmp/i.mp3"), duration: 10, sampleRate: 44100, channels: 2),
                           endPoster: .init(url: URL(fileURLWithPath: "/tmp/e.jpg"), width: 1920, height: 1080),
                           outroAudio: .init(url: URL(fileURLWithPath: "/tmp/o.mp3"), duration: 15, sampleRate: 44100, channels: 2))
        let plan = FFmpegRenderer.plan(edl: edl, options: o)
        XCTAssertEqual(plan.duration, 302.0 / 30 + 100 + 441.0 / 30, accuracy: 1e-6)   // 인트로 + 설교 + 끝 화면
        XCTAssertEqual(plan.inputCount, 5)                                              // 이미지+음악, 원본, 이미지+음악
        XCTAssertTrue(plan.filter.contains("xfade=transition=fadeblack"))
    }
}
