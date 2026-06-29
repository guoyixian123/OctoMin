import Foundation

// MARK: - 支持的压缩输出格式
public enum OutputCompressionFormat: String, CaseIterable, Sendable {
    case omz = "omz"
    case zip = "zip"
    
    public var displayName: String {
        switch self {
        case .omz: return "OMZ"
        case .zip: return "ZIP"
        }
    }
    
    public var fileExtension: String { rawValue }
    
    public var description: String {
        switch self {
        case .omz:
            return "自定义格式，支持多线程压缩、AES-256加密"
        case .zip:
            return "通用格式，兼容性最好，所有系统都支持"
        }
    }
    
    public var supportsEncryption: Bool {
        switch self {
        case .omz: return true
        case .zip: return true // 使用zip -P 密码
        }
    }
    
    public var supportsMultiThreading: Bool {
        switch self {
        case .omz: return true
        case .zip: return false // 系统zip是单线程的
        }
    }
}

// MARK: - 压缩进度
public struct CompressionProgressInfo: Sendable {
    public let fractionCompleted: Double
    public let statusMessage: String
    public let filesProcessed: Int
    public let totalFiles: Int
    public let bytesProcessed: Int64
    public let totalBytes: Int64
    
    public init(fractionCompleted: Double, statusMessage: String, filesProcessed: Int = 0, totalFiles: Int = 0, bytesProcessed: Int64 = 0, totalBytes: Int64 = 0) {
        self.fractionCompleted = fractionCompleted
        self.statusMessage = statusMessage
        self.filesProcessed = filesProcessed
        self.totalFiles = totalFiles
        self.bytesProcessed = bytesProcessed
        self.totalBytes = totalBytes
    }
}

