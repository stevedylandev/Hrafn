import Foundation

/// The slice of the Protocol Buffers encoding (protobuf.dev, "Encoding") that
/// the OMEMO messages use: varint (wire type 0) and length-delimited (wire
/// type 2) fields. Hand-written so the package needs no protobuf runtime.
struct ProtobufWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        tag(field, wireType: 0)
        writeVarint(value)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, wireType: 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    private mutating func tag(_ field: Int, wireType: UInt64) {
        writeVarint(UInt64(field) << 3 | wireType)
    }

    private mutating func writeVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }
}

/// Parses a message into its fields. Unknown fields are skipped, as the
/// encoding allows; for a repeated scalar the last value wins.
struct ProtobufReader {
    private(set) var varints: [Int: UInt64] = [:]
    private(set) var bytes: [Int: Data] = [:]

    init(_ data: Data) throws {
        let input = [UInt8](data)
        var offset = 0

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard offset < input.count else { throw OMEMOCryptoError.malformed }
                let byte = input[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << UInt64(shift)
                if byte & 0x80 == 0 { return result }
            }
            throw OMEMOCryptoError.malformed
        }

        while offset < input.count {
            let key = try readVarint()
            let field = Int(truncatingIfNeeded: key >> 3)
            guard field > 0 else { throw OMEMOCryptoError.malformed }
            switch key & 0x7 {
            case 0:
                varints[field] = try readVarint()
            case 1:
                guard input.count - offset >= 8 else { throw OMEMOCryptoError.malformed }
                offset += 8
            case 2:
                let length = try readVarint()
                guard length <= UInt64(input.count - offset) else { throw OMEMOCryptoError.malformed }
                bytes[field] = Data(input[offset..<offset + Int(length)])
                offset += Int(length)
            case 5:
                guard input.count - offset >= 4 else { throw OMEMOCryptoError.malformed }
                offset += 4
            default:
                throw OMEMOCryptoError.malformed
            }
        }
    }

    func uint32(_ field: Int) throws -> UInt32? {
        guard let value = varints[field] else { return nil }
        guard let narrowed = UInt32(exactly: value) else { throw OMEMOCryptoError.malformed }
        return narrowed
    }
}
