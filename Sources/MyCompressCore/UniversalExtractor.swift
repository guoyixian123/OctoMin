import Foundation
import UniformTypeIdentifiers

// MARK: - 支持的归档格式
public enum ArchiveFormat: String, CaseIterable, Sendable {
    case mcz = "mcz"
    case zip = "zip"
    case rar = "rar"
    case sevenZip = "7z"
    case tar = "tar"
    case gz = "gz"
    case bz2 = "bz2"
    case xz = "xz"
    case tgz = "tgz"
    case tbz2 = "tbz2"
    
    public var displayName: String {
        switch self {
        case .mcz: return "MCZ"
        case .zip: return "ZIP"
        case .rar: return "RAR"
        case .sevenZip: return "7-Zip"
        case .tar: return "TAR"
        case .gz: return "GZIP"
        case .bz2: return "BZIP2"
        case .xz: return "XZ"
        case .tgz: return "TAR.GZ"
        case .tbz2: return "TAR.BZ2"
        }
    }
    
    public static func from(url: URL) -> ArchiveFormat? {
        let ext = url.pathExtension.lowercased()
        return ArchiveFormat(rawValue: ext)
    }
    
    public static var supportedExtensions: [String] {
        allCases.map { $0.rawValue }
    }
}

// MARK: - 通用解压进度
public struct ExtractionProgress: Sendable {
    public let fractionCompleted: Double
    public let statusMessage: String
    public let filesProcessed: Int
    public let totalFiles: Int
    
    public init(fractionCompleted: Double, statusMessage: String, filesProcessed: Int, totalFiles: Int) {
        self.fractionCompleted = fractionCompleted
        self.statusMessage = statusMessage
        self.filesProcessed = filesProcessed
        self.totalFiles = totalFiles
    }
}

// MARK: - 归档信息
public struct ArchiveMetadata: Sendable {
    public let format: ArchiveFormat
    public let fileCount: Int?
    public let totalSize: Int64?
    public let isEncrypted: Bool
    
    public init(format: ArchiveFormat, fileCount: Int?, totalSize: Int64?, isEncrypted: Bool) {
        self.format = format
        self.fileCount = fileCount
        self.totalSize = totalSize
        self.isEncrypted = isEncrypted
    }
}

