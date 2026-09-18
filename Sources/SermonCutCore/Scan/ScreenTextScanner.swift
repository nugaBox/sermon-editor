import AVFoundation
import Foundation
import Vision

/// 화면 글자 스캔 (Apple Vision OCR, 기기 안에서 처리)
///
/// 녹화 원본에는 OBS가 띄운 예배 순서 자막이 있다 (09/13 실측):
/// "대표기도" 하단 자막 → "성경 봉독" 슬라이드 → 설교 하단 자막·목차 박스 → "찬송가 329장" 슬라이드 → 광고 슬라이드.
/// 이것으로 설교 구간 후보(SPEC §6.0 자동 찾기)와 설교 제목·본문·목차(§6.6, §6.7)를 얻는다.
public struct ScreenTextSample: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public var text: String
        /// Vision 정규 좌표 (0~1, 원점 왼쪽 아래)
        public var x: Double, y: Double, w: Double, h: Double
        public var confidence: Double
        public init(text: String, x: Double, y: Double, w: Double, h: Double, confidence: Double) {
            self.text = text; self.x = x; self.y = y; self.w = w; self.h = h; self.confidence = confidence
        }
    }
    public var time: Double
    public var lines: [Line]
    public init(time: Double, lines: [Line]) { self.time = time; self.lines = lines }

    /// 공백 없는 전체 텍스트 (키워드 검색용)
    public var compact: String { lines.map(\.text).joined(separator: " ").replacingOccurrences(of: " ", with: "") }
}

public struct ScreenTextScan: Codable, Sendable, Equatable {
    public var interval: Double
    public var samples: [ScreenTextSample]
    public init(interval: Double, samples: [ScreenTextSample]) { self.interval = interval; self.samples = samples }
}

public struct ScreenTextScanner: Sendable {
    public var interval: Double
    /// OCR 입력 크기 (작을수록 빠름. 720p면 하단 자막 글씨도 충분히 읽힘)
    public var maxSize = CGSize(width: 1280, height: 720)

    public init(interval: Double = 2) { self.interval = interval }

    public var concurrency = 4

    /// 일정 간격으로 스캔 (결과 캐시)
    public func scan(video: URL, range: TimeRange? = nil, cacheDirectory: URL?,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> ScreenTextScan {
        let key = WaveformGenerator.cacheKey(video) + String(format: "-%.1f", interval)
            + (range.map { String(format: "-%.0f-%.0f", $0.start, $0.end) } ?? "")
        let cacheURL = cacheDirectory?.appendingPathComponent("screentext-\(key).json")
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(ScreenTextScan.self, from: data) {
            return cached
        }
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        let r = range ?? TimeRange(start: 0, end: duration)
        let times = Array(stride(from: r.start, to: min(r.end, duration), by: interval))
        let samples = try await scan(video: video, times: times, progress: progress)
        let result = ScreenTextScan(interval: interval, samples: samples)
        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(result).write(to: cacheURL, options: .atomic)
        }
        return result
    }

    /// 지정한 시각들만 스캔. 프레임 추출은 순서대로, OCR은 동시에 `concurrency`개
    public func scan(video: URL, times: [Double], progress: (@Sendable (Double) -> Void)? = nil) async throws -> [ScreenTextSample] {
        guard !times.isEmpty else { return [] }
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = maxSize
        generator.appliesPreferredTrackTransform = true
        // 자막은 몇 초씩 떠 있으므로 정확한 프레임이 필요 없다 → 가까운 프레임 허용으로 빠르게
        let tolerance = CMTime(seconds: min(0.5, interval / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var samples: [ScreenTextSample] = []
        samples.reserveCapacity(times.count)
        let total = Double(times.count)
        try await withThrowingTaskGroup(of: ScreenTextSample?.self) { group in
            var inFlight = 0
            var done = 0
            for await result in generator.images(for: cmTimes) {
                try Task.checkCancellation()
                guard case .success(let requested, let image, _) = result else { continue }
                let t = requested.seconds
                group.addTask { ScreenTextSample(time: t, lines: (try? Self.recognize(image)) ?? []) }
                inFlight += 1
                if inFlight >= concurrency, let s = try await group.next() {
                    inFlight -= 1
                    if let s { samples.append(s) }
                    done += 1
                    if done % 20 == 0 { progress?(Double(done) / total) }
                }
            }
            for try await s in group { if let s { samples.append(s) } }
        }
        progress?(1)
        return samples.sorted { $0.time < $1.time }
    }

    static func recognize(_ image: CGImage) throws -> [ScreenTextSample.Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.02
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first, top.confidence > 0.3 else { return nil }
            let b = obs.boundingBox
            return .init(text: top.string, x: b.minX, y: b.minY, w: b.width, h: b.height, confidence: Double(top.confidence))
        }
    }
}
