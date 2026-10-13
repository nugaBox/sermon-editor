import Compression
import Foundation

/// 테스트용 최소 hwp 5.x 파일을 메모리에서 만든다 (개인 원고를 저장소에 넣지 않기 위해).
/// 구성: OLE 복합문서 512바이트 섹터 — 0: FAT, 1: 디렉터리, 2: 작은 FAT, 3~: 작은 스트림(64바이트 단위).
/// 실제 한글 파일처럼 FileHeader·BodyText/Section0 모두 4096바이트 미만이라 작은 스트림에 들어간다.
enum HwpFixture {
    struct BuildError: Error {}

    static func make(paragraphs: [String], flags: UInt32 = 1, controlInFirstParagraph: Bool = false) throws -> Data {
        var fileHeader = Data("HWP Document File".utf8)
        fileHeader += Data(count: 32 - fileHeader.count)
        fileHeader += le32(0x0501_0000)          // 버전 5.1.0.0
        fileHeader += le32(flags)
        fileHeader += Data(count: 256 - fileHeader.count)

        var records = Data()
        for (n, p) in paragraphs.enumerated() {
            records += record(tag: 66, level: 0, payload: Data(count: 22))
            var units: [UInt16] = []
            if n == 0, controlInFirstParagraph {
                // 확장 제어(11 = 표/그리기 개체)는 8글자를 차지한다
                units += [11, 0x7462, 0x6C20, 0, 0, 0, 0, 11]
            }
            for u in p.utf16 {
                switch u {
                case 0x09: units += [9, 0, 0, 0, 0, 0, 0, 9]
                default: units.append(u)
                }
            }
            units.append(13)
            if !p.isEmpty || n == 0 && controlInFirstParagraph {
                records += record(tag: 67, level: 1, payload: units.reduce(into: Data()) { $0 += le16($1) })
            }
        }
        let body = flags & 1 != 0 ? try deflate(records) : records
        return try compoundFile(fileHeader: fileHeader, section: body)
    }

    static func record(tag: UInt32, level: UInt32, payload: Data) -> Data {
        if payload.count >= 0xFFF {
            return le32(tag | level << 10 | 0xFFF << 20) + le32(UInt32(payload.count)) + payload
        }
        return le32(tag | level << 10 | UInt32(payload.count) << 20) + payload
    }

    static func compoundFile(fileHeader: Data, section: Data) throws -> Data {
        let free: UInt32 = 0xFFFF_FFFF, end: UInt32 = 0xFFFF_FFFE, fatSect: UInt32 = 0xFFFF_FFFD
        guard section.count < 4096 else { throw BuildError() }

        // 작은 스트림: FileHeader 다음에 Section0 (각자 64바이트 단위로 채움)
        func padded(_ d: Data, to unit: Int) -> Data { d + Data(count: (unit - d.count % unit) % unit) }
        let headerMini = padded(fileHeader, to: 64), sectionMini = padded(section, to: 64)
        let miniStream = headerMini + sectionMini
        let headerMiniCount = headerMini.count / 64, totalMini = miniStream.count / 64
        var miniFat: [UInt32] = []
        for k in 0..<totalMini {
            miniFat.append(k == headerMiniCount - 1 || k == totalMini - 1 ? end : UInt32(k + 1))
        }
        guard miniFat.count <= 128 else { throw BuildError() }
        let miniStreamSectors = padded(miniStream, to: 512)
        let streamSectorCount = miniStreamSectors.count / 512

        var fat: [UInt32] = [fatSect, end, end]
        for k in 0..<streamSectorCount { fat.append(k == streamSectorCount - 1 ? end : UInt32(3 + k + 1)) }
        fat += Array(repeating: free, count: 128 - fat.count)

        func dirEntry(_ name: String, type: UInt8, left: UInt32 = free, right: UInt32 = free, child: UInt32 = free,
                      start: UInt32 = 0, size: Int = 0) -> Data {
            var e = name.utf16.reduce(into: Data()) { $0 += le16($1) } + le16(0)
            let nameBytes = e.count
            e += Data(count: 64 - e.count)
            e += le16(UInt16(nameBytes))
            e += Data([type, 1])                  // 종류, 색(검정)
            e += le32(left) + le32(right) + le32(child)
            e += Data(count: 116 - e.count)
            e += le32(start) + le32(UInt32(size)) + le32(0)
            return e
        }
        let directory = dirEntry("Root Entry", type: 5, child: 1, start: 3, size: miniStream.count)
            + dirEntry("FileHeader", type: 2, right: 2, start: 0, size: fileHeader.count)
            + dirEntry("BodyText", type: 1, child: 3)
            + dirEntry("Section0", type: 2, start: UInt32(headerMiniCount), size: section.count)

        var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 16)
        header += le16(0x3E) + le16(3) + le16(0xFFFE) + le16(9) + le16(6)
        header += Data(count: 10)
        header += le32(1) + le32(1) + le32(0) + le32(4096) + le32(2) + le32(1) + le32(end) + le32(0)
        header += le32(0)
        for _ in 1..<109 { header += le32(free) }

        return header
            + fat.reduce(into: Data()) { $0 += le32($1) }
            + directory
            + (miniFat + Array(repeating: free, count: 128 - miniFat.count)).reduce(into: Data()) { $0 += le32($1) }
            + miniStreamSectors
    }

    static func deflate(_ input: Data) throws -> Data {
        let capacity = input.count + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let n = input.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, capacity, base, input.count, nil, COMPRESSION_ZLIB)
        }
        guard n > 0 else { throw BuildError() }
        return Data(bytes: dst, count: n)
    }

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) }) }
}
