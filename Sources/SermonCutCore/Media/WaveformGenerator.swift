import AVFoundation
import Foundation

/// 파형 피크 배열 (구간 선택 화면용, SPEC §6.0)
public struct Waveform: Codable, Sendable, Equatable {
    /// 버킷별 최대 절댓값 (0...1)
    public var peaks: [Float]
    /// 버킷 하나의 길이 (초)
    public var secondsPerBucket: Double
    public var duration: Double { Double(peaks.count) * secondsPerBucket }
}

/// AVAssetReader로 오디오를 8kHz 모노로 디코딩해 피크를 뽑는다. 결과는 캐시 폴더에 저장해 재사용.
public struct WaveformGenerator: Sendable {
    public var bucketsPerSecond: Double
    public var sampleRate: Double = 8000

    public init(bucketsPerSecond: Double = 10) { self.bucketsPerSecond = bucketsPerSecond }

    public func generate(video: URL, cacheDirectory: URL?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Waveform {
        let cacheURL = cacheDirectory.map { $0.appendingPathComponent(Self.cacheKey(video) + ".waveform.json") }
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let w = try? JSONDecoder().decode(Waveform.self, from: data) {
            return w
        }
        let w = try await decode(video: video, progress: progress)
        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(w).write(to: cacheURL, options: .atomic)
        }
        return w
    }

    /// 경로·크기·수정 시각으로 캐시 키
    public static func cacheKey(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var hasher = StableHash()
        hasher.combine(url.standardizedFileURL.path)
        hasher.combine("\(size)-\(Int(mtime))")
        return hasher.hex
    }

    private func decode(video: URL, progress: (@Sendable (Double) -> Void)?) async throws -> Waveform {
        let asset = AVURLAsset(url: video)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty, duration > 0 else {
            throw SermonCutError.mediaProbeFailed(reason: "오디오 트랙이 없습니다")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SermonCutError.mediaProbeFailed(reason: "오디오를 읽을 수 없습니다") }
        reader.add(output)
        guard reader.startReading() else {
            throw SermonCutError.mediaProbeFailed(reason: reader.error?.localizedDescription ?? "오디오 읽기 실패")
        }

        let samplesPerBucket = max(1, Int(sampleRate / bucketsPerSecond))
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(duration * bucketsPerSecond) + 1)
        var current: Float = 0
        var count = 0
        var total = 0
        var lastReported = -1

        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            let n = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: n) { samples in
                for i in 0..<n {
                    let v = abs(samples[i])
                    if v > current { current = v }
                    count += 1
                    if count == samplesPerBucket {
                        peaks.append(min(1, current))
                        current = 0
                        count = 0
                    }
                }
            }
            total += n
            let pct = Int(Double(total) / sampleRate / duration * 100)
            if pct != lastReported { lastReported = pct; progress?(min(1, Double(pct) / 100)) }
        }
        if reader.status == .cancelled { throw SermonCutError.cancelled }
        if reader.status == .failed {
            throw SermonCutError.mediaProbeFailed(reason: reader.error?.localizedDescription ?? "오디오 읽기 실패")
        }
        if count > 0 { peaks.append(min(1, current)) }
        return Waveform(peaks: peaks, secondsPerBucket: 1 / bucketsPerSecond)
    }
}

/// 실행마다 바뀌지 않는 간단한 해시 (FNV-1a 64)
struct StableHash {
    private var value: UInt64 = 0xcbf29ce484222325
    mutating func combine(_ s: String) {
        for b in s.utf8 { value ^= UInt64(b); value = value &* 0x100000001b3 }
        value ^= 0xFF; value = value &* 0x100000001b3
    }
    var hex: String { String(format: "%016llx", value) }
}
