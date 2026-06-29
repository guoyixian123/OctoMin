// OMZFormat.swift
// MyCompressCore - Custom .omz archive format definitions
// Target: macOS 13+

import Foundation
import Compression

// MARK: - Magic Number & Version

/// OMZ 文件魔数: "OMZ1" (ASCII: 0x4F 0x4D 0x5A 0x31)
public let OMZMagicNumber: UInt32 = 0x315A4D4F  // Little-endian: "OMZ1"

/// OMZ 格式版本
public let OMZFormatVersion: UInt16 = 1

// MARK: - Flags

/// 文件头标志位
public struct OMZFlags: OptionSet, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// 启用 AES-256-GCM 加密
    public static let encrypted = OMZFlags(rawValue: 1 << 0)
    /// 使用固实压缩 (solid archive)
    public static let solid = OMZFlags(rawValue: 1 << 1)
}

// MARK: - Compression Algorithm

/// 支持的压缩算法
public enum OMZCompressionAlgorithm: UInt8, Sendable, CaseIterable {
    case lz4 = 0
    case zstd = 1
    case lzma = 2

    /// 显示名称
    public var displayName: String {
        switch self {
        case .lz4: return "LZ4"
        case .zstd: return "ZSTD"
        case .lzma: return "LZMA"
        }
    }

    /// 映射到 Apple Compression 算法常量
    /// 使用 Apple Compression 框架: LZ4 / LZFSE / LZMA
    public var compressionAlgorithm: compression_algorithm {
        switch self {
        case .lz4: return COMPRESSION_LZ4
        case .zstd: return COMPRESSION_LZFSE
        case .lzma: return COMPRESSION_LZMA
        }
    }
}

// MARK: - File Header (固定 64 字节)

/// OMZ 文件头结构
/// - magic: 4 bytes ("OMZ1")
/// - version: 2 bytes (uint16)
/// - flags: 2 bytes (uint16)
/// - algorithm: 1 byte (uint8)
/// - reserved: 1 byte
/// - blockSize: 4 bytes (uint32)
/// - fileCount: 4 bytes (uint32)
/// - tableOffset: 8 bytes (uint64)  - 文件表在文件中的偏移
/// - dataOffset: 8 bytes (uint64)   - 数据区起始偏移
/// - reserved2: 30 bytes
public struct OMZFileHeader: Sendable {
    public static let size: Int = 64

    public var magic: UInt32
    public var version: UInt16
    public var flags: OMZFlags
    public var algorithm: OMZCompressionAlgorithm
    public var blockSize: UInt32
    public var fileCount: UInt32
    public var tableOffset: UInt64
    public var dataOffset: UInt64

    public init(
        flags: OMZFlags = [],
        algorithm: OMZCompressionAlgorithm = .zstd,
        blockSize: UInt32 = 1 << 20,  // 默认 1MB
        fileCount: UInt32 = 0,
        tableOffset: UInt64 = 0,
        dataOffset: UInt64 = 0
    ) {
        self.magic = OMZMagicNumber
        self.version = OMZFormatVersion
        self.flags = flags
        self.algorithm = algorithm
        self.blockSize = blockSize
        self.fileCount = fileCount
        self.tableOffset = tableOffset
        self.dataOffset = dataOffset
    }

    /// 验证魔数是否有效
    public func isValidMagic() -> Bool {
        magic == OMZMagicNumber
    }

    /// 是否加密
    public var isEncrypted: Bool {
        flags.contains(.encrypted)
    }

    /// 是否固实压缩
    public var isSolid: Bool {
        flags.contains(.solid)
    }
}

// MARK: - File Entry Metadata

/// OMZ 文件条目元数据
public struct OMZFileEntry: Sendable {
    /// 相对路径 (以 UTF-8 存储)
    public let path: String
    /// 原始未压缩大小
    public let uncompressedSize: UInt64
    /// 压缩后大小 (所有块之和)
    public let compressedSize: UInt64
    /// 数据区中的起始偏移 (相对于 dataOffset)
    public let dataOffset: UInt64
    /// Unix 文件权限 (如 0o644, 0o755)
    public let permissions: UInt16
    /// 是否为目录
    public let isDirectory: Bool
    /// 原始数据 CRC32 校验值
    public let crc32: UInt32
    /// 该文件的块数量
    public let blockCount: UInt32
    /// 块大小 (最后一个块可能更小)
    public let blockSize: UInt32
    /// 每个块的压缩大小 (用于随机访问)
    public let blockCompressedSizes: [UInt32]

