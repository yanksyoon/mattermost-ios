// T34 — the fenced-code decorator.
//
// Behaviour reference: mattermost/mattermost-mobile @ v2.45.0, app/components/markdown/
// highlighted_code.tsx (the language whitelist) and the Prism light build it uses. This client
// reimplements the *visible* result (keywords, strings, comments, numbers) rather than vendoring a
// grammar — see docs/THIRD_PARTY_NOTICES.md §10.
//
// The invariant that matters most: colouring must be *lossless*. Concatenating the tokens always
// reproduces the block exactly, so a language this file has never heard of, or a half-typed string,
// can only look plainer — never lose or reorder the author's characters.

import XCTest
@testable import Mattermost

final class T34CodeHighlightTests: XCTestCase {

    private func kinds(_ code: String, _ language: String?) -> [(CodeTokenKind, String)] {
        CodeHighlighter.tokens(code: code, language: language).map { ($0.kind, $0.text) }
    }

    private func text(_ code: String, _ language: String?) -> String {
        CodeHighlighter.tokens(code: code, language: language).map(\.text).joined()
    }

    func testSwiftKeywordTypeStringCommentAndNumber() {
        let code = """
        // a note
        struct Post: Codable {
            let count = 42
            let name = "hello"
        }
        """
        let tokens = kinds(code, "swift")
        XCTAssertTrue(tokens.contains { $0.0 == .comment && $0.1 == "// a note" })
        XCTAssertTrue(tokens.contains { $0.0 == .keyword && $0.1 == "struct" })
        XCTAssertTrue(tokens.contains { $0.0 == .keyword && $0.1 == "let" })
        XCTAssertTrue(tokens.contains { $0.0 == .type && $0.1 == "Post" })
        XCTAssertTrue(tokens.contains { $0.0 == .type && $0.1 == "Codable" })
        XCTAssertTrue(tokens.contains { $0.0 == .number && $0.1 == "42" })
        XCTAssertTrue(tokens.contains { $0.0 == .string && $0.1 == "\"hello\"" })
    }

    func testPythonUsesHashCommentsAndTripleQuotedStrings() {
        let code = """
        # comment
        def f():
            '''doc'''
            return None
        """
        let tokens = kinds(code, "python")
        XCTAssertTrue(tokens.contains { $0.0 == .comment && $0.1 == "# comment" })
        XCTAssertTrue(tokens.contains { $0.0 == .keyword && $0.1 == "def" })
        XCTAssertTrue(tokens.contains { $0.0 == .keyword && $0.1 == "return" })
        XCTAssertTrue(tokens.contains { $0.0 == .string && $0.1 == "'''doc'''" })
    }

    func testBashDoesNotTreatAnApostropheAsAComment() {
        let tokens = kinds("echo 'hi' # trailing", "bash")
        XCTAssertTrue(tokens.contains { $0.0 == .string && $0.1 == "'hi'" })
        XCTAssertTrue(tokens.contains { $0.0 == .comment && $0.1 == "# trailing" })
    }

    func testAliasesResolve() {
        XCTAssertEqual(text("const a = 1", "js"), "const a = 1")
        XCTAssertTrue(kinds("const a = 1", "js").contains { $0.0 == .keyword && $0.1 == "const" })
        XCTAssertTrue(kinds("let a = 1", "ts").contains { $0.0 == .keyword && $0.1 == "let" })
        XCTAssertTrue(kinds("x=1  # note", "sh").contains { $0.0 == .comment })
        XCTAssertTrue(kinds("key: value", "yml").allSatisfy { $0.0 == .plain })
    }

    func testAnUnknownLanguageIsOneUntouchedPlainToken() {
        let code = "⚠︎ whatever { } 42"
        let tokens = CodeHighlighter.tokens(code: code, language: "brainfuck")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].kind, .plain)
        XCTAssertEqual(tokens[0].text, code)
    }

    func testNoLanguageIsOneUntouchedPlainToken() {
        let code = "struct Post {}"
        let tokens = CodeHighlighter.tokens(code: code, language: nil)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens[0].text, code)
    }

    func testEmptyCodeHasNoTokens() {
        XCTAssertTrue(CodeHighlighter.tokens(code: "", language: "swift").isEmpty)
    }

    func testUnterminatedStringAndCommentStillEnd() {
        let tokens = kinds("let x = \"unterminated", "swift")
        XCTAssertTrue(tokens.contains { $0.0 == .string && $0.1 == "\"unterminated" })

        let block = kinds("/* never closed", "swift")
        XCTAssertEqual(block.first?.0, .comment)
        XCTAssertEqual(block.first?.1, "/* never closed")
    }

    func testBlockCommentSpansLines() {
        let code = "a /* one\n two */ b"
        let tokens = kinds(code, "swift")
        XCTAssertTrue(tokens.contains { $0.0 == .comment && $0.1.contains("two") })
    }

    /// The invariant: colouring never changes the text.
    func testTokenTextAlwaysReproducesTheInput() {
        let samples: [(String, String)] = [
            ("swift", "struct A: B { let c = 1 /* x */ }\n// tail"),
            ("swift", "let s = \"a \\\"quoted\\\" b\""),
            ("python", "def f(x):\n    '''doc'''\n    return {'k': 1}"),
            ("javascript", "const f = async () => { await g(`t${x}`) };"),
            ("json", "{\"order\": [\"p1\", \"p2\"], \"has_next\": true}"),
            ("bash", "for f in *.swift; do echo \"$f\"; done # done"),
            ("go", "package main\n\nfunc main() { fmt.Println(\"hi\") }"),
            ("sql", "SELECT * FROM posts WHERE id = '1' -- note"),
            ("yaml", "key: value\nlist:\n  - a\n"),
            ("", "no language at all: *** !!!"),
            ("swift", "")
        ]
        for (language, code) in samples {
            XCTAssertEqual(text(code, language.isEmpty ? nil : language), code,
                           "tokens lost characters for \(language): \(code)")
        }
    }

    func testPathologicalInputTerminates() {
        let samples = [
            String(repeating: "\"", count: 200),
            String(repeating: "/*", count: 200),
            String(repeating: "(", count: 500),
            String(repeating: "9", count: 500),
            String(repeating: "\n// x", count: 200)
        ]
        for sample in samples {
            XCTAssertEqual(text(sample, "swift"), sample)
        }
    }
}
