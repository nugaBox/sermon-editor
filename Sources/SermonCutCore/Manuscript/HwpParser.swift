import Compression
import Foundation

/// hwp 5.x(바이너리) 원고에서 문단 텍스트를 뽑는다. 새 의존성 없이 OLE 복합문서를 직접 읽고
/// 본문 압축(raw deflate)은 시스템 Compression 프레임워크로 푼다.
/// 문단 구분·탭·줄바꿈 처리는 HwpxParser와 같은 결과가 나오도록 맞춘다 (docs/hwpx-structure.md §6).
public struct HwpParser: Sendable {
    public init() {}

    public func paragraphs(_ url: URL) throws -> [String] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw SermonCutError.manuscriptUnreadable(fileName: url.lastPathComponent, reason: error.localizedDescription)
        }
        do { return try paragraphs(data) } catch SermonCutError.manuscriptUnreadable(_, let reason) {
            throw SermonCutError.manuscriptUnreadable(fileName: url.lastPathComponent, reason: reason)
        }
    }

    public func paragraphs(_ data: Data) throws -> [String] {
        let file = try CompoundFile(data)
        guard let header = try file.stream("FileHeader"), header.count >= 40,
              header.prefix(17) == Data("HWP Document File".utf8) else {
            throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "한글 문서 머리말이 없음")
        }
        let flags = header.u32(36)
        // bit1 암호, bit2 배포용 문서 → 본문이 암호화되어 있어 읽을 수 없다
        if flags & 0b110 != 0 { throw SermonCutError.hwpProtected }
        let compressed = flags & 1 != 0

        let sections = file.streamNames
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("BodyText/Section"), let n = Int(name.dropFirst("BodyText/Section".count)) else { return nil }
                return (n, name)
            }
            .sorted { $0.0 < $1.0 }
        guard !sections.isEmpty else { throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "본문 구역이 없음") }

        var out: [String] = []
        for (_, name) in sections {
            guard var body = try file.stream(name) else { continue }
            if compressed { body = try Self.inflate(body) }
            out += Self.recordParagraphs(body)
        }
        return out
    }

    // MARK: - 레코드

    static let tagParaHeader: UInt32 = 66   // HWPTAG_BEGIN(16) + 50
    static let tagParaText: UInt32 = 67     // HWPTAG_BEGIN(16) + 51

    /// 레코드 스트림 → 문단. 문단 머리(PARA_HEADER)마다 문단 하나, 글자는 뒤따르는 PARA_TEXT에서.
    /// 표 안 문단도 문서 순서대로 나온다 (hwpx의 hp:p 순서와 같음).
    static func recordParagraphs(_ body: Data) -> [String] {
        var paragraphs: [String] = []
        var i = body.startIndex
        while i + 4 <= body.endIndex {
            let h = body.u32(i - body.startIndex)
            let tag = h & 0x3FF
            var size = Int(h >> 20)
            i += 4
            if size == 0xFFF {
                guard i + 4 <= body.endIndex else { break }
                size = Int(body.u32(i - body.startIndex))
                i += 4
            }
            guard i + size <= body.endIndex else { break }
            if tag == tagParaHeader {
                paragraphs.append("")
            } else if tag == tagParaText, !paragraphs.isEmpty {
                paragraphs[paragraphs.count - 1] = paraText(body[i..<(i + size)])
            }
            i += size
        }
        return paragraphs
    }

    /// PARA_TEXT(UTF-16LE). 제어 문자 중 0·10·13·24~31은 1글자, 나머지 1~31은 8글자(코드 + 정보 + 코드)를 차지한다.
    static func paraText(_ raw: Data) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(raw.count / 2)
        var k = 0
        let n = raw.count / 2
        while k < n {
            let c = raw.u16(k * 2)
            switch c {
            case 9: units.append(0x20); k += 8                  // 탭 → 공백 (HwpxParser와 같게)
            case 10: units.append(0x0A); k += 1                 // 강제 줄바꿈
            case 0, 13, 24...31: k += 1                         // 문단 끝·하이픈 등 1글자 제어
            case 1...31: k += 8                                 // 표·각주·필드 등 확장/인라인 제어
            default: units.append(c); k += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// raw deflate(zlib 헤더 없음) 해제
    static func inflate(_ input: Data) throws -> Data {
        var output = Data()
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "압축 해제 준비 실패")
        }
        defer { compression_stream_destroy(stream) }
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(dst, count: chunk - stream.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return
                default: throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "본문 압축 해제 실패")
                }
            }
        }
        return output
    }
}

/// OLE 복합문서(CFB) 최소 읽기 — 스트림 경로("BodyText/Section0")로 내용을 꺼낸다.
struct CompoundFile {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var miniStream = Data()
    private var entries: [String: (start: UInt32, size: Int)] = [:]

