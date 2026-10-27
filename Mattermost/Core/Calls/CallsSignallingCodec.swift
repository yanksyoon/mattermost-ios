// The Calls `sdp` action's framing. Measured, not designed (docs/t44-build-note.md §5.1, correction
// C1): the plugin type-asserts the payload to `[]byte`
// (`server/websocket.go` `msgData, ok := req.Data["data"].([]byte)` — `:1226` at 0.29.8, `:1350` at
// 1.x), and the core server's JSON decoder can only produce a `string` for a text frame, so the
// frame is dropped with the server-side log `invalid or missing sdp data` and the session dies at
// the 10 s signalling timeout. Two things follow:
//
//   1. the frame must be **MessagePack** (the core socket decodes a binary frame with msgpack —
//      `web_conn.go:479-483`), and `data.data` must be a msgpack **bin**, not a str;
//   2. the SDP inside must be **zlib** (RFC 1950) of `JSON.stringify({type, sdp})`, because the
//      plugin unpacks it with Go's `zlib.NewReader` (`server/utils.go unpackSDPData`).
//
// Apple's `COMPRESSION_ZLIB` is raw DEFLATE, not the RFC 1950 wrapper, so Go's reader will not
// accept it — hence libz (`import zlib`) rather than the Compression framework.
//
// Validated against CPython's `zlib.decompress` and a reference MessagePack decoder before being
// wired into the app (docs/t44c-build-note.md §3); the committed unit test holds the same fixtures.

import Foundation
import zlib

/// A minimal MessagePack encoder: exactly the value kinds a socket frame needs (map / str / int /
/// bin / array / bool / null). Deliberately not a general codec — the plugin only ever sees this one
/// shape, and a smaller surface is a smaller thing to get wrong.
///
/// Maps are **ordered arrays of pairs**, so encoding is deterministic (the unit test asserts exact
/// bytes rather than "some valid msgpack").
enum CallsMessagePack {

    indirect enum Value {
        case map([(String, Value)])
        case array([Value])
        case string(String)
        case int(Int)
        case bool(Bool)
        case binary(Data)
        case null
    }

    static func encode(_ value: Value) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func write(_ value: Value, into out: inout Data) {
        switch value {
        case .null:
            out.append(0xC0)
        case .bool(let flag):
            out.append(flag ? 0xC3 : 0xC2)

        case .int(let n):
            if n >= 0 && n < 128 {
                out.append(UInt8(n))
            } else if n >= 0 && n < 65_536 {
                out.append(0xCD)
                appendBigEndian(UInt64(n), bytes: 2, into: &out)
            } else if n >= 0 && n < 4_294_967_296 {
                out.append(0xCE)
                appendBigEndian(UInt64(n), bytes: 4, into: &out)
            } else {
                out.append(0xD3)
                appendBigEndian(UInt64(bitPattern: Int64(n)), bytes: 8, into: &out)
            }

        case .string(let text):
            let bytes = Data(text.utf8)
            let count = bytes.count
            if count < 32 {
                out.append(0xA0 | UInt8(count))
            } else if count < 256 {
                out.append(0xD9)
                out.append(UInt8(count))
            } else if count < 65_536 {
                out.append(0xDA)
                appendBigEndian(UInt64(count), bytes: 2, into: &out)
            } else {
                out.append(0xDB)
                appendBigEndian(UInt64(count), bytes: 4, into: &out)
            }
            out.append(bytes)

        case .binary(let data):
            let count = data.count
            if count < 256 {
                out.append(0xC4)
                out.append(UInt8(count))
            } else if count < 65_536 {
                out.append(0xC5)
                appendBigEndian(UInt64(count), bytes: 2, into: &out)
            } else {
                out.append(0xC6)
                appendBigEndian(UInt64(count), bytes: 4, into: &out)
            }
            out.append(data)

        case .array(let values):
            if values.count < 16 {
                out.append(0x90 | UInt8(values.count))
            } else {
                out.append(0xDC)
                appendBigEndian(UInt64(values.count), bytes: 2, into: &out)
            }
            for value in values { write(value, into: &out) }

        case .map(let pairs):
            if pairs.count < 16 {
                out.append(0x80 | UInt8(pairs.count))
            } else {
                out.append(0xDE)
                appendBigEndian(UInt64(pairs.count), bytes: 2, into: &out)
            }
            for (key, value) in pairs {
                write(.string(key), into: &out)
                write(value, into: &out)
            }
        }
    }

