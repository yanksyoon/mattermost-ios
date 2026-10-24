import Foundation

/// A loss-free `Codable` representation of an arbitrary JSON value.
///
/// The transport layer needs it in two places where Mattermost's contract is genuinely untyped:
///
///  - **`post.props` / `post.metadata`** — an open bag whose shape depends on the plugin or the
///    feature (attachments, priority, calls, …). Typing it here would fork the API contract.
///  - **WebSocket v4 `data`** — a per-event object, and for `posted` / `post_edited` /
///    `post_deleted` / `reaction_added` the payload is a *JSON string inside* the object. The
///    frame decoder keeps the value untyped and re-decodes it into the typed model.
///
/// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0,
/// `app/client/websocket/index.ts` (the `msg.data` shapes) — own implementation per
/// docs/path-b-adr.md §3.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                  debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var int64Value: Int64? {
        switch self {
        case .number(let value): return Int64(value)
        case .string(let value): return Int64(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Convenience subscript for the object case (`data["post"]`).
    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// A JSON object as a plain Foundation graph, for `JSONSerialization`.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map { $0.foundationValue }
        case .object(let value): return value.mapValues { $0.foundationValue }
        }
    }

    /// A deterministic textual form (object keys sorted). Used to build WebSocket dedupe keys:
    /// a replayed frame must produce the same key byte-for-byte, so dictionary iteration order
    /// cannot leak into the comparison.
    func canonicalString() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: foundationValue,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: self)
        }
        return text
    }
}

/// An untyped JSON payload that can be re-decoded into a typed model on demand.
///
/// `MMSocketFrame.data` is this: the envelope decoder keeps `data` as a value, and the event
/// decoder asks for `MMPost`, `[MMPreference]`, etc. only once it knows the event name.
struct MMRawJSON: Codable, Equatable, Sendable {
    let value: JSONValue

    init(_ value: JSONValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        self.value = try JSONValue(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    /// Re-decode this payload into a typed model. Throws `DecodingError`/`MMError` upstream.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }

    subscript(key: String) -> JSONValue? { value[key] }
}
