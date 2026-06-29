// CryptoEngine.swift
// MyCompressCore - AES-256-GCM encryption engine
// Target: macOS 13+

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Crypto Engine Errors

/// 加密引擎相关错误
public enum CryptoError: Error, Sendable, LocalizedError {
    case keyDerivationFailed
    case encryptionFailed(String)
    case decryptionFailed(String)
    case invalidKeySize
    case authenticationFailure
    case invalidEncryptedData

    public var errorDescription: String? {
        switch self {
        case .keyDerivationFailed:
            return "密钥派生失败"
        case .encryptionFailed(let msg):
            return "加密失败: \(msg)"
        case .decryptionFailed(let msg):
            return "解密失败: \(msg)"
        case .invalidKeySize:
            return "密钥长度无效 (AES-256 需要 32 字节)"
        case .authenticationFailure:
            return "认证标签验证失败, 数据可能被篡改或密码错误"
        case .invalidEncryptedData:
            return "加密数据格式无效"
        }
    }
}

// MARK: - Encrypted Data Container

/// 加密后的数据封装格式:
/// - salt (16 bytes): PBKDF2 盐值
/// - nonce (12 bytes): AES-GCM nonce
/// - ciphertext + tag (variable): 密文 + 16 bytes GCM 认证标签
public struct MCZEncryptedData: Sendable {
    public static let saltSize = 16
    public static let nonceSize = 12
    public static let tagSize = 16
    public static let overhead = saltSize + nonceSize + tagSize

    public let salt: Data
    public let nonce: Data
    public let ciphertext: Data  // 包含认证标签在末尾

