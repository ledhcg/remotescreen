import CryptoKit
import Foundation

public enum LinkIdentityError: Error, Equatable {
    case malformedCertificate(String)
    case keychain(Int32)
    case notFound
    case unsupported(String)
}

/// SHA-256 of a DER `SubjectPublicKeyInfo`: the identity of a device in Screon (the "pin").
public enum SPKIHash {
    public static func hash(spki: Data) -> Data { Data(SHA256.hash(data: spki)) }
}

/// The fields of a Screon certificate that the transport cares about, parsed with bounds checks.
public struct LinkCertificate: Sendable, Equatable {
    public let der: Data
    /// The exact bytes the issuer signed (`tbsCertificate`).
    public let tbsDER: Data
    /// DER `SubjectPublicKeyInfo`.
    public let spkiDER: Data
    public let spkiHash: Data
    /// DER ECDSA signature (SEQUENCE of r, s).
    public let signatureDER: Data
    public let notBefore: Date
    public let notAfter: Date

    /// Parses a DER certificate. Rejects anything that is not a well-formed X.509 v3-shaped structure with an SPKI
    /// and validity; this is deliberately not a full X.509 validator (trust comes from the pin, not a chain).
    public init(der: Data) throws {
        do {
            var top = try DERReader(der)
            let cert = try top.next(expecting: DER.sequenceTag)
            guard top.isAtEnd else { throw DERError.malformed("trailing data") }
            var certReader = top.reader(for: cert)
            let tbs = try certReader.next(expecting: DER.sequenceTag)
            _ = try certReader.next(expecting: DER.sequenceTag)  // signatureAlgorithm
            let sig = try certReader.next(expecting: DER.bitStringTag)
            guard certReader.isAtEnd, sig.content.count >= 2, top.bytes[sig.content.lowerBound] == 0 else {
                throw DERError.malformed("bad signature")
            }
            var t = top.reader(for: tbs)
            var first = try t.next()
            if first.tag == 0xA0 { first = try t.next() }  // optional explicit version
            guard first.tag == DER.integerTag else { throw DERError.malformed("serial") }
            _ = try t.next(expecting: DER.sequenceTag)  // signature alg
            _ = try t.next(expecting: DER.sequenceTag)  // issuer
            let validity = try t.next(expecting: DER.sequenceTag)
            _ = try t.next(expecting: DER.sequenceTag)  // subject
            let spki = try t.next(expecting: DER.sequenceTag)

            var v = top.reader(for: validity)
            let nb = try v.next()
            let na = try v.next()
            guard v.isAtEnd else { throw DERError.malformed("validity") }
            let nbDate = try Self.parseTime(nb, in: top.bytes)
            let naDate = try Self.parseTime(na, in: top.bytes)

            self.der = der
            self.tbsDER = Data(top.bytes[tbs.full])
            self.spkiDER = Data(top.bytes[spki.full])
            self.spkiHash = SPKIHash.hash(spki: Data(top.bytes[spki.full]))
            self.signatureDER = Data(top.bytes[(sig.content.lowerBound + 1)..<sig.content.upperBound])
            self.notBefore = nbDate
            self.notAfter = naDate
        } catch let e as DERError {
            if case .malformed(let m) = e { throw LinkIdentityError.malformedCertificate(m) }
            throw e
        }
    }

    private static func parseTime(_ e: DERReader.Element, in bytes: [UInt8]) throws -> Date {
        let s = String(decoding: bytes[e.content], as: UTF8.self)
        let digits: String
        let year: Int
        switch e.tag {
        case DER.utcTimeTag:
            guard s.count == 13, s.hasSuffix("Z") else { throw DERError.malformed("time") }
            digits = String(s.dropLast())
            guard let yy = Int(digits.prefix(2)) else { throw DERError.malformed("time") }
            year = yy >= 50 ? 1900 + yy : 2000 + yy
            return try build(year: year, rest: String(digits.dropFirst(2)))
        case DER.generalizedTimeTag:
            guard s.count == 15, s.hasSuffix("Z") else { throw DERError.malformed("time") }
            digits = String(s.dropLast())
            guard let y = Int(digits.prefix(4)) else { throw DERError.malformed("time") }
            return try build(year: y, rest: String(digits.dropFirst(4)))
        default:
            throw DERError.malformed("time tag")
        }
    }

    private static func build(year: Int, rest: String) throws -> Date {
        guard rest.count == 10, rest.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw DERError.malformed("time") }
        let n = rest.compactMap { Int(String($0)) }
        func two(_ i: Int) -> Int { n[i] * 10 + n[i + 1] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var c = DateComponents()
        c.year = year; c.month = two(0); c.day = two(2); c.hour = two(4); c.minute = two(6); c.second = two(8)
        guard (1...12).contains(c.month!), (1...31).contains(c.day!), c.hour! < 24, c.minute! < 60, c.second! < 61,
              let d = cal.date(from: c) else { throw DERError.malformed("time value") }
        return d
    }

    /// True once 80 % of the validity period has elapsed (or the certificate is expired / not yet valid).
    public func needsRotation(now: Date = Date()) -> Bool {
        let total = notAfter.timeIntervalSince(notBefore)
        guard total > 0 else { return true }
        return now.timeIntervalSince(notBefore) >= total * 0.8 || now < notBefore
    }
}
