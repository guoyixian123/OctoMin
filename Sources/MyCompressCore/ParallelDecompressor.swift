// ParallelDecompressor.swift
// MyCompressCore - Multi-threaded parallel decompressor
// Target: macOS 13+

import Foundation
import Compression

// MARK: - Decompression Progress

/// 解压进度报告
public struct MCZDecompressionProgress: Sendable {
    /// 已处理文件数
    public let filesProcessed: Int
    /// 总文件数
    public let totalFiles: Int
    /// 已解压字节数 (解压后)
    public let bytesProcessed: Int64
    /// 总解压字节数
    public let totalBytes: Int64
    /// 当前正在解压的文件路径
    public let currentFile: String?
    /// 是否完成
    public let isFinished: Bool

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesProcessed) / Double(totalBytes)
    }

    public init(
        filesProcessed: Int,
        totalFiles: Int,
        bytesProcessed: Int64,
        totalBytes: Int64,
        currentFile: String?,
        isFinished: Bool = false
    ) {
        self.filesProcessed = filesProcessed
        self.totalFiles = totalFiles
        self.bytesProcessed = bytesProcessed
        self.totalBytes = totalBytes
        self.currentFile = currentFile
        self.isFinished = isFinished
    }
}

// MARK: - Decompression Options

/// 解压选项
public struct MCZDecompressionOptions: Sendable {
    /// 密码 (用于加密档案)
    public var password: String?
    /// 最大并发任务数 (0 = 自动)
    public var maxConcurrency: Int
    /// 是否恢复文件权限
    public var restorePermissions: Bool
    /// 是否覆盖已存在文件
    public var overwriteExisting: Bool
    /// 是否验证 CRC32
    public var verifyCRC: Bool

    public init(
        password: String? = nil,
        maxConcurrency: Int = 0,
        restorePermissions: Bool = true,
        overwriteExisting: Bool = false,
        verifyCRC: Bool = true
    ) {
        self.password = password
        self.maxConcurrency = maxConcurrency
        self.restorePermissions = restorePermissions
        self.overwriteExisting = overwriteExisting
        self.verifyCRC = verifyCRC
    }