// MARK: - 通用解压器
public final class UniversalExtractor: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (ExtractionProgress) -> Void
    
    public enum ExtractionError: Error, LocalizedError, Sendable {
        case unsupportedFormat
        case toolNotFound(String)
        case extractionFailed(String, Int32)
        case cancelled
        case corruptedArchive(String)
        
        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "不支持的文件格式"
            case .toolNotFound(let tool):
                return "未找到解压工具 \(tool)，请先安装（如 brew install unar）"
            case .extractionFailed(let message, let code):
                return "解压失败 (code: \(code)): \(message)"
            case .cancelled:
                return "解压已取消"
            case .corruptedArchive(let message):
                return "归档文件损坏: \(message)"
            }
        }
    }
    
    private let progressHandler: ProgressHandler?
    
    public init(progressHandler: ProgressHandler? = nil) {
        self.progressHandler = progressHandler
    }
    
    // MARK: - 检查是否支持格式
    public static func canHandle(_ url: URL) -> Bool {
        guard let format = ArchiveFormat.from(url: url) else { return false }
        
        switch format {
        case .mcz:
            return true // 我们自己的格式始终支持
        case .zip:
            return true // macOS自带ditto/unzip
        case .tar, .gz, .bz2, .xz, .tgz, .tbz2:
            return true // macOS自带tar
        case .rar, .sevenZip:
            return findTool(named: "unar") != nil || findTool(named: "7z") != nil || findTool(named: "unrar") != nil
        }
    }
    
    // MARK: - 读取归档信息
    public static func readMetadata(for url: URL, password: String? = nil) throws -> ArchiveMetadata {
        guard let format = ArchiveFormat.from(url: url) else {
            throw ExtractionError.unsupportedFormat
        }
        
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
        let isEncrypted: Bool
        
        switch format {
        case .mcz:
            // 使用我们自己的读取器
            let info = try ParallelDecompressor.readArchiveInfo(archiveURL: url)
            return ArchiveMetadata(
                format: .mcz,
                fileCount: Int(info.header.fileCount),
                totalSize: Int64(info.totalUncompressedSize),
                isEncrypted: info.header.isEncrypted
            )
        case .zip:
            isEncrypted = checkZipEncrypted(url: url)
        case .rar:
            isEncrypted = false // 简化处理
        case .sevenZip:
            isEncrypted = false
        default:
            isEncrypted = false
        }
        
        return ArchiveMetadata(
            format: format,
            fileCount: nil,
            totalSize: fileSize,
            isEncrypted: isEncrypted
        )
    }
    
    // MARK: - 解压
    public func extract(archive url: URL, to destination: URL, password: String? = nil, overwrite: Bool = true) async throws {
        guard let format = ArchiveFormat.from(url: url) else {
            throw ExtractionError.unsupportedFormat
        }
        
        // 确保目标目录存在
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        
        switch format {
        case .mcz:
            try await extractMCZ(url: url, to: destination, password: password, overwrite: overwrite)
        case .zip:
            try await extractZip(url: url, to: destination, password: password, overwrite: overwrite)
        case .rar, .sevenZip:
            try await extractWithExternalTool(url: url, to: destination, format: format, password: password, overwrite: overwrite)
        case .tar, .gz, .bz2, .xz, .tgz, .tbz2:
            try await extractTar(url: url, to: destination)
        }
    }
    
    // MARK: - MCZ 解压（我们自己的格式）
    private func extractMCZ(url: URL, to destination: URL, password: String?, overwrite: Bool) async throws {
        let options = MCZDecompressionOptions(
            password: password,
            maxConcurrency: ProcessInfo.processInfo.activeProcessorCount,
            restorePermissions: true,
            overwriteExisting: overwrite,
            verifyCRC: true
        )
        
        // 直接捕获 progressHandler 而非 self，避免 Sendable 闭包捕获非 Sendable 的 self
        let handler = progressHandler
        let decompressor = ParallelDecompressor(options: options) { prog in
            handler?(ExtractionProgress(
                fractionCompleted: prog.fractionCompleted,
                statusMessage: "正在解压... \(Int(prog.fractionCompleted * 100))%",
                filesProcessed: prog.filesProcessed,
                totalFiles: prog.totalFiles
            ))
        }
        
        try await decompressor.extract(archive: url, to: destination)
        handler?(ExtractionProgress(fractionCompleted: 1.0, statusMessage: "解压完成", filesProcessed: 0, totalFiles: 0))
    }
    
    // MARK: - ZIP 解压（使用系统ditto）
    private func extractZip(url: URL, to destination: URL, password: String?, overwrite: Bool) async throws {
        progressHandler?(ExtractionProgress(fractionCompleted: 0.1, statusMessage: "正在解压ZIP...", filesProcessed: 0, totalFiles: 0))
        
        // 优先使用 unzip（支持密码）
        let toolPath: String
        let toolArgs: [String]
        
        if let unzip = Self.findTool(named: "unzip") {
            toolPath = unzip
            var args = ["-o"]
            if !overwrite { args = ["-n"] }
            if let pw = password, !pw.isEmpty {
                args.append(contentsOf: ["-P", pw])
            }
            args.append(contentsOf: [url.path, "-d", destination.path])
            toolArgs = args
        } else {
            // 使用 ditto（不支持密码）
            toolPath = "/usr/bin/ditto"
            toolArgs = ["-x", "-k", url.path, destination.path]
        }
        
        try await runCommand(toolPath, arguments: toolArgs)
        progressHandler?(ExtractionProgress(fractionCompleted: 1.0, statusMessage: "解压完成", filesProcessed: 0, totalFiles: 0))
    }
    
    // MARK: - TAR/TAR.GZ/TAR.BZ2/TAR.XZ/GZ/BZ2/XZ 解压（使用系统tar）
    private func extractTar(url: URL, to destination: URL) async throws {
        progressHandler?(ExtractionProgress(fractionCompleted: 0.1, statusMessage: "正在解压TAR...", filesProcessed: 0, totalFiles: 0))
        
        let toolPath = "/usr/bin/tar"
        let toolArgs = ["-xf", url.path, "-C", destination.path]
        
        try await runCommand(toolPath, arguments: toolArgs)
        progressHandler?(ExtractionProgress(fractionCompleted: 1.0, statusMessage: "解压完成", filesProcessed: 0, totalFiles: 0))
    }
    
    // MARK: - RAR/7Z 解压（使用外部工具）
    private func extractWithExternalTool(url: URL, to destination: URL, format: ArchiveFormat, password: String?, overwrite: Bool) async throws {
        progressHandler?(ExtractionProgress(fractionCompleted: 0.1, statusMessage: "正在解压\(format.displayName)...", filesProcessed: 0, totalFiles: 0))
        
        // 优先使用 unar（支持格式最多）
        if let unar = Self.findTool(named: "unar") {
            var args = ["-o", destination.path, "-f"]
            if overwrite { args.append("-r") } // replace
            if let pw = password, !pw.isEmpty {
                args.append(contentsOf: ["-p", pw])
            }
            args.append(url.path)
            
            try await runCommand(unar, arguments: args)
            progressHandler?(ExtractionProgress(fractionCompleted: 1.0, statusMessage: "解压完成", filesProcessed: 0, totalFiles: 0))
            return
        }
        
        // 7z
        if let sevenz = Self.findTool(named: "7z") {
            var args = ["x", url.path, "-o\(destination.path)", "-y"]
            if let pw = password, !pw.isEmpty {
                args.append("-p\(pw)")
            }
            try await runCommand(sevenz, arguments: args)
            progressHandler?(ExtractionProgress(fractionCompleted: 1.0, statusMessage: "解压完成", filesProcessed: 0, totalFiles: 0))
            return
        }
        
        // unrar
        if let unrar = Self.findTool(named: "unrar") {
            var args = ["x", "-y"]
            if !overwrite { args = ["x", "-o-"] }
            if let pw = password, !pw.isEmpty {
                args.append("-p\(pw)")
            }
            args.append(url.path)
            args.append(destination.path + "/")
            try await runCommand(unrar, arguments: args)
            progressHandler?(ExtractionProgress(fractionCompleted: 1.0, statusMessage: "解压完成", filesProcessed: 0, totalFiles: 0))
            return
        }
        
        throw ExtractionError.toolNotFound("unar/7z/unrar")
    }
    
    // MARK: - 辅助方法
    
    private func runCommand(_ path: String, arguments: [String]) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(throwing: ExtractionError.extractionFailed(output.trimmingCharacters(in: .whitespacesAndNewlines), proc.terminationStatus))
                }
            }
            
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    public static func findTool(named name: String) -> String? {
        let paths = ["/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/bin/\(name)", "/bin/\(name)"]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // 通过 which 查找
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    return path
                }
            }
        } catch {}
        return nil
    }
    
    // 简单检测ZIP是否加密（检查文件头中的加密标志位）
    private static func checkZipEncrypted(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        
        let sig: UInt32 = 0x04034b50
        var offset: UInt64 = 0
        
        while true {
            handle.seek(toFileOffset: offset)
            guard let sigData = handle.readData(ofLength: 4) as Data?, sigData.count == 4 else { break }
            
            let value = sigData.withUnsafeBytes { $0.load(as: UInt32.self) }
            guard value == sig else { break }
            
            handle.seek(toFileOffset: offset + 6)
            guard let flagData = handle.readData(ofLength: 4) as Data?, flagData.count >= 2 else { break }
            let flags = flagData.withUnsafeBytes { $0.load(as: UInt16.self) }
            if flags & 0x01 != 0 {
                return true
            }
            
            handle.seek(toFileOffset: offset + 18)
            guard let csizeData = handle.readData(ofLength: 4) as Data?, csizeData.count == 4,
                  let nlenData = handle.readData(ofLength: 2) as Data?, nlenData.count == 2,
                  let elenData = handle.readData(ofLength: 2) as Data?, elenData.count == 2 else {
                break
            }
            
            let csize = csizeData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let nlen = nlenData.withUnsafeBytes { $0.load(as: UInt16.self) }
            let elen = elenData.withUnsafeBytes { $0.load(as: UInt16.self) }
            
            offset += 30 + UInt64(nlen) + UInt64(elen) + UInt64(csize)
            
            if offset > 100_000_000 { break }
        }
        
        return false
    }
}
