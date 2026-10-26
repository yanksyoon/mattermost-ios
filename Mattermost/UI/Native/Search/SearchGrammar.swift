// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: `app/screens/home/search/search.tsx` (`getSearchParams`: the terms string is sent as typed
//        after curly quotes are normalised to `"`), `app/screens/home/search/initial/modifiers/`
//        (the modifier chips and their insertion text), `app/utils/markdown/index.ts`
//        (`parseSearchTerms`, the client-side term split the highlighter uses).
// Server contract: https://api.mattermost.com `POST /api/v4/teams/{team_id}/posts/search` — the
// `terms` field is documented as carrying `from:username` and `in:channel-name`.
// User-facing grammar: docs.mattermost.com "Search modifiers" — `from:`, `in:`, `before:`, `after:`,
// `on:` (date typed as YYYY-MM-DD), the `-` exclusion prefix, `"exact phrase"` quotes and a trailing
// `*` wildcard that is invalid at the start or middle of a word.
// Licence: Apache-2.0 — behaviour reimplemented against the public contract; no upstream source
// copied. Attribution: docs/THIRD_PARTY_NOTICES.md §16.
//
// What this file owns: the *composition* of a query string and the *validation* of one, both as pure
// functions. It deliberately does not talk to the server, and it does not decide what a result row
// looks like — `SearchResults.swift` does that.
//
// Measured on the pinned server (Mattermost 9.11.19, build 16643067630, database search backend) by
// `scripts/t39_search_probe.py`:
//  - an empty `terms` answers **400** `Invalid or missing terms in request body.` — that is the one
//    invalid query the server reports itself;
//  - every other malformed query (`before:notadate`, an unclosed quote, a bad wildcard) answers
//    **200 with an empty or unrelated result set**. The server does not tell the client it did not
//    understand the query, so the readable error this card asks for has to come from here.

import Foundation

// MARK: - Modifiers

/// One search modifier the documented grammar supports.
///
/// The raw values are the literal prefixes the server parses (`in:` is a Swift keyword as a case
/// name, hence `inChannel`), so `SearchModifierKind.inChannel.rawValue == "in"` and a query is
/// composed by `kind.token + value`.
enum SearchModifierKind: String, CaseIterable, Hashable, Sendable {
    case from
    case inChannel = "in"
    case before
    case after
    case on

    /// The prefix as typed, colon included.
    var token: String { rawValue + ":" }

    /// What the modifier chip inserts — upstream's `modifiers` row.
    var placeholder: String {
        switch self {
        case .from: return "from:username"
        case .inChannel: return "in:channel"
        case .before: return "before:2026-01-31"
        case .after: return "after:2026-01-31"
        case .on: return "on:2026-01-31"
        }
    }

    /// The chip's label (what the reader taps).
    var title: String {
        switch self {
        case .from: return "From"
        case .inChannel: return "In"
        case .before: return "Before"
        case .after: return "After"
        case .on: return "On"
        }
    }

    /// `before:`/`after:`/`on:` take a date; `from:`/`in:` take a name.
    var takesDate: Bool {
        switch self {
        case .before, .after, .on: return true
        case .from, .inChannel: return false
        }
    }
}

/// One modifier as it appears in a query, including whether the `-` prefix excluded it.
struct SearchModifier: Equatable, Sendable {
    var kind: SearchModifierKind
    /// The value as typed, without the quotes a phrase value may have carried.
    var value: String
    var isNegated: Bool

    /// `from:alice`, or `-in:town-square`.
    var composed: String {
        (isNegated ? "-" : "") + kind.token + value
    }
}

// MARK: - Validation

/// Why a query cannot be sent as typed.
///
/// Each case carries the copy a reader sees. They exist because the server answers 200 to a query it
/// does not understand (see the file comment): without this, `before:notadate` is an empty result
/// list that looks like "no messages matched".
enum SearchQueryIssue: Equatable, Sendable {
    case emptyQuery
    case unterminatedQuote
    case emptyModifier(SearchModifierKind)
    case invalidDate(SearchModifierKind, value: String)
    case misplacedWildcard(term: String)

    /// One sentence, reader-facing, naming what to fix.
    var message: String {
        switch self {
        case .emptyQuery:
            return "Enter something to search for."
        case .unterminatedQuote:
            return "There is an opening \" with no closing one. Close the quote to search for an "
                + "exact phrase."
        case .emptyModifier(let kind):
            return "\(kind.token) needs a value after it — for example \(kind.placeholder)."
        case .invalidDate(let kind, let value):
            return "\(kind.token) needs a date like 2026-01-31 (YYYY-MM-DD); \"\(value)\" is not one."
        case .misplacedWildcard(let term):
            return "The * wildcard only works at the end of a word: rea* is valid, *\(term) and "
                + "re*\(term) are not."
        }
    }
}

