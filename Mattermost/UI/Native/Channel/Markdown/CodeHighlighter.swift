// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0 (162f2560d0e1df073220f7701d5a67cc17c8abeb)
// Files: app/components/markdown/markdown.tsx (a fenced block is rendered by `HighlightedCode`, which
//        runs `react-syntax-highlighter`'s Prism light build with a small language whitelist) and
//        app/components/markdown/highlighted_code.tsx (the whitelist and the per-language switch).
// Licence: Apache-2.0 (this file) — the Prism grammar itself is MIT and is *not* vendored; this is a
// small tokeniser that produces the same three things a reader can see (keywords, strings/comments,
// numbers). docs/THIRD_PARTY_NOTICES.md §10 records that this is a reimplementation, not a port.
//
// Deliberate scope: a fenced block is *decorated*, not compiled. Nothing here understands syntax
// beyond "a word in this language's keyword list", so an unknown or wrong language can only make
// colouring less useful — it can never make a block unreadable, and no input can hang it (every
// branch advances the cursor).

import Foundation

/// What a piece of code text is, for colouring.
enum CodeTokenKind: Equatable, Sendable {
    case plain
    case keyword
    case string
    case number
    case comment
    /// A capitalised identifier in a language where that conventionally means a type (`String`).
    case type
}

/// One coloured run of a fenced code block.
struct CodeToken: Equatable, Sendable {
    var kind: CodeTokenKind
    var text: String
}

/// A small, dependency-free syntax decorator for fenced code blocks.
enum CodeHighlighter {

    /// The token shapes a language file needs. Kept separate from the language table so tests can
    /// assert the *tokeniser* and the *table* independently.
    struct Profile {
        var lineComments: [String] = ["//"]
        var blockComment: (open: String, close: String)? = ("/*", "*/")
        var quoteCharacters: [Character] = ["\"", "'"]
        var tripleQuotes: [String] = []
        var keywords: Set<String> = []
        var capitalisedMeansType: Bool = false
    }