    private static func appendBigEndian(_ value: UInt64, bytes: Int, into out: inout Data) {
        for index in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
            out.append(UInt8((value >> UInt64(index)) & 0xFF))
        }
    }
}

/// The `sdp` action's payload: zlib(RFC 1950) over `JSON({type, sdp})`.
enum CallsSDPCodec {

    enum CodecError: Error, Equatable, CustomStringConvertible {
        case compressionFailed(Int32)
        case decompressionFailed(Int32)
        case notJSON

        var description: String {
            switch self {
            case .compressionFailed(let code): return "zlib deflate failed (\(code))"
            case .decompressionFailed(let code): return "zlib inflate failed (\(code))"
            case .notJSON: return "the inflated payload is not a JSON description"
            }
        }
    }

    /// What the client sends: zlib of the description's JSON.
    static func pack(_ description: CallsSessionDescription) throws -> Data {
        try deflate(description.jsonBody)
    }

    /// What a peer that compresses at us would send. The deployed SFU does **not** compress its own
    /// signalling (`websocket.go` publishes `string(msg.Data)`, plain JSON), so this path is used by
    /// the conformance check and the unit test against a Go/CPython-produced fixture — it is what
    /// proves our framing matches `zlib.NewReader`, in both directions.
    static func unpack(_ data: Data) throws -> CallsSessionDescription {
        let body = try inflate(data)
        guard let text = String(data: body, encoding: .utf8) else { throw CodecError.notJSON }
        do {
            return try CallsSessionDescription(json: text)
        } catch {
            throw CodecError.notJSON
        }
    }

    /// The frame the socket must send for one description: `{seq, action: <sdp>, data: {data: <bin>}}`.
    static func sdpFrame(seq: Int, description: CallsSessionDescription) throws -> Data {
        let packed = try pack(description)
        return CallsMessagePack.encode(.map([
            ("seq", .int(seq)),
            ("action", .string(CallsProtocol.Action.sdp.wireValue)),
            ("data", .map([("data", .binary(packed))])),
        ]))
    }

    // MARK: - zlib

    /// RFC 1950 deflate (`deflateInit_` → `deflate(Z_FINISH)`), i.e. what Go's `zlib.NewReader`
    /// accepts. Not `Compression.framework`'s `COMPRESSION_ZLIB`, which is raw DEFLATE.
    static func deflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        let initResult = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, zlibVersion(),
                                      Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw CodecError.compressionFailed(initResult) }
        defer { deflateEnd(&stream) }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let capacity = chunk.count
        let ok: Bool = input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return false }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            var status: Int32 = Z_OK
            repeat {
                chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    status = zlib.deflate(&stream, Z_FINISH)
                    let produced = capacity - Int(stream.avail_out)
                    if produced > 0, let bytes = buffer.bindMemory(to: UInt8.self).baseAddress {
                        output.append(bytes, count: produced)
                    }
                }
            } while status == Z_OK
            return status == Z_STREAM_END
        }
        guard ok else { throw CodecError.compressionFailed(-1) }
        return output
    }

    /// RFC 1950 inflate (`inflateInit_` → `inflate`), growing the buffer until `Z_STREAM_END`.
    static func inflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        let initResult = inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { throw CodecError.decompressionFailed(initResult) }
        defer { inflateEnd(&stream) }

        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let capacity = chunk.count
        let ok: Bool = input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return false }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            var status: Int32 = Z_OK
            while true {
                var produced = 0
                chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(capacity)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    produced = capacity - Int(stream.avail_out)
                    if produced > 0, let bytes = buffer.bindMemory(to: UInt8.self).baseAddress {
                        output.append(bytes, count: produced)
                    }
                }
                if status == Z_STREAM_END { return true }
                if status != Z_OK && status != Z_BUF_ERROR { return false }
                if produced == 0 && status == Z_BUF_ERROR { return false }
            }
        }
        guard ok else { throw CodecError.decompressionFailed(-1) }
        return output
    }

    /// True when the bytes carry the RFC 1950 header (CMF `0x78`, `(CMF<<8|FLG) % 31 == 0`). Used by
    /// the conformance check to tell a zlib stream from raw DEFLATE — the mistake the card warns
    /// about, and one that is invisible until Go refuses the frame.
    static func hasZlibWrapper(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let cmf = Int(data[data.startIndex])
        let flg = Int(data[data.startIndex + 1])
        return cmf & 0x0F == 8 && (cmf * 256 + flg) % 31 == 0
    }
}