// MARK: - Dates

/// The date grammar `before:`/`after:`/`on:` accept.
///
/// Only the documented `YYYY-MM-DD` form. Relative words (`today`, `yesterday`) are **rejected on
/// purpose**: measured on 9.11.19, `on:today` answers 0 results while `on:2026-10-26` answers the
/// posts that exist, i.e. the server silently drops the modifier and the reader gets an empty list
/// with no explanation. Refusing it here turns that silence into a sentence.
enum SearchDate {
    /// `yyyy-MM-dd`, strictly: the round trip rejects a rolled-over date such as `2026-02-31`.
    static func isValid(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

// MARK: - The parsed query

/// A query split into the pieces the client needs: the terms string it will send, and the parts it
/// has to understand for highlighting and validation.
struct SearchParsedQuery: Equatable, Sendable {
    /// The normalised text, exactly what `terms` carries.
    var terms: String
    var words: [String] = []
    /// The words the `-` prefix excluded. Kept apart from `words` because they are *not* search text
    /// to highlight: `-release` means "not this", so painting it would point at the wrong thing.
    var negatedWords: [String] = []
    var phrases: [String] = []
    var modifiers: [SearchModifier] = []
    /// Whether the reader used the `-` exclusion prefix (upstream then sends the same terms; the
    /// server owns the exclusion).
    var hasNegation: Bool = false
    var issues: [SearchQueryIssue] = []

    var isSendable: Bool { issues.isEmpty }
}

// MARK: - The query

/// A composed search request, before it becomes JSON.
struct SearchQuery: Equatable, Sendable {
    /// What the server's `terms` field carries.
    var terms: String
    /// `is_or_search`: the shell's one search is an AND search, exactly as upstream's
    /// `getSearchParams` sends (`is_or_search: false`).
    var isOrSearch: Bool = false
    /// Archived channels are searched, as upstream's `include_deleted_channels: true`.
    var includeDeletedChannels: Bool = true
    /// Offset from UTC in minutes, so `on:` means the reader's day (upstream sends
    /// `new Date().getTimezoneOffset()`).
    var timeZoneOffsetMinutes: Int = 0

    /// The request body for `POST /teams/{team_id}/posts/search`.
    struct Body: Encodable, Equatable {
        var terms: String
        var isOrSearch: Bool
        var timeZoneOffset: Int
        /// Sent, and documented as honoured only by an Elasticsearch backend (`posts.yaml`:
        /// "Only works with Elasticsearch"). On the database backend the server answers the first
        /// window (measured: at most 100 posts, `has_next: false`) whatever these say — the client's
        /// paging state machine still pages, and stops when a page comes back empty.
        var page: Int
        var perPage: Int
        var includeDeletedChannels: Bool

        enum CodingKeys: String, CodingKey {
            case terms
            case isOrSearch = "is_or_search"
            case timeZoneOffset = "time_zone_offset"
            case page
            case perPage = "per_page"
            case includeDeletedChannels = "include_deleted_channels"
        }
    }

    func body(page: Int = 0, perPage: Int = 60) -> Body {
        Body(terms: terms,
             isOrSearch: isOrSearch,
             timeZoneOffset: timeZoneOffsetMinutes,
             page: max(0, page),
             perPage: perPage,
             includeDeletedChannels: includeDeletedChannels)
    }

    /// Compose a query from what the reader typed.
    ///
    /// The one transformation is upstream's: curly quotes become straight ones, because a phone
    /// keyboard (and a copilot's smart quotes) type `“…”` while the server's grammar is `"…"`.
    /// Everything else — modifier spelling, the `-` prefix, the trailing `*` — is sent as typed: the
    /// server parses the string, and a client that rewrote it would be inventing a grammar.
    static func compose(from raw: String,
                        timeZoneOffsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60) -> SearchQuery {
        SearchQuery(terms: normalize(raw), timeZoneOffsetMinutes: timeZoneOffsetMinutes)
    }

    /// Straighten the quotes a phone keyboard produces and collapse whitespace that no longer
    /// separates anything (leading, trailing, and runs *outside* a quoted phrase).
    static func normalize(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\u{201C}", with: "\"")   // “
            .replacingOccurrences(of: "\u{201D}", with: "\"")   // ”
            .replacingOccurrences(of: "\u{201E}", with: "\"")   // „
            .replacingOccurrences(of: "\u{2033}", with: "\"")   // ″
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return collapseWhitespace(text)
    }

    /// Collapse runs of whitespace to one space, leaving the inside of a quoted phrase alone.
    private static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        var inQuote = false
        var pendingSpace = false
        for character in text {
            if character == "\"" {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                inQuote.toggle()
                out.append(character)
                continue
            }
            if character.isWhitespace {
                pendingSpace = !inQuote
                if inQuote { out.append(character) }
                continue
            }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(character)
        }
        return out
    }
}

