// CompressionEngine.swift
// MyCompressCore - Apple Compression framework wrapper
// Target: macOS 13+

import Foundation
import Compression

// MARK: - Compression Level

/// 压缩级别
public enum OMZCompressionLevel: Int, Sendable, CaseIterable {
    case fastest = 0
    case fast = 2
    case `default` = 5
    case best = 9
}

// MARK: - Compression Engine Errors

/// 压缩引擎错误
public enum CompressionError: Error, Sendable, LocalizedError {
    case compressionFailed(algorithm: String, message: String)
    case decompressionFailed(algorithm: String, message: String)
    case outputBufferTooSmall(expected: Int, actual: Int)
    case unknownAlgorithm

    public var errorDescription: String? {
        switch self {
        case .compressionFailed(let algo, let msg):
            return "[\(algo)] 压缩失败: \(msg)"
        case .decompressionFailed(let algo, let msg):
            return "[\(algo)] 解压失败: \(msg)"
        case .outputBufferTooSmall(let expected, let actual):
            return "输出缓冲区太小: 期望至少 \(expected), 实际 \(actual)"
        case .unknownAlgorithm:
            return "未知的压缩算法"
        }
    }
}

// MARK: - Compression Engine

/// Apple Compression 框架封装引擎
/// 支持 LZ4、ZSTD、LZMA 算法, 提供同步压缩/解压方法
public struct CompressionEngine: Sendable {
    /// 压缩算法
    public let algorithm: OMZCompressionAlgorithm

    /// 压缩级别
    public let level: OMZCompressionLevel

    /// 初始化压缩引擎
    /// - Parameters:
    ///   - algorithm: 压缩算法
    ///   - level: 压缩级别, 默认 .default
    public init(algorithm: OMZCompressionAlgorithm, level: OMZCompressionLevel = .default) {
        self.algorithm = algorithm
        self.level = level
    }

    // MARK: - Core Compression (compression_encode_buffer)

    /// 使用 compression_encode_buffer 压缩数据
    /// - Parameter source: 源数据
    /// - Returns: 压缩后的数据
    public func compress(_ source: Data) throws -> Data {
        guard !source.isEmpty else { return Data() }

        let algo = algorithm.compressionAlgorithm
        let algoName = algorithm.displayName

        // buffer API 不接受 flags 参数, 压缩行为由算法选择决定
        // (LZ4最快, LZMA最小, LZFSE平衡)

        // 尝试压缩, 如果输出缓冲区太小则重试 (倍增策略)
        var destCapacity = max(source.count + max(source.count / 8, 64), 256)
        var attempts = 0
        let maxAttempts = 8

        while attempts < maxAttempts {
            var destination = Data(count: destCapacity)
            let compressedSize: Int = destination.withUnsafeMutableBytes { destPtr -> Int in
                guard let destBase = destPtr.baseAddress else { return 0 }
                return source.withUnsafeBytes { srcPtr -> Int in
                    guard let srcBase = srcPtr.baseAddress else { return 0 }
                    return compression_encode_buffer(
                        destBase.assumingMemoryBound(to: UInt8.self),
                        destCapacity,
                        srcBase.assumingMemoryBound(to: UInt8.self),
                        source.count,
                        nil,
                        algo
                    )
                }
            }

            if compressedSize > 0 && compressedSize <= destCapacity {
                return destination.prefix(compressedSize)
            }

            // 缓冲区可能太小, 扩大一倍重试
            destCapacity *= 2
            attempts += 1
        }

        throw CompressionError.compressionFailed(
            algorithm: algoName,
            message: "输出缓冲区不足, 已尝试到 \(destCapacity) 字节"
        )
    }

    // MARK: - Core Decompression (compression_decode_buffer)

    /// 使用 compression_decode_buffer 解压数据
    /// - Parameters:
    ///   - source: 压缩数据
    ///   - uncompressedSize: 已知的解压后大小 (必须提供以分配缓冲区)
    /// - Returns: 解压后的数据
    public func decompress(_ source: Data, uncompressedSize: Int) throws -> Data {
        guard !source.isEmpty else { return Data() }
        guard uncompressedSize > 0 else { return Data() }

        let algo = algorithm.compressionAlgorithm
        let algoName = algorithm.displayName

        var destination = Data(count: uncompressedSize)

        let decompressedSize: Int = destination.withUnsafeMutableBytes { destPtr -> Int in
            guard let destBase = destPtr.baseAddress else { return 0 }
            return source.withUnsafeBytes { srcPtr -> Int in
                guard let srcBase = srcPtr.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destBase.assumingMemoryBound(to: UInt8.self),
                    uncompressedSize,
                    srcBase.assumingMemoryBound(to: UInt8.self),
                    source.count,
                    nil,
                    algo
                )
            }
        }

        guard decompressedSize > 0 else {
            throw CompressionError.decompressionFailed(
                algorithm: algoName,
                message: "compression_decode_buffer 返回 0, 数据可能损坏"
            )
        }

        guard decompressedSize == uncompressedSize else {
            throw CompressionError.decompressionFailed(
                algorithm: algoName,
                message: "解压大小不匹配: 期望 \(uncompressedSize), 实际 \(decompressedSize)"
            )
        }

