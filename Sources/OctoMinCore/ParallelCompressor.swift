// ParallelCompressor.swift
// MyCompressCore - Multi-threaded parallel compressor
// Target: macOS 13+

import Foundation
import Compression
import CryptoKit

// MARK: - Compression Progress

/// 压缩进度报告
public struct OMZCompressionProgress: Sendable {
    /// 已处理的文件数
    public let filesProcessed: Int
    /// 总文件数
    public let totalFiles: Int
    /// 已处理的未压缩字节数
    public let bytesProcessed: Int64
    /// 总未压缩字节数
    public let totalBytes: Int64
    /// 当前正在处理的文件路径
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

// MARK: - Compression Options

/// 压缩选项
public struct OMZCompressionOptions: Sendable {
    /// 压缩算法
    public var algorithm: OMZCompressionAlgorithm
    /// 压缩级别
    public var level: OMZCompressionLevel
    /// 块大小 (用于并行分块压缩)
    public var blockSize: Int
    /// 最大并发任务数 (0 = 自动, 使用处理器核心数)
    public var maxConcurrency: Int
    /// 密码 (nil = 不加密)
    public var password: String?
    /// 是否保留文件权限
    public var preservePermissions: Bool

    public init(
        algorithm: OMZCompressionAlgorithm = .zstd,
        level: OMZCompressionLevel = .default,
        blockSize: Int = 1 << 20,  // 1MB
        maxConcurrency: Int = 0,
        password: String? = nil,
        preservePermissions: Bool = true
    ) {
        self.algorithm = algorithm
        self.level = level
        self.blockSize = blockSize
        self.maxConcurrency = maxConcurrency
        self.password = password
        self.preservePermissions = preservePermissions
    }