// MARK: - The parser

/// Splits a query into words, phrases and modifiers, and reports what cannot be sent.
///
/// The scan is deliberately small: whitespace separates tokens, `"` starts/ends a phrase, a leading
/// `-` marks exclusion, and `prefix:value` is a modifier when `prefix` is one of the documented five.
/// Anything else is a word, because that is what the server does with it.
enum SearchQueryParser {

    static func parse(_ raw: String) -> SearchParsedQuery {
        let normalized = SearchQuery.normalize(raw)
        var parsed = SearchParsedQuery(terms: normalized)
        var issues: [SearchQueryIssue] = []
        var sawUnterminatedQuote = false

        var index = normalized.startIndex
        let end = normalized.endIndex

        func skipWhitespace() {
            while index < end, normalized[index].isWhitespace { index = normalized.index(after: index) }
        }

        while index < end {
            skipWhitespace()
            guard index < end else { break }

            var isNegated = false
            if normalized[index] == "-" {
                let next = normalized.index(after: index)
                if next < end, !normalized[next].isWhitespace {
                    isNegated = true
                    index = next
                    parsed.hasNegation = true
                }
            }

            if index < end, normalized[index] == "\"" {
                let start = normalized.index(after: index)
                if let close = normalized[start...].firstIndex(of: "\"") {
                    let phrase = String(normalized[start..<close])
                    parsed.phrases.append(phrase)
                    issues.append(contentsOf: wildcardIssues(in: phrase))
                    index = normalized.index(after: close)
                } else {
                    // Unterminated: keep what was typed as a phrase (so the reader sees which quote
                    // is open in the field) and report it.
                    parsed.phrases.append(String(normalized[start...]))
                    sawUnterminatedQuote = true
                    index = end
                }
                if isNegated { parsed.hasNegation = true }
                continue
            }

            var value = ""
            while index < end, !normalized[index].isWhitespace, normalized[index] != "\"" {
                value.append(normalized[index])
                index = normalized.index(after: index)
            }

            if let colon = value.firstIndex(of: ":") {
                let prefix = String(value[value.startIndex..<colon]).lowercased()
                if let kind = SearchModifierKind(rawValue: prefix) {
                    var modifierValue = String(value[value.index(after: colon)...])
                    if modifierValue.count >= 2, modifierValue.hasPrefix("\""),
                       modifierValue.hasSuffix("\"") {
                        modifierValue = String(modifierValue.dropFirst().dropLast())
                    }
                    parsed.modifiers.append(SearchModifier(kind: kind,
                                                           value: modifierValue,
                                                           isNegated: isNegated))
                    if modifierValue.isEmpty {
                        issues.append(.emptyModifier(kind))
                    } else if kind.takesDate, !SearchDate.isValid(modifierValue) {
                        issues.append(.invalidDate(kind, value: modifierValue))
                    }
                    continue
                }
            }

            if !value.isEmpty {
                // A negated word is still a word the server must see (it is in `terms`), but it is not
                // text to match, so it is kept apart.
                if isNegated {
                    parsed.negatedWords.append(value)
                } else {
                    parsed.words.append(value)
                }
                issues.append(contentsOf: wildcardIssues(in: value))
            }
        }

        if sawUnterminatedQuote { issues.insert(.unterminatedQuote, at: 0) }
        // A query that is only whitespace, or only a stray `-`, has nothing to search for.
        if parsed.words.isEmpty, parsed.negatedWords.isEmpty, parsed.phrases.isEmpty,
           parsed.modifiers.isEmpty {
            issues.append(.emptyQuery)
        }
        parsed.issues = issues
        return parsed
    }

    /// Convenience for the screen: the reader-facing sentences, de-duplicated in a stable order.
    static func issues(in raw: String) -> [SearchQueryIssue] {
        var seen = Set<String>()
        return parse(raw).issues.filter { seen.insert($0.message).inserted }
    }

    /// `*` is only a suffix wildcard: `rea*` is a prefix search, `*each` and `re*ch` are invalid.
    private static func wildcardIssues(in term: String) -> [SearchQueryIssue] {
        guard term.contains("*") else { return [] }
        let isSuffixOnly = term.hasSuffix("*")
            && !term.dropLast().contains("*")
            && term.count > 1
        guard !isSuffixOnly else { return [] }
        let offending = term.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        return [.misplacedWildcard(term: offending.isEmpty ? term : offending)]
    }
}