        return destination
    }

    // MARK: - Streaming API (compression_stream)

    /// 使用 streaming API 压缩数据 (适合一次性处理, 内部使用 finalize)
    public func compressStream(
        _ source: Data,
        bufferSize: Int = 64 * 1024
    ) throws -> Data {
        let algo = algorithm.compressionAlgorithm
        // compression_stream C 结构体要求所有指针字段非空,
        // 分配 dummy 指针 (在 compression_stream_init 后, 处理前会被覆盖)
        let dummyDst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let dummySrc = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        var stream = compression_stream(
            dst_ptr: dummyDst,
            dst_size: 0,
            src_ptr: UnsafePointer(dummySrc),
            src_size: 0,
            state: nil
        )
        var output = Data()

        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, algo)
        guard initStatus == COMPRESSION_STATUS_OK else {
            dummyDst.deallocate()
            dummySrc.deallocate()
            throw CompressionError.compressionFailed(
                algorithm: algorithm.displayName,
                message: "compression_stream_init 失败: \(initStatus)"
            )
        }
        defer {
            compression_stream_destroy(&stream)
            dummyDst.deallocate()
            dummySrc.deallocate()
        }

        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

        let compressResult: CompressionError? = source.withUnsafeBytes { srcPtr -> CompressionError? in
            guard let srcBase = srcPtr.baseAddress else {
                return CompressionError.compressionFailed(algorithm: algorithm.displayName, message: "源缓冲区不可用")
            }
            stream.src_ptr = srcBase.assumingMemoryBound(to: UInt8.self)
            stream.src_size = source.count

            var dstBuffer = [UInt8](repeating: 0, count: bufferSize)

            while true {
                let status: compression_status = dstBuffer.withUnsafeMutableBytes { dstPtr -> compression_status in
                    guard let dstBase = dstPtr.baseAddress else { return COMPRESSION_STATUS_ERROR }
                    stream.dst_ptr = dstBase.assumingMemoryBound(to: UInt8.self)
                    stream.dst_size = bufferSize
                    return compression_stream_process(&stream, flags)
                }

                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(contentsOf: dstBuffer.prefix(produced))
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return nil
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_ERROR:
                    return CompressionError.compressionFailed(
                        algorithm: algorithm.displayName,
                        message: "compression_stream_process 错误"
                    )
                default:
                    return CompressionError.compressionFailed(
                        algorithm: algorithm.displayName,
                        message: "未知状态: \(status.rawValue)"
                    )
                }
            }
        }

        if let error = compressResult {
            throw error
        }

        return output
    }

    /// 使用 streaming API 解压数据
    public func decompressStream(
        _ source: Data,
        bufferSize: Int = 64 * 1024
    ) throws -> Data {
        let algo = algorithm.compressionAlgorithm
        let dummyDst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        let dummySrc = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        var stream = compression_stream(
            dst_ptr: dummyDst,
            dst_size: 0,
            src_ptr: UnsafePointer(dummySrc),
            src_size: 0,
            state: nil
        )
        var output = Data()

        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algo)
        guard initStatus == COMPRESSION_STATUS_OK else {
            dummyDst.deallocate()
            dummySrc.deallocate()
            throw CompressionError.decompressionFailed(
                algorithm: algorithm.displayName,
                message: "compression_stream_init 失败: \(initStatus)"
            )
        }
        defer {
            compression_stream_destroy(&stream)
            dummyDst.deallocate()
            dummySrc.deallocate()
        }

        let decompressResult: CompressionError? = source.withUnsafeBytes { srcPtr -> CompressionError? in
            guard let srcBase = srcPtr.baseAddress else {
                return CompressionError.decompressionFailed(algorithm: algorithm.displayName, message: "源缓冲区不可用")
            }
            stream.src_ptr = srcBase.assumingMemoryBound(to: UInt8.self)
            stream.src_size = source.count

            var dstBuffer = [UInt8](repeating: 0, count: bufferSize)

            while true {
                let status: compression_status = dstBuffer.withUnsafeMutableBytes { dstPtr -> compression_status in
                    guard let dstBase = dstPtr.baseAddress else { return COMPRESSION_STATUS_ERROR }
                    stream.dst_ptr = dstBase.assumingMemoryBound(to: UInt8.self)
                    stream.dst_size = bufferSize
                    return compression_stream_process(&stream, 0)
                }

                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    output.append(contentsOf: dstBuffer.prefix(produced))
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return nil
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_ERROR:
                    return CompressionError.decompressionFailed(
                        algorithm: algorithm.displayName,
                        message: "compression_stream_process 错误"
                    )
                default:
                    return CompressionError.decompressionFailed(
                        algorithm: algorithm.displayName,
                        message: "未知状态: \(status.rawValue)"
                    )
                }
            }
        }

        if let error = decompressResult {
            throw error
        }

        return output
    }
}

// MARK: - Convenience Static Methods

public extension CompressionEngine {
    /// 快速压缩 (使用 LZ4 最快速度)
    static func fastestCompress(_ data: Data) throws -> Data {
        try CompressionEngine(algorithm: .lz4, level: .fastest).compress(data)
    }

    /// 最佳压缩 (使用 LZMA 最佳压缩率)
    static func bestCompress(_ data: Data) throws -> Data {
        try CompressionEngine(algorithm: .lzma, level: .best).compress(data)
    }

    /// 平衡压缩 (使用 ZSTD 默认级别)
    static func balancedCompress(_ data: Data) throws -> Data {
        try CompressionEngine(algorithm: .zstd, level: .default).compress(data)
    }
}
