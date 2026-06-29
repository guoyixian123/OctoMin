import Foundation
import MyCompressCore

let cli = CLI()
await cli.run(CommandLine.arguments)

struct CLI {
    func run(_ args: [String]) async {
        guard args.count > 1 else {
            printUsage()
            return
        }
        
        let command = args[1]
        
        switch command {
        case "compress", "c":
            await compress(args: Array(args.dropFirst(2)))
        case "decompress", "d", "x":
            await decompress(args: Array(args.dropFirst(2)))
        case "list", "l":
            await list(args: Array(args.dropFirst(2)))
        case "help", "-h", "--help":
            printUsage()
        default:
            print("Unknown command: \(command)")
            printUsage()
        }
    }
    
    func printUsage() {
        print("""
        MyCompress CLI - Multi-threaded compression tool
        
        Usage:
          MyCompressCLI compress <source> [-o output] [-a algorithm] [-l level] [-p password]
          MyCompressCLI decompress <archive> [-o output] [-p password]
          MyCompressCLI list <archive> [-p password]
        
        Commands:
          compress, c     Compress file or directory
          decompress, d   Decompress archive
          list, l         List archive contents
        
        Options:
          -o <path>       Output path
          -a <algo>       Algorithm: lz4, zstd, lzma (default: zstd)
          -l <level>      Compression level: fastest, fast, default, best
          -p <password>   Encryption/decryption password
          -h, --help      Show this help
        
        Algorithms:
          lz4    - Ultra fast compression, lower ratio
          zstd   - Balanced speed and ratio (recommended)
          lzma   - Best compression ratio, slower
        """)
    }
    
    func compress(args: [String]) async {
        var source: String?
        var output: String?
        var algorithm: MCZCompressionAlgorithm = .zstd
        var level: MCZCompressionLevel = .default
        var password: String?
        
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-o":
                i += 1
                if i < args.count { output = args[i] }
            case "-a":
                i += 1
                if i < args.count {
                    switch args[i].lowercased() {
                    case "lz4": algorithm = .lz4
                    case "zstd": algorithm = .zstd
                    case "lzma": algorithm = .lzma
                    default: print("Unknown algorithm: \(args[i])"); return
                    }
                }
            case "-l":
                i += 1
                if i < args.count {
                    switch args[i].lowercased() {
                    case "fastest": level = .fastest
                    case "fast": level = .fast
                    case "default": level = .default
                    case "best": level = .best
                    default:
                        if let n = Int(args[i]), n <= 2 { level = .fastest }
                        else if let n = Int(args[i]), n <= 4 { level = .fast }
                        else if let n = Int(args[i]), n <= 7 { level = .default }
                        else { level = .best }
                    }
                }
            case "-p":
                i += 1
                if i < args.count { password = args[i] }
            default:
                if source == nil { source = args[i] }
            }
            i += 1
        }
        
        guard let sourcePath = source else {
            print("Error: Source path required")
            return
        }
        
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let outputURL: URL
        if let o = output {
            outputURL = URL(fileURLWithPath: o)
        } else {
            outputURL = sourceURL.appendingPathExtension("mcz")
        }
        
        let options = MCZCompressionOptions(
            algorithm: algorithm,
            level: level,
            blockSize: 1024 * 1024,
            maxConcurrency: ProcessInfo.processInfo.activeProcessorCount,
            password: password,
            preservePermissions: true
        )
        
        print("Compressing \(sourcePath) -> \(outputURL.path)")
        print("Algorithm: \(algorithm.displayName), Level: \(level)")
        
        let compressor = ParallelCompressor(
            options: options,
            progressHandler: { prog in
                let percent = Int(prog.fractionCompleted * 100)
                fputs("\rProgress: \(percent)% (\(prog.filesProcessed)/\(prog.totalFiles) files)", stderr)
            }
        )
        
        do {
            try await compressor.compressDirectory(source: sourceURL, destination: outputURL)
            fputs("\nDone!\n", stderr)
        } catch {
            fputs("\nError: \(error.localizedDescription)\n", stderr)
        }
    }
    
    func decompress(args: [String]) async {
        var archive: String?
        var output: String?
        var password: String?
        
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-o":
                i += 1
                if i < args.count { output = args[i] }
            case "-p":
                i += 1
                if i < args.count { password = args[i] }
            default:
                if archive == nil { archive = args[i] }
            }
            i += 1
        }
        
        guard let archivePath = archive else {
            print("Error: Archive path required")
            return
        }
        
        let archiveURL = URL(fileURLWithPath: archivePath)
        let outputURL: URL
        if let o = output {
            outputURL = URL(fileURLWithPath: o)
        } else {
            outputURL = archiveURL.deletingPathExtension()
        }
        
        let options = MCZDecompressionOptions(
            password: password,
            maxConcurrency: ProcessInfo.processInfo.activeProcessorCount,
            restorePermissions: true,
            overwriteExisting: true,
            verifyCRC: true
        )
        
        print("Extracting \(archivePath) -> \(outputURL.path)")
        
        let decompressor = ParallelDecompressor(
            options: options,
            progressHandler: { prog in
                let percent = Int(prog.fractionCompleted * 100)
                fputs("\rProgress: \(percent)% (\(prog.filesProcessed)/\(prog.totalFiles) files)", stderr)
            }
        )
        
        do {
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try await decompressor.extract(archive: archiveURL, to: outputURL)
            fputs("\nDone!\n", stderr)
        } catch {
            fputs("\nError: \(error.localizedDescription)\n", stderr)
        }
    }
    
    func list(args: [String]) async {
        var archive: String?
        var password: String?
        
        var i = 0
        while i < args.count {
            switch args[i] {
            case "-p":
                i += 1
                if i < args.count { password = args[i] }
            default:
                if archive == nil { archive = args[i] }
            }
            i += 1
        }
        
        guard let archivePath = archive else {
            print("Error: Archive path required")
            return
        }
        
        let archiveURL = URL(fileURLWithPath: archivePath)
        
        do {
            let info = try ParallelDecompressor.readArchiveInfo(archiveURL: archiveURL)
            
            print("Archive: \(archivePath)")
            print("Algorithm: \(info.header.algorithm.displayName)")
            print("Files: \(info.header.fileCount)")
            print("Compressed: \(ByteCountFormatter.string(fromByteCount: Int64(info.totalCompressedSize), countStyle: .file))")
            print("Uncompressed: \(ByteCountFormatter.string(fromByteCount: Int64(info.totalUncompressedSize), countStyle: .file))")
            if info.totalUncompressedSize > 0 {
                print("Ratio: \(String(format: "%.1f%%", info.compressionRatio * 100))")
            }
            if info.header.flags.contains(.encrypted) {
                print("Encrypted: Yes")
            }
            print("---")
            
            for entry in info.entries {
                let size = ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize), countStyle: .file)
                print("  \(entry.path) (\(size))")
            }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