    public init(
        path: String,
        uncompressedSize: UInt64,
        compressedSize: UInt64,
        dataOffset: UInt64,
        permissions: UInt16,
        isDirectory: Bool,
        crc32: UInt32,
        blockCount: UInt32,
        blockSize: UInt32,
        blockCompressedSizes: [UInt32]
    ) {
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.compressedSize = compressedSize
        self.dataOffset = dataOffset
        self.permissions = permissions
        self.isDirectory = isDirectory
        self.crc32 = crc32
        self.blockCount = blockCount
        self.blockSize = blockSize
        self.blockCompressedSizes = blockCompressedSizes
    }
}

// MARK: - Block Structure

/// OMZ 压缩块
public struct OMZBlock: Sendable {
    /// 块索引
    public let index: Int
    /// 原始数据 (压缩前)
    public let rawData: Data
    /// 压缩后数据
    public var compressedData: Data?
    /// 原始数据 CRC32
    public let crc32: UInt32

    public init(index: Int, rawData: Data, crc32: UInt32) {
        self.index = index
        self.rawData = rawData
        self.crc32 = crc32
    }
}

// MARK: - Binary Encoding / Decoding

public extension OMZFileHeader {
    /// 序列化为二进制数据
    func serialize() -> Data {
        var data = Data(count: OMZFileHeader.size)
        var offset = 0

        func write<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            let size = MemoryLayout<T>.size
            withUnsafeBytes(of: &v) { ptr in
                data.replaceSubrange(offset..<offset+size, with: ptr)
            }
            offset += size
        }

        write(magic)                    // 0: 4 bytes
        write(version)                  // 4: 2 bytes
        write(flags.rawValue)           // 6: 2 bytes
        write(algorithm.rawValue)       // 8: 1 byte
        data[9] = 0                     // 9: 1 byte reserved
        offset = 10                     // advance past reserved byte
        write(blockSize)                // 10: 4 bytes
        write(fileCount)                // 14: 4 bytes
        write(tableOffset)              // 18: 8 bytes
        write(dataOffset)               // 26: 8 bytes
        // 34..<64: 30 bytes reserved (zeroed)

        return data
    }

    /// 从二进制数据反序列化
    static func deserialize(from data: Data) throws -> OMZFileHeader {
        guard data.count >= OMZFileHeader.size else {
            throw OMZFormatError.invalidHeaderSize(expected: OMZFileHeader.size, actual: data.count)
        }

        var offset = 0

        func read<T: FixedWidthInteger>() -> T {
            let size = MemoryLayout<T>.size
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { ptr in
                let bytes = data.subdata(in: offset..<offset+size)
                ptr.copyBytes(from: bytes)
            }
            offset += size
            return T(littleEndian: value)
        }

        let magic: UInt32 = read()
        let version: UInt16 = read()
        let flagsRaw: UInt16 = read()
        let algoRaw: UInt8 = read()

        guard magic == OMZMagicNumber else {
            throw OMZFormatError.invalidMagicNumber(magic)
        }

        guard version <= OMZFormatVersion else {
            throw OMZFormatError.unsupportedVersion(version)
        }

        guard let algorithm = OMZCompressionAlgorithm(rawValue: algoRaw) else {
            throw OMZFormatError.unsupportedAlgorithm(algoRaw)
        }

        offset = 10 // skip 1 byte reserved at position 9
        let blockSize: UInt32 = read()
        let fileCount: UInt32 = read()
        let tableOffset: UInt64 = read()
        let dataOffset: UInt64 = read()

        return OMZFileHeader(
            flags: OMZFlags(rawValue: flagsRaw),
            algorithm: algorithm,
            blockSize: blockSize,
            fileCount: fileCount,
            tableOffset: tableOffset,
            dataOffset: dataOffset
        )
    }
}

// MARK: - File Table Serialization

