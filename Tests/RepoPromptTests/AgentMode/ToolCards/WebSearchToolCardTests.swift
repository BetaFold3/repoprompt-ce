@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class WebSearchToolCardTests: XCTestCase {
    func testWebSearchNamesStayDistinctFromFileSearchAndRouteAsKnownResult() {
        for alias in ["search", "web_search", "web_search_request", "google_web_search", "search_web", "websearch"] {
            XCTAssertEqual(normalizedToolCardName(alias), "search", alias)
            XCTAssertEqual(AgentToolResultPersistencePolicy.normalizedToolName(alias), "search", alias)
        }
        for alias in ["webfetch", "web_fetch", "browser_open", "browser.open", "open_url"] {
            XCTAssertEqual(normalizedToolCardName(alias), "web_read", alias)
            XCTAssertEqual(AgentToolResultPersistencePolicy.normalizedToolName(alias), "web_read", alias)
        }
        for alias in ["file_search", "filesearch", "grep"] {
            XCTAssertEqual(AgentToolResultPersistencePolicy.normalizedToolName(alias), "file_search", alias)
        }
        XCTAssertTrue(ToolCardRouter.knownResultTools.contains("search"))
    }

    func testCanonicalToolCardNameMatchesLegacyClassificationAcrossCandidateEdgeCases() {
        let corpus: [String?] = [
            nil, "", "   ", "\n\t", ".", "..",
            "search", "web_search", "WEB-SEARCH", " Web Search ", "google_web_search", "Search_Web", "WebSearch",
            "WebFetch", "web-fetch", "web read", "browser.open", "Browser.Open", "browser_open", "read web page",
            "functions.web_search", "tools.browser.open", "ns.WebFetch", "a.b.search", "web_search.", "search.web_fetch",
            "web_fetch.search", "foo.\tweb_search", "foo.\nwebfetch", "foo.\u{00A0}web_fetch", "foo. web_search",
            "foo.\tweb_search\t", "mcp__RepoPrompt__web_search", "mcp__repoprompt__web_search", "mcp__RepoPromptCE__web_search",
            "xmcp__RepoPrompt__webfetchmcp__RepoPrompt__", "mcp__RepoPrompt__mcp__RepoPrompt__search",
            "mcp__RepoPrompt__ns.open_url", "file_search", "read_file", "grep", "bash", "exec_command",
            "\u{FF37}\u{FF25}\u{FF22}_search", "\u{0130}search", "web_search\u{0130}", "web_searc\u{0048}\u{0301}",
            "S\u{0045}ARCH", "\u{212A}", "web\u{2010}search"
        ]
        for raw in corpus {
            let label = String(reflecting: raw)
            XCTAssertEqual(
                AgentWebToolCanonicalNames.canonicalToolCardName(raw),
                legacyCanonicalToolCardName(raw),
                label
            )
            guard let raw else { continue }
            XCTAssertEqual(AgentWebToolCanonicalNames.isWebSearchName(raw), legacyIsWebSearchName(raw), label)
            XCTAssertEqual(AgentWebToolCanonicalNames.isWebReadName(raw), legacyIsWebReadName(raw), label)
        }
        // Pinned outcomes so a defect shared with the legacy copy cannot pass silently.
        XCTAssertEqual(AgentWebToolCanonicalNames.canonicalToolCardName("foo.\tweb_search"), "search")
        XCTAssertEqual(AgentWebToolCanonicalNames.canonicalToolCardName("foo.\u{00A0}web_fetch"), "web_read")
        XCTAssertEqual(AgentWebToolCanonicalNames.canonicalToolCardName("web_fetch.search"), "search")
        XCTAssertEqual(AgentWebToolCanonicalNames.canonicalToolCardName("mcp__RepoPrompt__WebFetch"), "web_read")
        // Pre-existing behavior: RepoPrompt prefix stripping is case-sensitive.
        XCTAssertNil(AgentWebToolCanonicalNames.canonicalToolCardName("mcp__repoprompt__webfetch"))
        XCTAssertNil(AgentWebToolCanonicalNames.canonicalToolCardName("  "))
        XCTAssertTrue(AgentWebToolCanonicalNames.isWebSearchName(" Web-Search "))
        XCTAssertTrue(AgentWebToolCanonicalNames.isWebReadName("\tBrowser.Open\n"))
        XCTAssertFalse(AgentWebToolCanonicalNames.isWebSearchName("file_search"))
    }

    func testVisibleToolNameKnownNonWebAliasesAreDisjointFromWebClassification() {
        let knownAliases: [(alias: String, expected: String)] = [
            ("readfile", "read_file"), ("read_file", "read_file"), ("read_file_tool", "read_file"),
            ("read_file_contents", "read_file"), ("file_search", "file_search"), ("filesearch", "file_search"),
            ("grep", "file_search"), ("bash", "bash"), ("shell", "bash"), ("local_shell", "bash"),
            ("unified_exec", "bash"), ("exec", "bash"), ("exec_command", "bash"), ("run_shell_command", "bash"),
            ("command", "bash"), ("filechange", "apply_patch"), ("file_change", "apply_patch")
        ]
        for (alias, expected) in knownAliases {
            // Disjointness: matching these aliases before web classification cannot change a result.
            XCTAssertNil(AgentWebToolCanonicalNames.canonicalToolCardName(alias), alias)
            XCTAssertNil(legacyCanonicalToolCardName(alias), alias)
            XCTAssertEqual(AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(alias), expected, alias)
        }
        let variants: [(raw: String?, expected: String?)] = [
            (nil, nil), ("  ", nil), ("  Exec-Command \n", "bash"), ("Run Shell Command", "bash"),
            ("File-Change", "apply_patch"), ("READFILE", "read_file"), ("Web-Search", "search"),
            ("functions.web_search", "search"), ("browser.open", "web_read"), ("tools.WebFetch", "web_read"),
            ("foo.\tweb_fetch", "web_read"), ("x.bash", "x.bash"), ("custom_tool", "custom_tool")
        ]
        for (raw, expected) in variants {
            XCTAssertEqual(
                AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(raw),
                expected,
                String(reflecting: raw)
            )
        }
    }

    func testPathLikeToolNamesKeepPathSignalAndVisibleNameOutcomes() {
        let cases: [(raw: String?, pathSignal: String?, visible: String?)] = [
            (nil, nil, nil), ("", nil, nil), ("  \n", nil, nil),
            // Recognized RepoPrompt, native, and web/dotted aliases are never paths.
            ("mcp__RepoPromptCE__read_file", nil, "read_file"), ("mcp__RepoPromptCE__git", nil, "git"),
            ("Read-File", nil, "read_file"), ("Bash", nil, "bash"), ("grep", nil, "file_search"),
            ("browser.open", nil, "web_read"), ("tools.WebFetch", nil, "web_read"),
            ("foo.\tweb_fetch", nil, "web_read"), ("functions.web_search", nil, "search"),
            // Relative paths (backslashes normalized) and known extensions read as files.
            ("Sources\\App\\Main.swift", "Sources/App/Main.swift", "read_file"),
            ("src/main.ts", "src/main.ts", "read_file"), ("a/b", "a/b", "read_file"),
            ("  docs/Guide.md \n", "docs/Guide.md", "read_file"), ("README.md", "README.md", "read_file"),
            ("Main.SWIFT", "Main.SWIFT", "read_file"), ("tools/web_fetch", "tools/web_fetch", "read_file"),
            ("\u{00DC}n\u{00EF}code/F\u{00EF}le.swift", "\u{00DC}n\u{00EF}code/F\u{00EF}le.swift", "read_file"),
            // Absolute, home, URL, spaced, unknown-extension, and extension-only names are not paths.
            ("/abs/path.swift", nil, "/abs/path.swift"), ("\\abs\\path.swift", nil, "\\abs\\path.swift"),
            ("~/notes.md", nil, "~/notes.md"), ("https://example.com/a.md", nil, "https://example.com/a.md"),
            ("my file.swift", nil, "my_file.swift"), ("src\\file with space.swift", nil, "src\\file_with_space.swift"),
            ("notes.exe", nil, "notes.exe"), (".swift", nil, ".swift"), ("x.bash", nil, "x.bash"),
            ("F\u{00EF}le.SW\u{0130}FT", nil, "F\u{00EF}le.SW\u{0130}FT".lowercased()), ("tool", nil, "tool")
        ]
        for (raw, pathSignal, visible) in cases {
            let label = String(reflecting: raw)
            XCTAssertEqual(AgentTranscriptToolVisibilityPolicy.pathSignal(fromPathLikeToolName: raw), pathSignal, label)
            XCTAssertEqual(AgentTranscriptToolVisibilityPolicy.isPathLikeToolName(raw), pathSignal != nil, label)
            XCTAssertEqual(AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(raw), visible, label)
        }
    }

    func testWebActionClassifierDistinguishesSearchReadFindAndCodeSearch() throws {
        XCTAssertEqual(webPresentation(toolName: "search", args: ["query": "native web search cards"])?.title, "Web Search")

        let searchWithSources = webPresentation(
            toolName: "search",
            args: ["query": "native web search cards"],
            result: ["sources": [["url": "https://example.com/source"]]]
        )
        XCTAssertEqual(searchWithSources?.title, "Web Search")

        let resultOnlyURL = webPresentation(toolName: "search", result: ["url": "https://example.com/page"])
        XCTAssertEqual(resultOnlyURL?.title, "Web Search")

        let read = try XCTUnwrap(webPresentation(toolName: "webfetch", args: ["url": "https://docs.example.com/a/b/c"]), "webfetch read")
        XCTAssertEqual(read.title, "Read Web Page")
        XCTAssertEqual(read.subtitle, "docs.example.com/…/c")

        XCTAssertEqual(webPresentation(toolName: "browser_open", args: ["url": "https://example.com/docs"])?.title, "Read Web Page")
        XCTAssertEqual(webPresentation(toolName: "browser.open", args: ["url": "https://example.com/docs"])?.title, "Read Web Page")
        XCTAssertEqual(webPresentation(toolName: "search", args: ["url": "https://example.com/docs", "action": "open"])?.title, "Read Web Page")

        let find = try XCTUnwrap(webPresentation(toolName: "search", args: ["url": "https://example.com/docs", "pattern": "install"]), "search find")
        XCTAssertEqual(find.title, "Find In Page")
        XCTAssertTrue(find.subtitle?.contains("example.com/docs") == true)
        XCTAssertTrue(find.subtitle?.contains("install") == true)
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/docs", "needle": "API"])?.title, "Find In Page")
        XCTAssertEqual(webPresentation(toolName: "search", args: ["pattern": "install"])?.title, "Web Search")
        XCTAssertNil(webPresentation(toolName: "file_search", args: ["pattern": "TODO", "path": "Sources"]))
        XCTAssertNil(webPresentation(toolName: "grep", args: ["pattern": "TODO"]))
        XCTAssertNil(webPresentation(toolName: "webfetch", args: ["uri": "file:///tmp/x", "pattern": "TODO"]))
        XCTAssertEqual(webPresentation(toolName: "search", result: ["results": [["url": "https://example.com/result"]]])?.title, "Web Search")
    }

    func testNestedTaggedWebActionsClassifySearchOpenAndFind() throws {
        let search = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["action": ["type": "search", "query": "nested query"]]
        ))
        XCTAssertEqual(search.title, "Web Search")
        XCTAssertEqual(search.subtitle, "\"nested query\"")

        let multiSearch = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["action": ["type": "search", "queries": ["first query", "second query"]]]
        ))
        XCTAssertEqual(multiSearch.title, "Web Search")
        XCTAssertEqual(multiSearch.subtitle, "\"first query ...\"")

        let open = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["action": ["type": "openPage", "url": "https://example.com/docs"]]
        ))
        XCTAssertEqual(open.title, "Read Web Page")
        XCTAssertEqual(open.subtitle, "example.com/docs")

        let find = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["action": ["type": "findInPage", "url": NSNull(), "pattern": "install"]]
        ))
        XCTAssertEqual(find.title, "Find In Page")
        XCTAssertEqual(find.subtitle, "\"install\"")
        XCTAssertEqual(
            webPresentation(toolName: "search", args: ["action": "find_in_page", "pattern": "install"])?.title,
            "Find In Page"
        )

        for query in [
            "https://example.com/docs",
            "'installation' in https://example.com/docs"
        ] {
            let authoritativeSearch = try XCTUnwrap(webPresentation(
                toolName: "search",
                args: ["query": query, "action": ["type": "search", "query": query]]
            ), query)
            XCTAssertEqual(authoritativeSearch.title, "Web Search", query)
            XCTAssertEqual(authoritativeSearch.op, "search", query)
        }
    }

    func testCodexSearchQueryGrammarRecognizesReadAndFindInPage() throws {
        let read = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "https://www.theguardian.com/europe"]
        ))
        XCTAssertEqual(read.title, "Read Web Page")
        XCTAssertEqual(read.subtitle, "www.theguardian.com/europe")
        XCTAssertEqual(read.op, "read_web_page")

        let normalizedOnlyRead = try XCTUnwrap(AgentWebToolActionPresentation.classify(AgentWebToolActionInput(
            rawToolName: "codex_web_search",
            normalizedToolName: "search",
            argsObject: ["query": "https://example.com/docs"],
            resultObject: nil
        )))
        XCTAssertEqual(normalizedOnlyRead.title, "Read Web Page")
        XCTAssertEqual(normalizedOnlyRead.subtitle, "example.com/docs")

        let quotedFind = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "'Netherlands' in https://www.theguardian.com/europe"]
        ))
        XCTAssertEqual(quotedFind.title, "Find In Page")
        XCTAssertEqual(quotedFind.subtitle, "www.theguardian.com/europe • \"Netherlands\"")
        XCTAssertEqual(quotedFind.op, "find_in_page")

        let unquotedFind = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "Netherlands in https://www.theguardian.com/europe"]
        ))
        XCTAssertEqual(unquotedFind.title, "Find In Page")
        XCTAssertEqual(unquotedFind.subtitle, "www.theguardian.com/europe • \"Netherlands\"")

        let curlyPossessiveFind = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "teachers’ in https://example.com"]
        ))
        XCTAssertEqual(curlyPossessiveFind.title, "Find In Page")
        XCTAssertEqual(curlyPossessiveFind.subtitle, "example.com • \"teachers’\"")

        let straightPossessiveFind = try XCTUnwrap(webPresentation(
            toolName: "search",
            args: ["query": "dogs' in https://example.com"]
        ))
        XCTAssertEqual(straightPossessiveFind.title, "Find In Page")
        XCTAssertEqual(straightPossessiveFind.subtitle, "example.com • \"dogs'\"")
    }

    func testCodexSearchQueryGrammarKeepsOrdinaryURLMentionsAsWebSearchAndExcludesCodeSearch() throws {
        for query in [
            "Netherlands https://www.theguardian.com/europe",
            "https://www.theguardian.com/europe Netherlands",
            "site:https://www.theguardian.com/europe Netherlands",
            "Netherlands in https://www.theguardian.com/europe latest news"
        ] {
            let presentation = try XCTUnwrap(webPresentation(toolName: "search", args: ["query": query]), query)
            XCTAssertEqual(presentation.title, "Web Search", query)
            XCTAssertEqual(presentation.op, "search", query)
        }

        XCTAssertNil(webPresentation(toolName: "file_search", args: ["query": "https://example.com/docs"]))
        XCTAssertNil(webPresentation(toolName: "grep", args: ["query": "'needle' in https://example.com/docs"]))
    }

    func testWebActionSubtitleFormatting() throws {
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com"])?.subtitle, "example.com")
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/docs/api?token=secret#section"])?.subtitle, "example.com/docs/api")
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/docs/api/"])?.subtitle, "example.com/docs/api")
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/a/b/c/d"])?.subtitle, "example.com/…/d")
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["url": "https://example.com/docs/Swift%20API"])?.subtitle, "example.com/docs/Swift API")
        let longURL = "https://example.com/docs/" + String(repeating: "very-long-component-", count: 8)
        XCTAssertLessThanOrEqual(try XCTUnwrap(webPresentation(toolName: "webfetch", args: ["url": longURL])?.subtitle).count, 80)
        XCTAssertEqual(webPresentation(toolName: "webfetch", args: ["ref_id": "abc123"])?.subtitle, "ref abc123")
        XCTAssertTrue(try XCTUnwrap(webPresentation(toolName: "webfetch", args: ["ref_id": "abcdefghijklmnopqrstuvwxyz0123456789"])?.subtitle).contains("…"))
    }

    func testRunningCallPresentationUsesWebActionLabels() throws {
        let readItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "webfetch",
            toolArgsJSON: jsonString(["url": "https://docs.example.com/a/b/c"])
        )
        let read = try XCTUnwrap(ToolCardRouter.callPresentation(for: readItem))
        XCTAssertEqual(read.title, "Read Web Page")
        XCTAssertEqual(read.subtitle, "docs.example.com/…/c")

        let findItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "search",
            toolArgsJSON: jsonString(["url": "https://example.com/docs", "pattern": "needle"])
        )
        let find = try XCTUnwrap(ToolCardRouter.callPresentation(for: findItem))
        XCTAssertEqual(find.title, "Find In Page")

        let fileSearchItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "file_search",
            toolArgsJSON: jsonString(["pattern": "needle"])
        )
        XCTAssertNil(ToolCardRouter.callPresentation(for: fileSearchItem))
    }

    func testReadAndFindPresentationsCoverLiveAndSummaryOnlyPayloads() throws {
        let readArgs = jsonString(["url": "https://docs.example.com/a/b/c"])
        let readRaw = jsonString(["status": "completed", "title": "Docs page", "content": String(repeating: "body ", count: 200)])
        let readItem = AgentChatItem(kind: .toolResult, text: readRaw, toolName: "webfetch", toolArgsJSON: readArgs, toolResultJSON: readRaw, toolIsError: false)
        let read = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: readItem, normalizedToolName: "web_read"))
        XCTAssertEqual(read.toolName, "web_read")
        XCTAssertEqual(read.title, "Read Web Page")
        XCTAssertEqual(read.subtitle, "docs.example.com/…/c")
        XCTAssertEqual(read.detailText, "Docs page")
        XCTAssertFalse(read.dictionary.description.contains("body body"))

        let findArgs = jsonString(["url": "https://example.com/docs", "pattern": "needle"])
        let findRaw = jsonString(["status": "completed", "match_count": 3])
        let findItem = AgentChatItem(kind: .toolResult, text: findRaw, toolName: "search", toolArgsJSON: findArgs, toolResultJSON: findRaw, toolIsError: false)
        let find = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: findItem, normalizedToolName: "search"))
        XCTAssertEqual(find.toolName, "search")
        XCTAssertEqual(find.title, "Find In Page")
        XCTAssertEqual(find.op, "find_in_page")
        XCTAssertEqual(find.detailText, "3 matches")

        let minimalWebReadSummary = jsonString([
            "status": "success",
            "summary_only": true,
            "render_summary": ["schema_version": 1, "tool_name": "web_read", "status": "success", "subtitle": "example.com/docs"]
        ])
        let minimalStoredItem = AgentChatItem(kind: .toolResult, text: minimalWebReadSummary, toolName: "webfetch", toolResultJSON: minimalWebReadSummary, toolIsError: false)
        let minimalStored = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: minimalStoredItem, normalizedToolName: "web_read"))
        XCTAssertEqual(minimalStored.title, "Read Web Page")

        let summaryOnly = jsonString(["status": "success", "summary_only": true, "render_summary": find.dictionary])
        let storedItem = AgentChatItem(kind: .toolResult, text: summaryOnly, toolName: "search", toolArgsJSON: findArgs, toolResultJSON: summaryOnly, toolIsError: false)
        let stored = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: storedItem, normalizedToolName: "search"))
        XCTAssertEqual(stored.title, "Find In Page")
        XCTAssertEqual(stored.subtitle, find.subtitle)
    }

    func testLegacyWebReadSummaryAliasesRestoreByCanonicalEquivalenceWithoutSpoofing() throws {
        for alias in ["webfetch", "web_fetch"] {
            let renderSummary = AgentToolCardRenderSummary(
                toolName: alias,
                title: "Read Web Page",
                subtitle: "example.com/docs",
                detailText: "Legacy docs",
                status: .success,
                op: "read_web_page"
            )
            let summaryOnly = jsonString([
                "status": "success",
                "summary_only": true,
                "render_summary": renderSummary.dictionary
            ])
            let legacyItem = AgentChatItem(
                kind: .toolResult,
                text: summaryOnly,
                toolName: alias,
                toolResultJSON: summaryOnly,
                toolIsError: false
            )
            let restored = try XCTUnwrap(
                NativeToolCardPresentationBuilder.build(item: legacyItem, normalizedToolName: "web_read"),
                alias
            )
            XCTAssertEqual(restored.title, "Read Web Page", alias)
            XCTAssertEqual(restored.subtitle, "example.com/docs", alias)

            XCTAssertNil(NativeToolCardPresentationBuilder.build(
                item: AgentChatItem(
                    kind: .toolResult,
                    text: summaryOnly,
                    toolName: "weather_lookup",
                    toolResultJSON: summaryOnly
                ),
                normalizedToolName: "weather_lookup"
            ), alias)
        }
    }

    func testWebSearchPresentationCoversLiveAndSummaryOnlyPayloads() throws {
        let args = jsonString(["query": "native web search cards"])
        let raw = jsonString([
            "status": "completed",
            "query": "native web search cards",
            "total_results": 12,
            "response": [
                "web_results": [["title": "Native card", "snippet": "Readable web result"]],
                "citations": [["title": "Docs"]]
            ],
            "errorMessage": "stale retry warning"
        ])
        let liveItem = AgentChatItem(
            kind: .toolResult,
            text: raw,
            toolName: "search",
            toolArgsJSON: args,
            toolResultJSON: raw,
            toolIsError: false
        )

        let live = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: liveItem, normalizedToolName: "search"))
        XCTAssertEqual(live.title, "Web Search")
        XCTAssertEqual(live.status, .success)
        XCTAssertTrue(live.subtitle?.contains("native web search cards") == true)
        XCTAssertTrue(live.subtitle?.contains("12 results") == true)
        XCTAssertTrue(live.subtitle?.contains("1 source") == true)
        XCTAssertTrue(live.detailText?.contains("Native card") == true)
        XCTAssertFalse(live.detailText?.contains("stale retry") == true)

        let summaryOnly = jsonString([
            "status": "success",
            "summary_only": true,
            "render_summary": live.dictionary
        ])
        let storedItem = AgentChatItem(
            kind: .toolResult,
            text: summaryOnly,
            toolName: "search",
            toolArgsJSON: args,
            toolResultJSON: summaryOnly,
            toolIsError: false
        )
        let stored = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: storedItem, normalizedToolName: "search"))
        XCTAssertEqual(stored.title, "Web Search")
        XCTAssertEqual(stored.status, .success)
        XCTAssertEqual(stored.subtitle, live.subtitle)
        XCTAssertFalse(toolResultHasPayload(storedItem))
    }

    func testNativeFallbackRequiresSafeNameMatchingSummaryAndScalarSignals() throws {
        let spoofedSummary = AgentToolCardRenderSummary(
            toolName: "search",
            title: "Web Search",
            subtitle: "\"spoofed\"",
            detailText: "spoofed detail",
            status: .success,
            op: "search"
        )
        let spoofedRaw = jsonString([
            "status": "success",
            "summary_only": true,
            "render_summary": spoofedSummary.dictionary
        ])
        XCTAssertNil(NativeToolCardPresentationBuilder.build(
            item: AgentChatItem(kind: .toolResult, text: spoofedRaw, toolName: "mcp__RepoPrompt__unknown", toolResultJSON: spoofedRaw),
            normalizedToolName: "mcp__RepoPrompt__unknown"
        ))
        XCTAssertNil(NativeToolCardPresentationBuilder.build(
            item: AgentChatItem(kind: .toolResult, text: spoofedRaw, toolName: "weather_lookup", toolResultJSON: spoofedRaw),
            normalizedToolName: "weather_lookup"
        ))

        let safeItem = AgentChatItem(
            kind: .toolResult,
            text: jsonString(["status": "completed", "summary": "Sunny and mild"]),
            toolName: "weather_lookup",
            toolArgsJSON: jsonString(["query": "tomorrow weather"]),
            toolResultJSON: jsonString(["status": "completed", "summary": "Sunny and mild"]),
            toolIsError: false
        )
        let safe = try XCTUnwrap(NativeToolCardPresentationBuilder.build(item: safeItem, normalizedToolName: "weather_lookup"))
        XCTAssertEqual(safe.title, "Weather Lookup")
        XCTAssertEqual(safe.subtitle, "tomorrow weather")
        XCTAssertEqual(safe.detailText, "Sunny and mild")
        XCTAssertNil(NativeToolCardPresentationBuilder.build(item: safeItem, normalizedToolName: "tool"))
    }

    private func webPresentation(
        toolName: String,
        args: [String: Any]? = nil,
        result: [String: Any]? = nil
    ) -> AgentWebToolActionPresentation? {
        AgentWebToolActionPresentation.classify(AgentWebToolActionInput(
            rawToolName: toolName,
            normalizedToolName: normalizedToolCardName(toolName),
            argsObject: args,
            resultObject: result
        ))
    }

    /// Verbatim copy of the pre-change classification (normalization repeated per predicate).
    private func legacyNormalizedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func legacyIsWebSearchName(_ name: String) -> Bool {
        switch legacyNormalizedName(name) {
        case "search", "web_search", "web_search_request", "google_web_search", "search_web", "websearch":
            true
        default:
            false
        }
    }

    private func legacyIsWebReadName(_ name: String) -> Bool {
        switch legacyNormalizedName(name) {
        case "webfetch", "web_fetch", "web_read", "read_web", "browser.open", "browser_open", "open_url",
             "read_url", "fetch_url", "web_page", "webpage", "read_web_page":
            true
        default:
            false
        }
    }

    private func legacyCanonicalToolCardName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var names: [String] = []
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let normalized = legacyNormalizedName(trimmed.replacingOccurrences(of: "mcp__RepoPrompt__", with: ""))
            names = [normalized]
            if let suffix = normalized.split(separator: ".").last.map(String.init), suffix != normalized {
                names.append(suffix)
            }
        }
        if names.contains(where: legacyIsWebSearchName) { return "search" }
        if names.contains(where: legacyIsWebReadName) { return "web_read" }
        return nil
    }

    private func jsonString(_ object: [String: Any], file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