    public var effectiveConcurrency: Int {
        if maxConcurrency > 0 { return maxConcurrency }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}

// MARK: - Archive Info

/// MCZ 档案元信息 (可用于列出内容)
public struct MCZArchiveInfo: Sendable {
    public let header: MCZFileHeader
    public let entries: [MCZFileEntry]
    /// 总未压缩大小
    public let totalUncompressedSize: UInt64
    /// 总压缩大小
    public let totalCompressedSize: UInt64
    /// 压缩比
    public var compressionRatio: Double {
        guard totalUncompressedSize > 0 else { return 0 }
        return Double(totalCompressedSize) / Double(totalUncompressedSize)
    }
}

// MARK: - Parallel Decompressor

/// 多线程并行解压器
/// 使用 Swift Concurrency 并行解压文件, 支持可选解密和权限恢复
public actor ParallelDecompressor {
    /// 解压选项
    private let options: MCZDecompressionOptions

    /// 进度回调
    public typealias ProgressHandler = @Sendable (MCZDecompressionProgress) -> Void
    private let progressHandler: ProgressHandler?

    /// 进度统计
    private var bytesProcessed: Int64 = 0
    private var filesProcessed: Int = 0

    /// 初始化并行解压器
    public init(
        options: MCZDecompressionOptions = MCZDecompressionOptions(),
        progressHandler: ProgressHandler? = nil
    ) {
        self.options = options
        self.progressHandler = progressHandler
    }

    // MARK: - Public API: Read Archive Info

    /// 读取 MCZ 档案信息 (不解压)
    public static func readArchiveInfo(archiveURL: URL) throws -> MCZArchiveInfo {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        // 读取文件头
        let headerData = try readExact(handle: handle, count: MCZFileHeader.size, from: 0)
        let header = try MCZFileHeader.deserialize(from: headerData)

        // 读取文件表大小 (文件末尾 8 bytes)
        let fileSize = try handle.seekToEnd()
        let tableSizeOffset = fileSize - 8
        let tableSizeData = try readExact(handle: handle, count: 8, from: tableSizeOffset)
        var tableSize: UInt64 = 0
        withUnsafeMutableBytes(of: &tableSize) { ptr in
            ptr.copyBytes(from: tableSizeData.prefix(8))
        }
        tableSize = UInt64(littleEndian: tableSize)

        // 读取文件表
        let tableStart = Int(header.tableOffset)
        let tableData = try Self.readExact(handle: handle, count: Int(tableSize), from: UInt64(tableStart))

        // 如果加密, 需要密码才能读取文件表
        if header.isEncrypted {
            // 文件表也被加密, 但我们没有密码, 返回仅含头部的信息
            return MCZArchiveInfo(
                header: header,
                entries: [],
                totalUncompressedSize: 0,
                totalCompressedSize: 0
            )
        }

        let entries = try deserializeFileTable(from: tableData, count: Int(header.fileCount))

        let totalUncompressed = entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        let totalCompressed = entries.reduce(UInt64(0)) { $0 + $1.compressedSize }

        return MCZArchiveInfo(
            header: header,
            entries: entries,
            totalUncompressedSize: totalUncompressed,
            totalCompressedSize: totalCompressed
        )
    }

    // MARK: - Public API: Extract

    /// 解压 .mcz 文件到目标目录
    /// - Parameters:
    ///   - archiveURL: .mcz 档案路径
    ///   - destinationURL: 目标解压目录
    public func extract(archive archiveURL: URL, to destinationURL: URL) async throws {
        bytesProcessed = 0
        filesProcessed = 0

        let fileMgr = FileManager.default

        // 确保目标目录存在
        try fileMgr.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        // 1. 读取文件头
        let headerData = try Self.readExact(handle: handle, count: MCZFileHeader.size, from: 0)
        let header = try MCZFileHeader.deserialize(from: headerData)

        guard header.version == MCZFormatVersion else {
            throw MCZFormatError.unsupportedVersion(header.version)
        }

        // 2. 初始化加密引擎
        let crypto: CryptoEngine?
        let masterSalt: Data?
        if header.isEncrypted {
            guard let password = options.password else {
                throw CryptoError.decryptionFailed("档案已加密, 需要提供密码")
            }
            crypto = CryptoEngine(password: password)
            // masterSalt 紧接在 header 之后 (64 字节开始, 16 字节)
            let saltOffset = UInt64(MCZFileHeader.size)
            masterSalt = try Self.readExact(handle: handle, count: MCZEncryptedData.saltSize, from: saltOffset)
            _ = try await crypto!.deriveKey(salt: masterSalt!) // pre-derive
        } else {
            crypto = nil
            masterSalt = nil
        }

        // 数据区绝对起始位置 = header.dataOffset (由压缩器写入, 已包含 salt 偏移)
        let dataSectionAbsStart = header.dataOffset

        // 3. 读取文件表大小 (最后 8 字节)
        let fileSize = try handle.seekToEnd()
        let tableSizeOffset = fileSize - 8
        let tableSizeData = try Self.readExact(handle: handle, count: 8, from: tableSizeOffset)
        var tableSize: UInt64 = 0
        withUnsafeMutableBytes(of: &tableSize) { ptr in
            ptr.copyBytes(from: tableSizeData.prefix(8))
        }
        tableSize = UInt64(littleEndian: tableSize)

        // 4. 读取文件表
        let tableAbsOffset = header.tableOffset
        var tableRawData = try Self.readExact(handle: handle, count: Int(tableSize), from: tableAbsOffset)

        if let crypto = crypto, let salt = masterSalt {
            // 解密文件表: nonce(12) + ciphertext+tag
            let nonceData = tableRawData.prefix(MCZEncryptedData.nonceSize)
            let encTableData = tableRawData.subdata(in: MCZEncryptedData.nonceSize..<tableRawData.count)
            tableRawData = try await crypto.decryptBlock(encTableData, salt: salt, nonce: Data(nonceData))
        }

        let entries = try deserializeFileTable(from: tableRawData, count: Int(header.fileCount))

        let totalUncompressed = entries.reduce(Int64(0)) { $0 + Int64($1.uncompressedSize) }
        let totalFiles = entries.count

        // 报告初始进度
        reportProgress(totalFiles: totalFiles, totalBytes: totalUncompressed, currentFile: nil)

        // 5. 创建所有目录 (按顺序, 先于文件写入)
        // 先建目录以确保文件写入时父目录存在
        let directories = entries.filter { $0.isDirectory }
        for dirEntry in directories {
            let dirURL = destinationURL.appendingPathComponent(dirEntry.path)
            try fileMgr.createDirectory(at: dirURL, withIntermediateDirectories: true)
            if options.restorePermissions {
                try? Self.applyPermissions(dirEntry.permissions, to: dirURL)
            }
        }
        // 目录已处理, 计入进度
        filesProcessed = directories.count

        // 6. 并行解压所有文件
        let fileEntries = entries.filter { !$0.isDirectory }
        let concurrency = options.effectiveConcurrency
        let compressionEngine = CompressionEngine(algorithm: header.algorithm)

        try await withThrowingTaskGroup(of: Int64.self) { group in
            var submitted = 0
            var inFlight = 0

            func submitNext() {
                guard submitted < fileEntries.count else { return }
                let entry = fileEntries[submitted]
                submitted += 1
                inFlight += 1

                group.addTask { [options] in
                    // 计算该条目在文件中的绝对偏移
                    let absOffset = dataSectionAbsStart + entry.dataOffset

                    // 读取压缩数据
                    // 注意: FileHandle 不是 Sendable, 这里需要在 Task 内独立打开文件
                    let entryHandle = try FileHandle(forReadingFrom: archiveURL)
                    defer { try? entryHandle.close() }

                    var compressedData = try Self.readExact(
                        handle: entryHandle,
                        count: Int(entry.compressedSize),
                        from: absOffset
                    )

                    // 如果加密, 解密
                    if let crypto = crypto, let salt = masterSalt {
                        let nonceData = compressedData.prefix(MCZEncryptedData.nonceSize)
                        let encData = compressedData.subdata(in: MCZEncryptedData.nonceSize..<compressedData.count)
                        compressedData = try await crypto.decryptBlock(encData, salt: salt, nonce: Data(nonceData))
                    }

                    // 分块解压
                    let uncompressedSize = Int(entry.uncompressedSize)
                    var decompressed = Data(capacity: uncompressedSize)

                    if entry.blockCount > 1 {
                        // 多块并行解压
                        let blockSizes = entry.blockCompressedSizes
                        var blockDatas = [Data]()
                        blockDatas.reserveCapacity(Int(entry.blockCount))

                        // 分割 compressedData 为各块
                        var boffset = 0
                        for bs in blockSizes {
                            let end = boffset + Int(bs)
                            blockDatas.append(compressedData.subdata(in: boffset..<end))
                            boffset = end
                        }

                        var results = [Data?](repeating: nil, count: blockDatas.count)

                        // 计算每个块的未压缩大小 (最后一个块可能不同)
                        let normalBlockSize = Int(entry.blockSize)

                        try await withThrowingTaskGroup(of: (Int, Data).self) { blockGroup in
                            var blockSubmitted = 0

                            func submitBlock() {
                                guard blockSubmitted < blockDatas.count else { return }
                                let bidx = blockSubmitted
                                let cblock = blockDatas[bidx]

                                // 计算该块的未压缩大小
                                let isLast = (bidx == blockDatas.count - 1)
                                let blockRawSize: Int
                                if isLast {
                                    let totalBlocks = blockDatas.count
                                    let prevTotal = (totalBlocks - 1) * normalBlockSize
                                    blockRawSize = uncompressedSize - prevTotal
                                } else {
                                    blockRawSize = normalBlockSize
                                }

                                blockSubmitted += 1

                                blockGroup.addTask {
                                    let engine = CompressionEngine(algorithm: header.algorithm)
                                    let data = try engine.decompress(cblock, uncompressedSize: blockRawSize)
                                    return (bidx, data)
                                }
                            }

                            for _ in 0..<min(concurrency, blockDatas.count) {
                                submitBlock()
                            }

                            for try await (bidx, ddata) in blockGroup {
                                results[bidx] = ddata
                                submitBlock()
                            }
                        }

                        for maybeData in results {
                            guard let d = maybeData else {
                                throw CompressionError.decompressionFailed(
                                    algorithm: header.algorithm.displayName,
                                    message: "块数据丢失"
                                )
                            }
                            decompressed.append(d)
                        }
                    } else {
                        // 单块解压
                        if !compressedData.isEmpty {
                            decompressed = try compressionEngine.decompress(compressedData, uncompressedSize: uncompressedSize)
                        }
                    }

                    // CRC 校验
                    if options.verifyCRC {
                        let actualCRC = MCZCRC32.compute(decompressed)
                        guard actualCRC == entry.crc32 else {
                            throw MCZFormatError.crcMismatch(expected: entry.crc32, actual: actualCRC)
                        }
                    }

                    // 写入文件
                    let outURL = destinationURL.appendingPathComponent(entry.path)

                    // 确保父目录存在
                    let parentDir = outURL.deletingLastPathComponent()
                    try fileMgr.createDirectory(at: parentDir, withIntermediateDirectories: true)

                    // 检查是否覆盖
                    if fileMgr.fileExists(atPath: outURL.path) {
                        if options.overwriteExisting {
                            try? fileMgr.removeItem(at: outURL)
                        } else {
                            throw MCZFormatError.writeError("文件已存在且未启用覆盖: \(entry.path)")
                        }
                    }

                    // 写入
                    try decompressed.write(to: outURL, options: .atomic)

                    // 恢复权限
                    if options.restorePermissions {
                        try? Self.applyPermissions(entry.permissions, to: outURL)
                    }

                    return Int64(uncompressedSize)
                }
            }

            for _ in 0..<min(concurrency, fileEntries.count) {
                submitNext()
            }

            for try await bytes in group {
                inFlight -= 1
                filesProcessed += 1
                bytesProcessed += bytes
                reportProgress(totalFiles: totalFiles, totalBytes: totalUncompressed, currentFile: nil)
                submitNext()
            }
        }

        // 报告完成
        progressHandler?(MCZDecompressionProgress(
            filesProcessed: totalFiles,
            totalFiles: totalFiles,
            bytesProcessed: totalUncompressed,
            totalBytes: totalUncompressed,
            currentFile: nil,
            isFinished: true
        ))
    }

    // MARK: - List Contents (for encrypted archives)

    /// 列出加密档案内容 (需要密码)
    public func listContents(archive archiveURL: URL) async throws -> [MCZFileEntry] {
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        let headerData = try Self.readExact(handle: handle, count: MCZFileHeader.size, from: 0)
        let header = try MCZFileHeader.deserialize(from: headerData)

        let crypto: CryptoEngine?
        let masterSalt: Data?
        if header.isEncrypted {
            guard let password = options.password else {
                throw CryptoError.decryptionFailed("档案已加密, 需要密码")
            }
            crypto = CryptoEngine(password: password)
            masterSalt = try Self.readExact(handle: handle, count: MCZEncryptedData.saltSize, from: UInt64(MCZFileHeader.size))
            _ = try await crypto!.deriveKey(salt: masterSalt!)
        } else {
            crypto = nil
            masterSalt = nil
        }

        let fileSize = try handle.seekToEnd()
        let tableSizeOffset = fileSize - 8
        let tableSizeData = try Self.readExact(handle: handle, count: 8, from: tableSizeOffset)
        var tableSize: UInt64 = 0
        withUnsafeMutableBytes(of: &tableSize) { ptr in
            ptr.copyBytes(from: tableSizeData.prefix(8))
        }
        tableSize = UInt64(littleEndian: tableSize)

        var tableRawData = try Self.readExact(handle: handle, count: Int(tableSize), from: header.tableOffset)

        if let crypto = crypto, let salt = masterSalt {
            let nonceData = tableRawData.prefix(MCZEncryptedData.nonceSize)
            let encData = tableRawData.subdata(in: MCZEncryptedData.nonceSize..<tableRawData.count)
            tableRawData = try await crypto.decryptBlock(encData, salt: salt, nonce: Data(nonceData))
        }

        return try deserializeFileTable(from: tableRawData, count: Int(header.fileCount))
    }

    // MARK: - Helpers

    /// 从 FileHandle 指定偏移精确读取 count 字节
    private static func readExact(handle: FileHandle, count: Int, from offset: UInt64) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: count)
        guard data.count == count else {
            throw MCZFormatError.readError("无法读取足够数据: 期望 \(count) 字节, 实际 \(data.count) 字节")
        }
        return data
    }

    /// 应用 Unix 文件权限
    private static func applyPermissions(_ permissions: UInt16, to url: URL) throws {
        let fileMgr = FileManager.default
        try fileMgr.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
    }

    /// 报告进度
    private func reportProgress(totalFiles: Int, totalBytes: Int64, currentFile: String?) {
        let progress = MCZDecompressionProgress(
            filesProcessed: filesProcessed,
            totalFiles: totalFiles,
            bytesProcessed: bytesProcessed,
            totalBytes: totalBytes,
            currentFile: currentFile
        )
        progressHandler?(progress)
    }
}
