import Foundation
import CommonCrypto
import CryptoKit

/// The few primitives the browsers' password stores need. Nothing here touches the disk or the Keychain.
enum PasswordCrypto {
    enum Cipher { case aes, tripleDES }

    /// CBC with PKCS#7 padding. nil on a wrong key or damaged data (bad padding).
    static func cbc(_ operation: Int, _ cipher: Cipher, key: Data, iv: Data, _ input: Data) -> Data? {
        let algorithm = cipher == .aes ? CCAlgorithm(kCCAlgorithmAES) : CCAlgorithm(kCCAlgorithm3DES)
        let block = cipher == .aes ? kCCBlockSizeAES128 : kCCBlockSize3DES
        guard iv.count == block, !input.isEmpty else { return nil }
        var out = Data(count: input.count + block)
        var written = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(operation), algorithm, CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                inPtr.baseAddress, input.count, outPtr.baseAddress, outCount, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(written)
    }

    static func decrypt(_ cipher: Cipher, key: Data, iv: Data, _ input: Data) -> Data? {
        cbc(kCCDecrypt, cipher, key: key, iv: iv, input)
    }

    static func encrypt(_ cipher: Cipher, key: Data, iv: Data, _ input: Data) -> Data? {
        cbc(kCCEncrypt, cipher, key: key, iv: iv, input)
    }

    enum PRF { case sha1, sha256 }

    static func pbkdf2(_ prf: PRF, password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data? {
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         pw.bindMemory(to: Int8.self).baseAddress, password.count,
                                         s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(prf == .sha1 ? kCCPRFHmacAlgSHA1 : kCCPRFHmacAlgSHA256),
                                         UInt32(iterations), out.bindMemory(to: UInt8.self).baseAddress, keyLength)
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }

    static func hmacSHA1(key: Data, _ data: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
