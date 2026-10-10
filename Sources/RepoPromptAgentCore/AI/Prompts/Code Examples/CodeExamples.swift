//
//  CodeExamples.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-12-28.
//

import Foundation

/**
 * CodeExamples protocol is a generic interface for providing code snippets
 * in various languages. SwiftExamples is our Swift-specific implementation.
 */
public protocol CodeExamples {
    func userSearchReplaceOldLines(includeIndentation: Bool) -> [String]
    func userSearchReplaceNewLines(includeIndentation: Bool) -> [String]

    func userRewriteAllLines(includeIndentation: Bool) -> [String]
    func userCreateAllLines(includeIndentation: Bool) -> [String]

    func networkManagerOldLines(includeIndentation: Bool) -> [String]
    func networkManagerNewLines(includeIndentation: Bool) -> [String]

    // Negative example for search/replace (mismatched search block)
    func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String]
    func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String]
    func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String]

    // Additional negative example for mismatched braces
    func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String]
    func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String]
    func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String]

    /// New negative example: one-line search block (should be avoided)
    func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String]
    /// New block for one-line negative example (content must match search block)
    func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String]

    /// New negative example: ambiguous search block (should be avoided)
    func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String]
    /// New block for ambiguous negative example (content must match search block)
    func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String]

    /// Returns the comment syntax for this language (e.g., "//" for Swift/C, "#" for Python)
    func commentSyntax() -> String

    // File editor example methods
    func fileEditorExampleFileContents() -> [String]
    func fileEditorExampleChange1() -> [String]
    func fileEditorExampleChange2() -> [String]
    func fileEditorExampleSearchBlock() -> [String]
    func fileEditorExampleContentBlock() -> [String]
    func fileEditorExampleSearchBlock2() -> [String]
    func fileEditorExampleContentBlock2() -> [String]

    // File editor rewrite-only example methods
    func fileEditorRewriteExampleFileContents() -> [String]
    func fileEditorRewriteExampleChange1() -> [String]
    func fileEditorRewriteExampleChange2() -> [String]
    func fileEditorRewriteExampleCompleteFile() -> [String]
}

// MARK: - Default Implementations for File Editor Examples

public extension CodeExamples {
    /// Default implementations using generic JavaScript-like syntax
    func fileEditorExampleFileContents() -> [String] {
        [
            "class GameManager {",
            "  constructor() {",
            "    this.score = 0;",
            "    this.level = 1;",
            "    this.isRunning = false;",
            "  }",
            "  ",
            "  reset() {",
            "    this.score = 0;",
            "    this.level = 1;",
            "    this.isRunning = false;",
            "  }",
            "  ",
            "  checkProximity(position) {",
            "    // Calculate distance logic here",
            "    return 0.0;",
            "  }",
            "}"
        ]
    }

    func fileEditorExampleChange1() -> [String] {
        [
            "    // ... existing code ...",
            "    this.isRunning = false;",
            "    ",
            "    console.log('GameManager initialized');",
            "  }",
            "  ",
            "  reset() {",
            "    // ... existing code ..."
        ]
    }

    func fileEditorExampleChange2() -> [String] {
        [
            "    // ... existing code ...",
            "  }",
            "  ",
            "  destroy() {",
            "    console.log('GameManager cleaned up');",
            "  }",
            "}"
        ]
    }

    func fileEditorExampleSearchBlock() -> [String] {
        [
            "    this.isRunning = false;",
            "  }",
            "  ",
            "  reset() {"
        ]
    }

    func fileEditorExampleContentBlock() -> [String] {
        [
            "    this.isRunning = false;",
            "    ",
            "    console.log('GameManager initialized');",
            "  }",
            "  ",
            "  reset() {"
        ]
    }

    func fileEditorExampleSearchBlock2() -> [String] {
        [
            "    return 0.0;",
            "  }",
            "}"
        ]
    }

    func fileEditorExampleContentBlock2() -> [String] {
        [
            "    return 0.0;",
            "  }",
            "  ",
            "  destroy() {",
            "    console.log('GameManager cleaned up');",
            "  }",
            "}"
        ]
    }

    // MARK: - Rewrite-Only File Editor Example Methods

    func fileEditorRewriteExampleFileContents() -> [String] {
        [
            "class UserService {",
            "  constructor() {",
            "    this.users = [];",
            "  }",
            "  ",
            "  processUser(userData) {",
            "    // Process user data",
            "    const user = {",
            "      id: userData.id,",
            "      name: userData.name",
            "    };",
            "    return user;",
            "  }",
            "  ",
            "  saveUser(user) {",
            "    // Save user to database",
            "    this.users.push(user);",
            "  }",
            "}"
        ]
    }

    func fileEditorRewriteExampleChange1() -> [String] {
        [
            "  processUser(userData) {",
            "    // Add validation",
            "    if (!userData || !userData.id || !userData.name) {",
            "      throw new Error('Invalid user data');",
            "    }",
            "    ",
            "    // ... existing code ...",
            "  }"
        ]
    }

    func fileEditorRewriteExampleChange2() -> [String] {
        [
            "  saveUser(user) {",
            "    try {",
            "      // ... existing code ...",
            "      console.log('User saved successfully');",
            "    } catch (error) {",
            "      console.error('Failed to save user:', error);",
            "      throw error;",
            "    }",
            "  }"
        ]
    }

    func fileEditorRewriteExampleCompleteFile() -> [String] {
        [
            "class UserService {",
            "  constructor() {",
            "    this.users = [];",
            "  }",
            "  ",
            "  processUser(userData) {",
            "    // Add validation",
            "    if (!userData || !userData.id || !userData.name) {",
            "      throw new Error('Invalid user data');",
            "    }",
            "    ",
            "    // Process user data",
            "    const user = {",
            "      id: userData.id,",
            "      name: userData.name",
            "    };",
            "    return user;",
            "  }",
            "  ",
            "  saveUser(user) {",
            "    try {",
            "      // Save user to database",
            "      this.users.push(user);",
            "      console.log('User saved successfully');",
            "    } catch (error) {",
            "      console.error('Failed to save user:', error);",
            "      throw error;",
            "    }",
            "  }",
            "}"
        ]
    }
}