    private static let endOfChain: UInt32 = 0xFFFF_FFFA   // 이 값 이상은 특수 표시(끝·빈칸·FAT)
    private static let signature = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])

    init(_ data: Data) throws {
        let data = Data(data)   // 0부터 시작하는 색인 보장
        guard data.count >= 512, data.prefix(8) == Self.signature else {
            throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "OLE 복합문서가 아님")
        }
        self.data = data
        sectorSize = 1 << Int(data.u16(30))
        miniSectorSize = 1 << Int(data.u16(32))
        miniCutoff = Int(data.u32(56))
        guard (512...4096).contains(sectorSize), miniSectorSize <= sectorSize else {
            throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "섹터 크기가 잘못됨")
        }
        let fatCount = Int(data.u32(44))
        let dirStart = data.u32(48)
        let miniFatStart = data.u32(60)

        // DIFAT: 머리말의 109칸 + 이어지는 DIFAT 섹터
        var difat = (0..<109).map { data.u32(76 + $0 * 4) }
        var next = data.u32(68)
        var guardCount = 0
        while next < Self.endOfChain, guardCount < 10_000 {
            let s = try sector(next)
            let perSector = sectorSize / 4
            difat += (0..<(perSector - 1)).map { s.u32($0 * 4) }
            next = s.u32((perSector - 1) * 4)
            guardCount += 1
        }
        for d in difat.filter({ $0 < Self.endOfChain }).prefix(fatCount) {
            let s = try sector(d)
            fat += (0..<(sectorSize / 4)).map { s.u32($0 * 4) }
        }

        let dir = try readChain(dirStart)
        var raw: [(name: String, type: UInt8, left: UInt32, right: UInt32, child: UInt32, start: UInt32, size: Int)] = []
        for k in 0..<(dir.count / 128) {
            let e = dir.subdata(in: (k * 128)..<((k + 1) * 128))
            let nameLength = max(Int(e.u16(64)) - 2, 0)
            let name = String(decoding: (0..<(min(nameLength, 64) / 2)).map { e.u16($0 * 2) }, as: UTF16.self)
            raw.append((name, e[66], e.u32(68), e.u32(72), e.u32(76), e.u32(116), Int(e.u32(120))))
        }
        guard let root = raw.first else { throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "디렉터리가 비어 있음") }

        if miniFatStart < Self.endOfChain {
            let mf = try readChain(miniFatStart)
            miniFat = (0..<(mf.count / 4)).map { mf.u32($0 * 4) }
        }
        miniStream = try readChain(root.start)

        // 디렉터리는 형제끼리 레드블랙 트리(left/right), 저장소(type 1)는 child로 내려간다
        var visited = Set<UInt32>()
        func walk(_ index: UInt32, _ prefix: String) {
            guard Int(index) < raw.count, visited.insert(index).inserted else { return }
            let e = raw[Int(index)]
            walk(e.left, prefix)
            walk(e.right, prefix)
            switch e.type {
            case 2: entries[prefix + e.name] = (e.start, e.size)
            case 1: walk(e.child, prefix + e.name + "/")
            default: break
            }
        }
        walk(root.child, "")
    }

    var streamNames: [String] { Array(entries.keys) }

    func stream(_ path: String) throws -> Data? {
        guard let e = entries[path] else { return nil }
        let content = e.size < miniCutoff ? try readMiniChain(e.start) : try readChain(e.start)
        guard content.count >= e.size else {
            throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "\(path) 스트림이 잘림")
        }
        return content.prefix(e.size)
    }

    private func sector(_ index: UInt32) throws -> Data {
        let offset = 512 + Int(index) * sectorSize
        guard offset + sectorSize <= data.count else {
            throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "섹터 범위를 벗어남")
        }
        return data.subdata(in: offset..<(offset + sectorSize))
    }

    private func readChain(_ start: UInt32) throws -> Data {
        var out = Data()
        var s = start
        var count = 0
        while s < Self.endOfChain {
            guard Int(s) < fat.count, count <= fat.count else {
                throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "섹터 체인이 잘못됨")
            }
            out += try sector(s)
            s = fat[Int(s)]
            count += 1
        }
        return out
    }

    private func readMiniChain(_ start: UInt32) throws -> Data {
        var out = Data()
        var s = start
        var count = 0
        while s < Self.endOfChain {
            let offset = Int(s) * miniSectorSize
            guard Int(s) < miniFat.count, count <= miniFat.count, offset + miniSectorSize <= miniStream.count else {
                throw SermonCutError.manuscriptUnreadable(fileName: "hwp", reason: "작은 섹터 체인이 잘못됨")
            }
            out += miniStream.subdata(in: offset..<(offset + miniSectorSize))
            s = miniFat[Int(s)]
            count += 1
        }
        return out
    }
}

extension Data {
    /// 리틀 엔디언 읽기 (startIndex 기준 상대 위치)
    func u16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