// MARK: - 通用压缩器
public final class UniversalCompressor: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (CompressionProgressInfo) -> Void
    
    public enum CompressionError: Error, LocalizedError, Sendable {
        case unsupportedFormat
        case toolNotFound(String)
        case compressionFailed(String, Int32)
        case cancelled
        case noInputFiles
        
        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "不支持的输出格式"
            case .toolNotFound(let tool):
                return "未找到压缩工具 \(tool)"
            case .compressionFailed(let message, let code):
                return "压缩失败 (code: \(code)): \(message)"
            case .cancelled:
                return "压缩已取消"
            case .noInputFiles:
                return "没有可压缩的文件"
            }
        }
    }
    
    public struct Options: Sendable {
        public var password: String?
        public var overwriteExisting: Bool
        public var maxConcurrency: Int // 0 = auto
        // OMZ specific
        public var omzAlgorithm: OMZCompressionAlgorithm
        public var omzLevel: OMZCompressionLevel
        public var omzBlockSize: Int
        // ZIP specific
        public var zipCompressionLevel: Int // 0-9
        
        public init(
            password: String? = nil,
            overwriteExisting: Bool = true,
            maxConcurrency: Int = 0,
            omzAlgorithm: OMZCompressionAlgorithm = .zstd,
            omzLevel: OMZCompressionLevel = .default,
            omzBlockSize: Int = 1024 * 1024,
            zipCompressionLevel: Int = 6
        ) {
            self.password = password
            self.overwriteExisting = overwriteExisting
            self.maxConcurrency = maxConcurrency
            self.omzAlgorithm = omzAlgorithm
            self.omzLevel = omzLevel
            self.omzBlockSize = omzBlockSize
            self.zipCompressionLevel = zipCompressionLevel
        }
    }
    
    private let progressHandler: ProgressHandler?
    
    public init(progressHandler: ProgressHandler? = nil) {
        self.progressHandler = progressHandler
    }
    
    // MARK: - 压缩
    public func compress(
        files: [URL],
        to destination: URL,
        format: OutputCompressionFormat,
        options: Options = Options()
    ) async throws {
        guard !files.isEmpty else {
            throw CompressionError.noInputFiles
        }
        
        // 处理覆盖
        if options.overwriteExisting {
            try? FileManager.default.removeItem(at: destination)
        } else if FileManager.default.fileExists(atPath: destination.path) {
            throw CompressionError.compressionFailed("目标文件已存在", -1)
        }
        
        switch format {
        case .omz:
            try await compressOMZ(files: files, to: destination, options: options)
        case .zip:
            try await compressZIP(files: files, to: destination, options: options)
        }
    }
    
    // MARK: - OMZ 压缩（我们自己的格式，多线程）
    private func compressOMZ(files: [URL], to destination: URL, options: Options) async throws {
        progressHandler?(CompressionProgressInfo(
            fractionCompleted: 0.05,
            statusMessage: "正在分析文件...",
            totalFiles: files.count
        ))
        
        // 确定源目录（对于单文件/文件夹）
        let sourceBase: URL
        let actualFiles: [URL]
        
        if files.count == 1 {
            sourceBase = files[0].deletingLastPathComponent()
            actualFiles = files
        } else {
            // 多个文件 - 使用共同父目录
            sourceBase = findCommonParentDirectory(of: files)
            actualFiles = files
        }
        
        let concurrency = options.maxConcurrency > 0 ? options.maxConcurrency : ProcessInfo.processInfo.activeProcessorCount
        
        let omzOptions = OMZCompressionOptions(
            algorithm: options.omzAlgorithm,
            level: options.omzLevel,
            blockSize: options.omzBlockSize,
            maxConcurrency: concurrency,
            password: options.password,
            preservePermissions: true
        )
        
        let handler = progressHandler
        let compressor = ParallelCompressor(options: omzOptions) { prog in
            let msg: String
            if let current = prog.currentFile {
                msg = "正在压缩 \(URL(fileURLWithPath: current).lastPathComponent)..."
            } else {
                msg = "正在压缩..."
            }
            handler?(CompressionProgressInfo(
                fractionCompleted: 0.1 + prog.fractionCompleted * 0.85,
                statusMessage: msg,
                filesProcessed: prog.filesProcessed,
                totalFiles: prog.totalFiles,
                bytesProcessed: prog.bytesProcessed,
                totalBytes: prog.totalBytes
            ))
        }
        
        // 确定输出路径
        let destDir = destination.deletingLastPathComponent()
        let destName = destination.deletingPathExtension().lastPathComponent
        let tempDest = destDir.appendingPathComponent(destName + ".omz.tmp")
        try? FileManager.default.removeItem(at: tempDest)
        
        if files.count == 1 && files[0].hasDirectoryPath {
            // 压缩单个目录
            try await compressor.compressDirectory(source: files[0], destination: tempDest)
        } else {
            // 压缩多个文件/目录
            try await compressor.compressFiles(actualFiles, sourceBase: sourceBase, destination: tempDest)
        }
        
        try FileManager.default.moveItem(at: tempDest, to: destination)
        
        progressHandler?(CompressionProgressInfo(
            fractionCompleted: 1.0,
            statusMessage: "压缩完成！",
            filesProcessed: files.count,
            totalFiles: files.count
        ))
    }
    
    // MARK: - ZIP 压缩（使用系统zip命令）
    private func compressZIP(files: [URL], to destination: URL, options: Options) async throws {
        progressHandler?(CompressionProgressInfo(
            fractionCompleted: 0.1,
            statusMessage: "正在压缩为ZIP...",
            totalFiles: files.count
        ))
        
        let zipTool: String
        if let found = UniversalExtractor.findTool(named: "zip") {
            zipTool = found
        } else {
            zipTool = "/usr/bin/zip"
        }
        
        guard FileManager.default.isExecutableFile(atPath: zipTool) else {
            throw CompressionError.toolNotFound("zip")
        }
        
        // 构建参数
        var args = ["-r", "-q"]
        
        // 压缩级别
        if options.zipCompressionLevel >= 0 && options.zipCompressionLevel <= 9 {
            args.append("-\(options.zipCompressionLevel)")
        }
        
        // 密码
        if let password = options.password, !password.isEmpty {
            args.append(contentsOf: ["-P", password])
        }
        
        // 符号链接
        args.append("-y")
        
        // 输出文件
        args.append(destination.path)
        
        // 要压缩的文件 - 使用相对路径
        let workDir: URL
        if files.count == 1 {
            workDir = files[0].deletingLastPathComponent()
            args.append(files[0].lastPathComponent)
        } else {
            workDir = findCommonParentDirectory(of: files)
            for file in files {
                let relPath = relativePath(from: workDir, to: file)
                args.append(relPath)
            }
        }
        
        progressHandler?(CompressionProgressInfo(
            fractionCompleted: 0.3,
            statusMessage: "正在压缩...",
            totalFiles: files.count
        ))
        
        try await runCommand(zipTool, arguments: args, workingDirectory: workDir)
        
        progressHandler?(CompressionProgressInfo(
            fractionCompleted: 1.0,
            statusMessage: "压缩完成！",
            filesProcessed: files.count,
            totalFiles: files.count
        ))
    }
    
    // MARK: - 辅助方法
    private func findCommonParentDirectory(of urls: [URL]) -> URL {
        guard let first = urls.first else { return URL(fileURLWithPath: "/") }
        var commonComponents = first.pathComponents
        
        for url in urls.dropFirst() {
            let components = url.pathComponents
            var common = 0
            for (a, b) in zip(commonComponents, components) {
                if a == b { common += 1 } else { break }
            }
            commonComponents = Array(commonComponents.prefix(common))
        }
        
        if commonComponents.isEmpty { return URL(fileURLWithPath: "/") }
        let path = commonComponents.joined(separator: "/")
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    
    private func relativePath(from base: URL, to target: URL) -> String {
        let basePath = base.standardized.path
        let targetPath = target.standardized.path
        if targetPath.hasPrefix(basePath + "/") {
            return String(targetPath.dropFirst(basePath.count + 1))
        }
        return target.lastPathComponent
    }
    
    private func runCommand(_ path: String, arguments: [String], workingDirectory: URL? = nil) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            if let wd = workingDirectory {
                process.currentDirectoryURL = wd
            }
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 || proc.terminationStatus == 12 { // zip: 12 = "nothing to compress" but still OK
                    continuation.resume()
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(throwing: CompressionError.compressionFailed(
                        output.trimmingCharacters(in: .whitespacesAndNewlines),
                        proc.terminationStatus
                    ))
                }
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