/// 文件表编码:
/// 对于每个文件条目:
///   - pathLength: UInt16
///   - pathUTF8: pathLength bytes
///   - uncompressedSize: UInt64
///   - compressedSize: UInt64
///   - dataOffset: UInt64
///   - permissions: UInt16
///   - flags: UInt8  (bit0 = isDirectory)
///   - crc32: UInt32
///   - blockCount: UInt32
///   - blockSize: UInt32
///   - blockCompressedSizes: blockCount * UInt32
public extension OMZFileEntry {
    func serialize() -> Data {
        var data = Data()
        let pathData = Array(path.utf8)

        // pathLength + path
        withUnsafeBytes(of: UInt16(pathData.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: pathData)

        func write<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        write(uncompressedSize)
        write(compressedSize)
        write(dataOffset)
        write(permissions)
        let flags: UInt8 = isDirectory ? 1 : 0
        data.append(flags)
        write(crc32)
        write(blockCount)
        write(blockSize)
        for size in blockCompressedSizes {
            write(size)
        }

        return data
    }

    static func deserialize(from data: Data) throws -> (entry: OMZFileEntry, bytesConsumed: Int) {
        var offset = 0

        func read<T: FixedWidthInteger>() -> T {
            let size = MemoryLayout<T>.size
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { ptr in
                let bytes = data.subdata(in: offset..<offset+size)
                ptr.copyBytes(from: bytes)
            }
            offset += size
            return T(littleEndian: value)
        }

        let pathLength: UInt16 = read()
        guard offset + Int(pathLength) <= data.count else {
            throw OMZFormatError.truncatedFileTable
        }
        let pathData = data.subdata(in: offset..<offset+Int(pathLength))
        offset += Int(pathLength)
        guard let path = String(data: pathData, encoding: .utf8) else {
            throw OMZFormatError.invalidPathEncoding
        }

        let uncompressedSize: UInt64 = read()
        let compressedSize: UInt64 = read()
        let entryDataOffset: UInt64 = read()
        let permissions: UInt16 = read()
        let flags: UInt8 = data[offset]; offset += 1
        let isDirectory = (flags & 1) != 0
        let crc32: UInt32 = read()
        let blockCount: UInt32 = read()
        let blockSize: UInt32 = read()

        var blockSizes = [UInt32]()
        blockSizes.reserveCapacity(Int(blockCount))
        for _ in 0..<blockCount {
            blockSizes.append(read())
        }

        let entry = OMZFileEntry(
            path: path,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            dataOffset: entryDataOffset,
            permissions: permissions,
            isDirectory: isDirectory,
            crc32: crc32,
            blockCount: blockCount,
            blockSize: blockSize,
            blockCompressedSizes: blockSizes
        )
        return (entry, offset)
    }
}

/// 序列化整个文件表
public func serializeFileTable(_ entries: [OMZFileEntry]) -> Data {
    var table = Data()
    for entry in entries {
        table.append(entry.serialize())
    }
    return table
}

/// 反序列化整个文件表
public func deserializeFileTable(from data: Data, count: Int) throws -> [OMZFileEntry] {
    var entries = [OMZFileEntry]()
    entries.reserveCapacity(count)
    var offset = 0
    let total = data.count
    for _ in 0..<count {
        let subdata = data.subdata(in: offset..<total)
        let (entry, consumed) = try OMZFileEntry.deserialize(from: subdata)
        entries.append(entry)
        offset += consumed
    }
    return entries
}

// MARK: - CRC32

/// CRC32 计算 (IEEE 802.3 多项式)
public enum OMZCRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0)
            }
            table[i] = crc
        }
        return table
    }()

    /// 计算数据的 CRC32 值
    public static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[idx]
        }
        return crc ^ 0xFFFFFFFF
    }

    /// 增量计算: 返回新的 CRC 值
    public static func update(crc: UInt32, data: Data) -> UInt32 {
        var c = crc ^ 0xFFFFFFFF
        for byte in data {
            let idx = Int((c ^ UInt32(byte)) & 0xFF)
            c = (c >> 8) ^ table[idx]
        }
        return c ^ 0xFFFFFFFF
    }
}

// MARK: - Errors

/// OMZ 格式相关错误
public enum OMZFormatError: Error, Sendable, LocalizedError {
    case invalidHeaderSize(expected: Int, actual: Int)
    case invalidMagicNumber(UInt32)
    case unsupportedAlgorithm(UInt8)
    case truncatedFileTable
    case invalidPathEncoding
    case crcMismatch(expected: UInt32, actual: UInt32)
    case unsupportedVersion(UInt16)
    case fileNotFound(String)
    case writeError(String)
    case readError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeaderSize(let expected, let actual):
            return "OMZ 文件头大小无效: 期望 \(expected) 字节, 实际 \(actual) 字节"
        case .invalidMagicNumber(let magic):
            return "无效的魔数: 0x\(String(magic, radix: 16))"
        case .unsupportedAlgorithm(let raw):
            return "不支持的压缩算法: \(raw)"
        case .truncatedFileTable:
            return "文件表数据截断"
        case .invalidPathEncoding:
            return "文件路径编码无效 (非 UTF-8)"
        case .crcMismatch(let expected, let actual):
            return "CRC32 校验失败: 期望 \(expected), 实际 \(actual)"
        case .unsupportedVersion(let v):
            return "不支持的 OMZ 版本: \(v)"
        case .fileNotFound(let path):
            return "文件未找到: \(path)"
        case .writeError(let msg):
            return "写入错误: \(msg)"
        case .readError(let msg):
            return "读取错误: \(msg)"
        }
    }
}
