import Foundation

/// Just enough ASN.1 DER to read NSS's encrypted blobs: SEQUENCE, OCTET STRING, INTEGER and OBJECT IDENTIFIER.
struct DERNode {
    var tag: UInt8
    var content: Data

    static let sequence: UInt8 = 0x30
    static let octetString: UInt8 = 0x04
    static let integer: UInt8 = 0x02
    static let oid: UInt8 = 0x06

    /// The children of a constructed node (SEQUENCE / SET); nil if the bytes don't parse.
    var children: [DERNode]? {
        guard tag & 0x20 != 0 else { return nil }
        var rest = content
        var out: [DERNode] = []
        while !rest.isEmpty {
            guard let (node, used) = DERNode.read(rest) else { return nil }
            out.append(node)
            rest = rest.dropFirst(used)
        }
        return out
    }

    var intValue: Int? {
        guard tag == DERNode.integer, !content.isEmpty, content.count <= 8 else { return nil }
        return content.reduce(0) { ($0 << 8) | Int($1) }
    }

    /// Parses one node from the start of `data`, returning it and the bytes it used.
    static func read(_ data: Data) -> (DERNode, Int)? {
        let b = Array(data.prefix(10))
        guard b.count >= 2 else { return nil }
        let tag = b[0]
        var length = Int(b[1])
        var header = 2
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard n >= 1, n <= 4, b.count >= 2 + n else { return nil }
            length = b[2..<(2 + n)].reduce(0) { ($0 << 8) | Int($1) }
            header = 2 + n
        }
        guard data.count >= header + length else { return nil }
        let start = data.startIndex + header
        return (DERNode(tag: tag, content: Data(data[start..<(start + length)])), header + length)
    }

    static func parse(_ data: Data) -> DERNode? {
        guard let (node, used) = read(data), used == data.count else { return nil }
        return node
    }
}

/// Object identifiers the NSS key store uses, as DER content bytes.
enum OID {
    /// pbeWithSha1AndTripleDES-CBC (PKCS#12 PBE as NSS applies it)
    static let pbeSHA1TripleDES = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x05, 0x01, 0x03])
    /// PBES2
    static let pbes2 = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D])
    /// PBKDF2
    static let pbkdf2 = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C])
    /// des-ede3-cbc
    static let tripleDESCBC = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x03, 0x07])
    /// aes256-CBC
    static let aes256CBC = Data([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A])
}
