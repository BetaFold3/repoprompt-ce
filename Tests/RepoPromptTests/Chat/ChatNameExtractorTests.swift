@testable import RepoPromptApp
import XCTest

final class ChatNameExtractorTests: XCTestCase {
    func testExtractAndRemoveScenarios() {
        let latePrefix = String(repeating: "A", count: 8192)
        let scenarios: [(
            name: String,
            chunks: [String],
            expectedName: String?,
            expectedContent: String
        )] = [
            (
                "quoted self-closing marker",
                ["<chatName=\"Implementation Plan\"/>\nBody"],
                "Implementation Plan",
                "\nBody"
            ),
            (
                "unquoted non-self-closing marker",
                ["Intro\n<chatName=Plan>\nBody"],
                "Plan",
                "Intro\n\nBody"
            ),
            (
                "valid marker embedded in surrounding text",
                ["Before <chatName = \"Review Notes\" /> after"],
                "Review Notes",
                "Before  after"
            ),
            (
                "marker split in opening tag",
                ["Intro\n<chat", "Name=\"Chunk Safe\"/>\nBody"],
                "Chunk Safe",
                "Intro\n\nBody"
            ),
            (
                "marker split in title",
                ["Intro\n<chatName=\"Chunk", " Safe\"/>\nBody"],
                "Chunk Safe",
                "Intro\n\nBody"
            ),
            (
                "marker split in closing tag",
                ["Intro\n<chatName=\"Chunk Safe\"/", ">\nBody"],
                "Chunk Safe",
                "Intro\n\nBody"
            ),
            (
                "unterminated quoted marker line",
                ["Intro\n<chatName=\"Broken Title\"\nBody"],
                "Broken Title",
                "Intro\n\nBody"
            ),
            (
                "unterminated unquoted marker line",
                ["Intro\n<chatName=Broken-Title/\nBody"],
                "Broken-Title",
                "Intro\n\nBody"
            ),
            (
                "unterminated quote marker line",
                ["Intro\n<chatName=\"Broken Title\nBody"],
                "Broken Title",
                "Intro\n\nBody"
            ),
            (
                "empty quoted value",
                ["Intro\n<chatName=\"\"/>\nBody"],
                nil,
                "Intro\n\nBody"
            ),
            (
                "missing assignment and value",
                ["Intro\n<chatName/>\nBody"],
                nil,
                "Intro\n\nBody"
            ),
            (
                "multiline quoted marker preserves following lines",
                ["<chatName=\"Draft\nImportant answer\n\"/>\nBody"],
                "Draft",
                "\nImportant answer\n\"/>\nBody"
            ),
            (
                "malformed before valid removes both artifacts",
                ["<chatName/>\nBody\n<chatName=\"Good\"/>"],
                "Good",
                "\nBody\n"
            ),
            (
                "multiple valid markers use first title and remove all",
                ["<chatName=\"First\"/>\nBody\n<chatName=\"Second\"/>"],
                "First",
                "\nBody\n"
            ),
            (
                "malformed after valid is also removed",
                ["<chatName=\"Good\"/>\nBody\n<chatName/>"],
                "Good",
                "\nBody\n"
            ),
            (
                "late marker beyond eight thousand characters",
                [latePrefix + "\n<chatName=\"Late Title\"/>\nBody"],
                "Late Title",
                latePrefix + "\n\nBody"
            ),
            (
                "absent marker",
                ["Intro\nNo chat name here.\nBody"],
                nil,
                "Intro\nNo chat name here.\nBody"
            )
        ]

        for scenario in scenarios {
            XCTContext.runActivity(named: scenario.name) { _ in
                var content = scenario.chunks.joined()

                let name = ChatNameExtractor.extractAndRemove(from: &content)

                XCTAssertEqual(name, scenario.expectedName)
                XCTAssertEqual(content, scenario.expectedContent)
            }
        }
    }
}