    /// 有效并发数
    public var effectiveConcurrency: Int {
        if maxConcurrency > 0 { return maxConcurrency }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}

// MARK: - Internal Data Types

/// 内部使用: 文件收集信息
private struct FileInfo: Sendable {
    let url: URL
    let relativePath: String
    let fileSize: Int64
    let permissions: UInt16
    let isDirectory: Bool
}

/// 内部使用: 压缩后的文件数据
private struct CompressedFile: Sendable {
    let info: FileInfo
    let data: Data  // 压缩后的原始字节 (尚未写入)
    let crc32: UInt32
    let blockSizes: [UInt32]
    let uncompressedSize: UInt64
}

// MARK: - Parallel Compressor

/// 多线程并行压缩器
/// 使用 Swift Concurrency (TaskGroup) 进行文件级和块级并行压缩
public actor ParallelCompressor {
    /// 压缩选项
    private let options: OMZCompressionOptions

    /// 进度回调 (在 actor 上调用, 线程安全)
    public typealias ProgressHandler = @Sendable (OMZCompressionProgress) -> Void
    private let progressHandler: ProgressHandler?

    /// 已处理字节数 (用于进度报告)
    private var bytesProcessed: Int64 = 0
    private var filesProcessed: Int = 0

    /// 初始化并行压缩器
    /// - Parameters:
    ///   - options: 压缩选项
    ///   - progressHandler: 进度回调
    public init(
        options: OMZCompressionOptions = OMZCompressionOptions(),
        progressHandler: ProgressHandler? = nil
    ) {
        self.options = options
        self.progressHandler = progressHandler
    }

    // MARK: - Public API: Compress Directory

    /// 压缩目录到 .omz 文件
    /// - Parameters:
    ///   - sourceURL: 源目录 URL
    ///   - destinationURL: 目标 .omz 文件 URL
    public func compressDirectory(source: URL, destination: URL) async throws {
        let files = try Self.collectFiles(from: source)
        try await compressFiles(files, sourceBase: source, destination: destination)
    }

    /// 压缩文件列表到 .omz 文件
    /// - Parameters:
    ///   - fileURLs: 源文件 URL 列表
    ///   - destinationURL: 目标 .omz 文件 URL
    ///   - baseURL: 计算相对路径的基础目录
    public func compressFiles(_ fileURLs: [URL], sourceBase: URL, destination: URL) async throws {
        // 重置进度
        bytesProcessed = 0
        filesProcessed = 0

        let fileMgr = FileManager.default

        var fileInfos: [FileInfo] = []
        var totalBytes: Int64 = 0

        for url in fileURLs {
            let attrs = try fileMgr.attributesOfItem(atPath: url.path)
            let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
            let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let posixPerms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let relPath = String(url.path.dropFirst(sourceBase.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            fileInfos.append(FileInfo(
                url: url,
                relativePath: relPath.isEmpty ? url.lastPathComponent : relPath,
                fileSize: fileSize,
                permissions: options.preservePermissions ? posixPerms : 0o644,
                isDirectory: isDir
            ))
            if !isDir { totalBytes += fileSize }
        }

        // 排序确保确定性输出
        fileInfos.sort { $0.relativePath < $1.relativePath }

        let totalFiles = fileInfos.count

        // 报告初始进度
        reportProgress(totalFiles: totalFiles, totalBytes: totalBytes, currentFile: nil)

        // 初始化加密引擎 (如果需要)
        let crypto: CryptoEngine?
        let masterSalt: Data?
        if let password = options.password {
            crypto = CryptoEngine(password: password)
            masterSalt = CryptoEngine.generateSalt()
        } else {
            crypto = nil
            masterSalt = nil
        }

        let concurrency = options.effectiveConcurrency

        // 使用有序数组保持结果顺序
        var compressedResults = [CompressedFile?](repeating: nil, count: fileInfos.count)

        try await withThrowingTaskGroup(of: (Int, CompressedFile).self) { group in
            var submitted = 0
            var inFlight = 0

            func submitNext() {
                guard submitted < fileInfos.count else { return }
                let idx = submitted
                let info = fileInfos[idx]
                submitted += 1
                inFlight += 1

                group.addTask { [options] in
                    let compressionEngine = CompressionEngine(algorithm: options.algorithm, level: options.level)

                    if info.isDirectory {
                        // 目录条目: 空数据
                        let emptyData = Data()
                        return (idx, CompressedFile(
                            info: info,
                            data: emptyData,
                            crc32: OMZCRC32.compute(emptyData),
                            blockSizes: [],
                            uncompressedSize: 0
                        ))
                    }

                    // 读取文件数据
                    let fileData: Data
                    do {
                        fileData = try Data(contentsOf: info.url, options: .mappedIfSafe)
                    } catch {
                        throw OMZFormatError.readError("无法读取文件 \(info.url.path): \(error.localizedDescription)")
                    }

                    let fileCrc = OMZCRC32.compute(fileData)
                    let blockSize = options.blockSize

                    // 分块
                    let rawBlocks = self.splitIntoBlocks(fileData, blockSize: blockSize)

                    // 并行压缩块
                    var compressedBlocks = [Data?](repeating: nil, count: rawBlocks.count)

                    if rawBlocks.count <= 1 {
                        // 单块直接压缩
                        let compressed = try compressionEngine.compress(rawBlocks[0])
                        let result = CompressedFile(
                            info: info,
                            data: compressed,
                            crc32: fileCrc,
                            blockSizes: [UInt32(compressed.count)],
                            uncompressedSize: UInt64(fileData.count)
                        )
                        return (idx, result)
                    }

                    // 多块并行压缩
                    try await withThrowingTaskGroup(of: (Int, Data).self) { blockGroup in
                        var blockSubmitted = 0
                        var blockInFlight = 0

                        func submitBlock() {
                            guard blockSubmitted < rawBlocks.count else { return }
                            let bidx = blockSubmitted
                            let block = rawBlocks[bidx]
                            blockSubmitted += 1
                            blockInFlight += 1

                            blockGroup.addTask {
                                let engine = CompressionEngine(algorithm: options.algorithm, level: options.level)
                                let compressed = try engine.compress(block)
                                return (bidx, compressed)
                            }
                        }

                        // 初始提交
                        for _ in 0..<min(concurrency, rawBlocks.count) {
                            submitBlock()
                        }

                        for try await (bidx, cdata) in blockGroup {
                            compressedBlocks[bidx] = cdata
                            blockInFlight -= 1
                            submitBlock()
                        }
                    }

                    // 组装最终数据 (按顺序拼接)
                    var assembled = Data()
                    var sizes = [UInt32]()
                    sizes.reserveCapacity(compressedBlocks.count)
                    for (i, maybeBlock) in compressedBlocks.enumerated() {
                        guard let cblock = maybeBlock else {
                            throw CompressionError.compressionFailed(
                                algorithm: options.algorithm.displayName,
                                message: "块 \(i) 未成功压缩"
                            )
                        }
                        sizes.append(UInt32(cblock.count))
                        assembled.append(cblock)
                    }

                    return (idx, CompressedFile(
                        info: info,
                        data: assembled,
                        crc32: fileCrc,
                        blockSizes: sizes,
                        uncompressedSize: UInt64(fileData.count)
                    ))
                }
            }

            // 初始提交
            for _ in 0..<min(concurrency, fileInfos.count) {
                submitNext()
            }

            for try await (idx, result) in group {
                compressedResults[idx] = result

                inFlight -= 1
                filesProcessed += 1
                bytesProcessed += Int64(result.uncompressedSize)

                reportProgress(
                    totalFiles: totalFiles,
                    totalBytes: totalBytes,
                    currentFile: result.info.relativePath
                )

                submitNext()
            }
        }

        // 收集结果 (已按顺序)
        let compressedFiles = compressedResults.compactMap { $0 }

        // 第二阶段: 写入 OMZ 文件
        try await writeArchive(
            to: destination,
            compressedFiles: compressedFiles,
            crypto: crypto,
            masterSalt: masterSalt
        )

        // 报告完成
        progressHandler?(OMZCompressionProgress(
            filesProcessed: totalFiles,
            totalFiles: totalFiles,
            bytesProcessed: totalBytes,
            totalBytes: totalBytes,
            currentFile: nil,
            isFinished: true
        ))
    }

    // MARK: - Write Archive

    private func writeArchive(
        to destination: URL,
        compressedFiles: [CompressedFile],
        crypto: CryptoEngine?,
        masterSalt: Data?
    ) async throws {
        let fileMgr = FileManager.default

        // 如果目标文件已存在则删除
        if fileMgr.fileExists(atPath: destination.path) {
            try? fileMgr.removeItem(at: destination)
        }

        // 创建空文件
        fileMgr.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        // 占位: 文件头 (64 bytes, 后续回填)
        let headerPlaceholder = Data(count: OMZFileHeader.size)
        try handle.write(contentsOf: headerPlaceholder)

        // 写入加密头 (如果加密): masterSalt(16)
        if let salt = masterSalt {
            try handle.write(contentsOf: salt)
        }

        // dataSectionStart 是文件数据区在档案中的绝对偏移
        let dataSectionStart = try handle.offset()

        // 构建文件条目并写入数据区
        var entries = [OMZFileEntry]()
        entries.reserveCapacity(compressedFiles.count)

        // entry.dataOffset 是相对于 dataSectionStart 的偏移, 从 0 开始
        var currentEntryOffset: UInt64 = 0

        for cf in compressedFiles {
            var finalData: Data

            if let crypto = crypto, let salt = masterSalt, !cf.data.isEmpty {
                // 对文件的压缩数据进行加密
                // 每个文件使用独立 nonce, salt 复用 masterSalt
                let nonce = CryptoEngine.generateNonce()
                let encryptedBlock = try await crypto.encryptBlock(cf.data, salt: salt, nonce: nonce)
                // 存储格式: nonce(12) + encrypted(ciphertext+tag)
                var withNonce = Data()
                withNonce.append(nonce)
                withNonce.append(encryptedBlock)
                finalData = withNonce
            } else {
                finalData = cf.data
            }

            try handle.write(contentsOf: finalData)

            let entry = OMZFileEntry(
                path: cf.info.relativePath,
                uncompressedSize: cf.uncompressedSize,
                compressedSize: UInt64(finalData.count),
                dataOffset: currentEntryOffset,
                permissions: cf.info.permissions,
                isDirectory: cf.info.isDirectory,
                crc32: cf.crc32,
                blockCount: UInt32(cf.blockSizes.count),
                blockSize: UInt32(options.blockSize),
                blockCompressedSizes: cf.blockSizes
            )
            entries.append(entry)
            currentEntryOffset += UInt64(finalData.count)
        }

        // 写入文件表
        let tableOffset = try handle.offset()
        let tableData = serializeFileTable(entries)

        var tableToWrite = tableData
        if let crypto = crypto, let salt = masterSalt {
            let nonce = CryptoEngine.generateNonce()
            let encTable = try await crypto.encryptBlock(tableData, salt: salt, nonce: nonce)
            var withNonce = Data()
            withNonce.append(nonce)
            withNonce.append(encTable)
            tableToWrite = withNonce
        }
        try handle.write(contentsOf: tableToWrite)

        // 写入文件表大小 (8 bytes LE, 用于快速定位)
        var tableSize = UInt64(tableToWrite.count).littleEndian
        let tableSizeData = withUnsafeBytes(of: &tableSize) { Data($0) }
        try handle.write(contentsOf: tableSizeData)

        // 回填文件头
        let flags: OMZFlags = crypto != nil ? [.encrypted] : []
        let header = OMZFileHeader(
            flags: flags,
            algorithm: options.algorithm,
            blockSize: UInt32(options.blockSize),
            fileCount: UInt32(entries.count),
            tableOffset: UInt64(tableOffset),
            dataOffset: UInt64(dataSectionStart)
        )
        let headerData = header.serialize()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: headerData)
    }

    // MARK: - Helpers

    /// 将数据按 blockSize 分块 (纯函数, 不访问 actor 状态)
    nonisolated private func splitIntoBlocks(_ data: Data, blockSize: Int) -> [Data] {
        guard blockSize > 0 else { return [data] }
        let count = data.count
        guard count > blockSize else { return [data] }

        var blocks = [Data]()
        blocks.reserveCapacity((count + blockSize - 1) / blockSize)
        var offset = 0
        while offset < count {
            let end = min(offset + blockSize, count)
            blocks.append(data.subdata(in: offset..<end))
            offset = end
        }
        return blocks
    }

    /// 报告进度
    private func reportProgress(totalFiles: Int, totalBytes: Int64, currentFile: String?) {
        let progress = OMZCompressionProgress(
            filesProcessed: filesProcessed,
            totalFiles: totalFiles,
            bytesProcessed: bytesProcessed,
            totalBytes: totalBytes,
            currentFile: currentFile
        )
        progressHandler?(progress)
    }

    // MARK: - File Collection

    /// 递归收集目录下所有文件和目录
    public static func collectFiles(from directoryURL: URL) throws -> [URL] {
        let fileMgr = FileManager.default
        var results = [URL]()

        guard let enumerator = fileMgr.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw OMZFormatError.readError("无法枚举目录: \(directoryURL.path)")
        }

        // 包含根目录自身
        results.append(directoryURL)

        for case let url as URL in enumerator {
            results.append(url)
        }

        return results
    }
}