    /// Languages with a profile. Keys are what a fence's info string carries (` ```swift `).
    static let profiles: [String: Profile] = [
        "swift": Profile(
            lineComments: ["//"], blockComment: ("/*", "*/"),
            quoteCharacters: ["\""],
            keywords: ["actor", "associatedtype", "async", "await", "break", "case", "catch", "class",
                       "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
                       "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import",
                       "in", "indirect", "init", "inout", "internal", "is", "let", "nil", "open",
                       "operator", "private", "protocol", "public", "repeat", "return", "self",
                       "static", "struct", "subscript", "super", "switch", "throw", "throws", "true",
                       "try", "typealias", "var", "where", "while"],
            capitalisedMeansType: true),
        "javascript": Profile(
            lineComments: ["//"], blockComment: ("/*", "*/"),
            quoteCharacters: ["\"", "'", "`"],
            keywords: ["async", "await", "break", "case", "catch", "class", "const", "continue",
                       "default", "delete", "do", "else", "export", "extends", "false", "finally",
                       "for", "from", "function", "if", "import", "in", "instanceof", "let", "new",
                       "null", "of", "return", "static", "super", "switch", "this", "throw", "true",
                       "try", "typeof", "undefined", "var", "void", "while", "yield"],
            capitalisedMeansType: true),
        "typescript": Profile(
            lineComments: ["//"], blockComment: ("/*", "*/"),
            quoteCharacters: ["\"", "'", "`"],
            keywords: ["abstract", "any", "as", "async", "await", "boolean", "break", "case", "catch",
                       "class", "const", "continue", "declare", "default", "do", "else", "enum",
                       "export", "extends", "false", "finally", "for", "from", "function", "if",
                       "implements", "import", "in", "interface", "keyof", "let", "namespace", "new",
                       "null", "number", "of", "private", "protected", "public", "readonly", "return",
                       "static", "string", "super", "switch", "this", "throw", "true", "try", "type",
                       "typeof", "undefined", "var", "void", "while", "yield"],
            capitalisedMeansType: true),
        "python": Profile(
            lineComments: ["#"], blockComment: nil,
            quoteCharacters: ["\"", "'"], tripleQuotes: ["\"\"\"", "'''"],
            keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                       "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                       "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                       "raise", "return", "True", "try", "while", "with", "yield"],
            capitalisedMeansType: false),
        "json": Profile(
            lineComments: [], blockComment: nil, quoteCharacters: ["\""], tripleQuotes: [],
            keywords: ["true", "false", "null"], capitalisedMeansType: false),
        "bash": Profile(
            lineComments: ["#"], blockComment: nil, quoteCharacters: ["\"", "'"],
            keywords: ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function",
                       "if", "in", "local", "readonly", "return", "set", "then", "until", "while"],
            capitalisedMeansType: false),
        "go": Profile(
            lineComments: ["//"], blockComment: ("/*", "*/"), quoteCharacters: ["\"", "'", "`"],
            keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else",
                       "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface",
                       "map", "nil", "package", "range", "return", "select", "struct", "switch", "true",
                       "type", "var"],
            capitalisedMeansType: true),
        "java": Profile(
            lineComments: ["//"], blockComment: ("/*", "*/"), quoteCharacters: ["\"", "'"],
            keywords: ["abstract", "boolean", "break", "case", "catch", "class", "continue", "default",
                       "do", "double", "else", "enum", "extends", "false", "final", "finally", "float",
                       "for", "if", "implements", "import", "instanceof", "int", "interface", "long",
                       "new", "null", "package", "private", "protected", "public", "return", "static",
                       "super", "switch", "this", "throw", "throws", "true", "try", "void", "while"],
            capitalisedMeansType: true),
        "kotlin": Profile(
            lineComments: ["//"], blockComment: ("/*", "*/"), quoteCharacters: ["\"", "'"],
            keywords: ["as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if",
                       "in", "interface", "is", "null", "object", "package", "return", "super", "this",
                       "throw", "true", "try", "typealias", "val", "var", "when", "while"],
            capitalisedMeansType: true),
        "yaml": Profile(
            lineComments: ["#"], blockComment: nil, quoteCharacters: ["\"", "'"],
            keywords: ["true", "false", "null", "yes", "no"], capitalisedMeansType: false),
        "sql": Profile(
            lineComments: ["--"], blockComment: ("/*", "*/"), quoteCharacters: ["'"],
            keywords: ["ALTER", "AND", "AS", "ASC", "BY", "CREATE", "DELETE", "DESC", "DISTINCT",
                       "DROP", "FROM", "GROUP", "HAVING", "INSERT", "INTO", "JOIN", "LEFT", "LIMIT",
                       "NOT", "NULL", "ON", "OR", "ORDER", "SELECT", "SET", "TABLE", "UPDATE", "VALUES",
                       "WHERE"],
            capitalisedMeansType: false),
    ]

    /// Aliases a fence may carry (` ```js `, ` ```ts `, ` ```sh `, ` ```yml `).
    static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "node": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "python3": "python",
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
        "yml": "yaml", "kotlin": "kotlin", "kt": "kotlin",
        "golang": "go", "jsonc": "json", "postgres": "sql", "postgresql": "sql",
    ]

    /// Tokenise `code` as `language`. An unknown/absent language yields one `.plain` token whose text
    /// is exactly the input — a fenced block is never dropped or reflowed because of its info string.
    static func tokens(code: String, language: String?) -> [CodeToken] {
        guard let language else { return code.isEmpty ? [] : [CodeToken(kind: .plain, text: code)] }
        let key = language.lowercased()
        let resolved = profiles[key] != nil ? key : aliases[key]
        guard let resolved, let profile = profiles[resolved] else {
            return code.isEmpty ? [] : [CodeToken(kind: .plain, text: code)]
        }
        return tokenise(Array(code), profile: profile)
    }

    private static func tokenise(_ characters: [Character], profile: Profile) -> [CodeToken] {
        var tokens: [CodeToken] = []
        var index = 0

        func append(_ kind: CodeTokenKind, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = tokens.last, last.kind == kind, kind == .plain {
                tokens[tokens.count - 1].text += text
                return
            }
            tokens.append(CodeToken(kind: kind, text: text))
        }

        while index < characters.count {
            let character = characters[index]

            // Line comment: to end of line (the newline itself stays plain so line breaks survive).
            if let prefix = profile.lineComments.first(where: { matches($0, characters, index) }) {
                var end = index + prefix.count
                while end < characters.count, characters[end] != "\n" { end += 1 }
                append(.comment, String(characters[index..<end]))
                index = end
                continue
            }

            // Block comment: to the closing delimiter, or the end of the input.
            if let block = profile.blockComment, matches(block.open, characters, index) {
                var end = index + block.open.count
                while end < characters.count, !matches(block.close, characters, end) { end += 1 }
                end = min(characters.count, end + block.close.count)
                append(.comment, String(characters[index..<end]))
                index = end
                continue
            }

            // Triple-quoted strings before single quotes (Python docstrings).
            if let triple = profile.tripleQuotes.first(where: { matches($0, characters, index) }) {
                var end = index + triple.count
                while end < characters.count, !matches(triple, characters, end) { end += 1 }
                end = min(characters.count, end + triple.count)
                append(.string, String(characters[index..<end]))
                index = end
                continue
            }

            if profile.quoteCharacters.contains(character) {
                let quote = character
                var end = index + 1
                while end < characters.count {
                    if characters[end] == "\\" { end += 2; continue }
                    if characters[end] == quote { end += 1; break }
                    if characters[end] == "\n" { break }        // an unterminated string ends at EOL
                    end += 1
                }
                append(.string, String(characters[index..<min(end, characters.count)]))
                index = min(end, characters.count)
                continue
            }

            if character.isNumber {
                var end = index + 1
                while end < characters.count,
                      characters[end].isNumber || characters[end] == "." || characters[end] == "_"
                        || characters[end] == "x" || characters[end].isHexDigit {
                    end += 1
                }
                append(.number, String(characters[index..<end]))
                index = end
                continue
            }

            if character.isLetter || character == "_" {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber
                        || characters[end] == "_" { end += 1 }
                let word = String(characters[index..<end])
                if profile.keywords.contains(word) {
                    append(.keyword, word)
                } else if profile.capitalisedMeansType, let first = word.first, first.isUppercase {
                    append(.type, word)
                } else {
                    append(.plain, word)
                }
                index = end
                continue
            }

            append(.plain, String(character))
            index += 1
        }
        // Coalesce adjacent plain runs produced by the one-character fallback above.
        var merged: [CodeToken] = []
        for token in tokens {
            if let last = merged.last, last.kind == .plain, token.kind == .plain {
                merged[merged.count - 1].text += token.text
            } else {
                merged.append(token)
            }
        }
        return merged
    }

    private static func matches(_ needle: String, _ characters: [Character], _ start: Int) -> Bool {
        let charactersOfNeedle = Array(needle)
        guard start + charactersOfNeedle.count <= characters.count else { return false }
        for offset in 0..<charactersOfNeedle.count where characters[start + offset] != charactersOfNeedle[offset] {
            return false
        }
        return true
    }
}