    public init(salt: Data, nonce: Data, ciphertext: Data) {
        self.salt = salt
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    /// 序列化为二进制格式: salt + nonce + ciphertext(含tag)
    public func serialize() -> Data {
        var data = Data(capacity: salt.count + nonce.count + ciphertext.count)
        data.append(salt)
        data.append(nonce)
        data.append(ciphertext)
        return data
    }

    /// 从二进制数据反序列化
    public static func deserialize(from data: Data) throws -> MCZEncryptedData {
        guard data.count >= overhead else {
            throw CryptoError.invalidEncryptedData
        }

        let salt = data.subdata(in: 0..<saltSize)
        let nonce = data.subdata(in: saltSize..<saltSize+nonceSize)
        let ciphertext = data.subdata(in: saltSize+nonceSize..<data.count)

        guard ciphertext.count >= tagSize else {
            throw CryptoError.invalidEncryptedData
        }

        return MCZEncryptedData(salt: salt, nonce: nonce, ciphertext: ciphertext)
    }
}

// MARK: - Crypto Engine

/// AES-256-GCM 加密引擎
/// 使用 PBKDF2-HMAC-SHA256 从密码派生密钥
public actor CryptoEngine {
    /// PBKDF2 迭代次数
    public static let defaultPBKDF2Iterations: UInt32 = 100_000

    /// AES-256 密钥长度 (32 bytes)
    public static let keySize = 32

    /// 密码
    private let password: String

    /// PBKDF2 迭代次数
    private let iterations: UInt32

    /// 缓存的密钥 (salt -> SymmetricKey)
    private var keyCache: [Data: SymmetricKey] = [:]

    /// 初始化加密引擎
    /// - Parameters:
    ///   - password: 用户密码
    ///   - iterations: PBKDF2 迭代次数, 默认 100,000
    public init(password: String, iterations: UInt32 = CryptoEngine.defaultPBKDF2Iterations) {
        self.password = password
        self.iterations = iterations
    }

    // MARK: - Key Derivation

    /// 使用 PBKDF2-HMAC-SHA256 从密码和盐派生 32 字节密钥
    public func deriveKey(salt: Data) throws -> SymmetricKey {
        if let cached = keyCache[salt] {
            return cached
        }

        let key = try PBKDF2.deriveKey(
            password: Array(password.utf8),
            salt: Array(salt),
            iterations: iterations,
            keyLength: CryptoEngine.keySize
        )
        let symmetricKey = SymmetricKey(data: Data(key))
        keyCache[salt] = symmetricKey
        return symmetricKey
    }

    /// 生成随机盐值 (16 bytes)
    public static func generateSalt() -> Data {
        var salt = Data(count: saltSize)
        let status = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, saltSize, ptr.baseAddress!)
        }
        precondition(status == errSecSuccess, "Failed to generate random salt")
        return salt
    }

    /// 生成随机 nonce (12 bytes)
    public static func generateNonce() -> Data {
        var nonce = Data(count: nonceSize)
        let status = nonce.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, nonceSize, ptr.baseAddress!)
        }
        precondition(status == errSecSuccess, "Failed to generate random nonce")
        return nonce
    }

    // MARK: - Encryption

    /// 加密数据
    /// - Parameter data: 要加密的明文数据
    /// - Returns: 加密后的数据容器 (含 salt、nonce、密文+tag)
    public func encrypt(_ data: Data) throws -> MCZEncryptedData {
        let salt = CryptoEngine.generateSalt()
        return try encrypt(data, salt: salt)
    }

    /// 使用指定盐值加密数据 (用于确定性加密场景)
    public func encrypt(_ data: Data, salt: Data) throws -> MCZEncryptedData {
        let nonceData = CryptoEngine.generateNonce()
        let key = try deriveKey(salt: salt)

        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else {
            throw CryptoError.encryptionFailed("无法创建 nonce")
        }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce)
        } catch {
            throw CryptoError.encryptionFailed(error.localizedDescription)
        }

        // ciphertext + tag
        var ciphertext = Data(sealedBox.ciphertext)
        ciphertext.append(sealedBox.tag)

        return MCZEncryptedData(salt: salt, nonce: nonceData, ciphertext: ciphertext)
    }

    /// 加密数据并序列化为二进制格式
    public func encryptToData(_ data: Data) throws -> Data {
        let encrypted = try encrypt(data)
        return encrypted.serialize()
    }

    // MARK: - Decryption

    /// 解密数据
    /// - Parameter encrypted: 加密数据容器
    /// - Returns: 解密后的明文数据
    public func decrypt(_ encrypted: MCZEncryptedData) throws -> Data {
        let key = try deriveKey(salt: encrypted.salt)

        guard let nonce = try? AES.GCM.Nonce(data: encrypted.nonce) else {
            throw CryptoError.decryptionFailed("无效的 nonce")
        }

        // ciphertext 末尾 16 字节是 tag
        let tagStart = encrypted.ciphertext.count - MCZEncryptedData.tagSize
        guard tagStart >= 0, encrypted.ciphertext.count >= MCZEncryptedData.tagSize else {
            throw CryptoError.invalidEncryptedData
        }

        let ciphertext = encrypted.ciphertext.prefix(tagStart)
        let tag = encrypted.ciphertext.suffix(MCZEncryptedData.tagSize)

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(sealedBox, using: key)
        } catch CryptoKitError.authenticationFailure {
            throw CryptoError.authenticationFailure
        } catch {
            throw CryptoError.decryptionFailed(error.localizedDescription)
        }
    }

    /// 从二进制数据解密
    public func decryptFromData(_ data: Data) throws -> Data {
        let encrypted = try MCZEncryptedData.deserialize(from: data)
        return try decrypt(encrypted)
    }

    // MARK: - Stream Encryption (逐块)

    /// 加密单个数据块 (使用提供的 salt 和 nonce)
    public func encryptBlock(_ data: Data, salt: Data, nonce: Data) throws -> Data {
        let key = try deriveKey(salt: salt)
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce) else {
            throw CryptoError.encryptionFailed("无法创建块 nonce")
        }
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: gcmNonce)
        var result = Data(sealedBox.ciphertext)
        result.append(sealedBox.tag)
        return result
    }

    /// 解密单个数据块
    public func decryptBlock(_ ciphertext: Data, salt: Data, nonce: Data) throws -> Data {
        let key = try deriveKey(salt: salt)
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce) else {
            throw CryptoError.decryptionFailed("无效的块 nonce")
        }
        let tagStart = ciphertext.count - MCZEncryptedData.tagSize
        guard tagStart >= 0, ciphertext.count >= MCZEncryptedData.tagSize else {
            throw CryptoError.invalidEncryptedData
        }
        let ct = ciphertext.prefix(tagStart)
        let tag = ciphertext.suffix(MCZEncryptedData.tagSize)
        do {
            let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ct, tag: tag)
            return try AES.GCM.open(sealedBox, using: key)
        } catch CryptoKitError.authenticationFailure {
            throw CryptoError.authenticationFailure
        }
    }

    /// 清除密钥缓存
    public func clearKeyCache() {
        keyCache.removeAll()
    }
}

// MARK: - PBKDF2 Implementation

/// PBKDF2-HMAC-SHA256 密钥派生
/// 使用 CommonCrypto 实现
enum PBKDF2 {
    static func deriveKey(
        password: [UInt8],
        salt: [UInt8],
        iterations: UInt32,
        keyLength: Int
    ) throws -> [UInt8] {
        var derivedKey = [UInt8](repeating: 0, count: keyLength)
        let result: Int32 = derivedKey.withUnsafeMutableBytes { derivedPtr -> Int32 in
            guard let derivedBase = derivedPtr.baseAddress else { return -1 }
            return password.withUnsafeBytes { passwordPtr -> Int32 in
                guard let passwordBase = passwordPtr.baseAddress else { return -1 }
                return salt.withUnsafeBytes { saltPtr -> Int32 in
                    guard let saltBase = saltPtr.baseAddress else { return -1 }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBase.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBase.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBase.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw CryptoError.keyDerivationFailed
        }

        return derivedKey
    }
}

// MARK: - Constants

private let saltSize = MCZEncryptedData.saltSize
private let nonceSize = MCZEncryptedData.nonceSize
