//
//  JavaScriptExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-01-14.
//

import Foundation

/**
 * JavaScriptExamples implements CodeExamples for JavaScript-specific snippets.
 */
public struct JavaScriptExamples: CodeExamples {
    // MARK: 1) Search & Replace Lines for "User" class

    public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User {",
                "<s2>constructor(id, name) {",
                "<s4>this.id = id;",
                "<s4>this.name = name;",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "class User {",
                "  constructor(id, name) {",
                "    this.id = id;",
                "    this.name = name;",
                "  }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User {",
                "<s2>constructor(id, name, email) {",
                "<s4>this.id = id;",
                "<s4>this.name = name;",
                "<s4>this.email = email;",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "class User {",
                "  constructor(id, name, email) {",
                "    this.id = id;",
                "    this.name = name;",
                "    this.email = email;",
                "  }",
                "}"
            ]
        }
    }

    // MARK: 2) Rewrite All Lines

    public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User {",
                "<s2>constructor(id, name, email, role = 'user') {",
                "<s4>this.id = id;",
                "<s4>this.name = name;",
                "<s4>this.email = email;",
                "<s4>this.role = role;",
                "<s4>this.createdAt = new Date();",
                "<s2>}",
                "",
                "<s2>getDisplayName() {",
                "<s4>return `${this.name} (${this.email})`;",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "class User {",
                "  constructor(id, name, email, role = 'user') {",
                "    this.id = id;",
                "    this.name = name;",
                "    this.email = email;",
                "    this.role = role;",
                "    this.createdAt = new Date();",
                "  }",
                "",
                "  getDisplayName() {",
                "    return `${this.name} (${this.email})`;",
                "  }",
                "}"
            ]
        }
    }

    // MARK: 3) Create All Lines

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>// models/User.js",
                "<s0>export class User {",
                "<s2>constructor(id, name, email) {",
                "<s4>this.id = id;",
                "<s4>this.name = name;",
                "<s4>this.email = email;",
                "<s2>}",
                "",
                "<s2>toJSON() {",
                "<s4>return {",
                "<s6>id: this.id,",
                "<s6>name: this.name,",
                "<s6>email: this.email",
                "<s4>};",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "// models/User.js",
                "export class User {",
                "  constructor(id, name, email) {",
                "    this.id = id;",
                "    this.name = name;",
                "    this.email = email;",
                "  }",
                "",
                "  toJSON() {",
                "    return {",
                "      id: this.id,",
                "      name: this.name,",
                "      email: this.email",
                "    };",
                "  }",
                "}"
            ]
        }
    }

    // MARK: 4) NetworkManager Example

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class APIClient {",
                "<s2>async fetchData(endpoint) {",
                "<s4>const response = await fetch(endpoint);",
                "<s4>return response.json();",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "class APIClient {",
                "  async fetchData(endpoint) {",
                "    const response = await fetch(endpoint);",
                "    return response.json();",
                "  }",
                "}"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class APIClient {",
                "<s2>async fetchData(endpoint, options = {}) {",
                "<s4>try {",
                "<s6>const response = await fetch(endpoint, {",
                "<s8>...options,",
                "<s8>headers: {",
                "<s10>'Content-Type': 'application/json',",
                "<s10>...options.headers",
                "<s8>}",
                "<s6>});",
                "<s6>",
                "<s6>if (!response.ok) {",
                "<s8>throw new Error(`HTTP ${response.status}: ${response.statusText}`);",
                "<s6>}",
                "<s6>",
                "<s6>return response.json();",
                "<s4>} catch (error) {",
                "<s6>console.error('API request failed:', error);",
                "<s6>throw error;",
                "<s4>}",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "class APIClient {",
                "  async fetchData(endpoint, options = {}) {",
                "    try {",
                "      const response = await fetch(endpoint, {",
                "        ...options,",
                "        headers: {",
                "          'Content-Type': 'application/json',",
                "          ...options.headers",
                "        }",
                "      });",
                "      ",
                "      if (!response.ok) {",
                "        throw new Error(`HTTP ${response.status}: ${response.statusText}`);",
                "      }",
                "      ",
                "      return response.json();",
                "    } catch (error) {",
                "      console.error('API request failed:', error);",
                "      throw error;",
                "    }",
                "  }",
                "}"
            ]
        }
    }

    // MARK: 5) Negative Examples

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        [
            "class User {",
            "  constructor(id, name) {",
            "    this.id = id;",
            "    this.name = name;",
            "    this.isActive = true;",
            "  }",
            "  ",
            "  getInfo() {",
            "    return `User: ${this.name}`;",
            "  }",
            "}"
        ]
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        [
            "  constructor(id, name) {",
            "    this.id = id;",
            "    this.name = name;"
        ]
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        [
            "  constructor(id, name, email) {",
            "    this.id = id;",
            "    this.name = name;",
            "    this.email = email;"
        ]
    }

    /// Brace mismatch example
    public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
        [
            "function processData(items) {",
            "  if (items.length > 0) {",
            "    items.forEach(item => {",
            "      console.log(item);",
            "    });",
            "  }",
            "}"
        ]
    }

    public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
        [
            "  if (items.length > 0) {",
            "    items.forEach(item => {",
            "      console.log(item);"
        ]
    }

    public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
        [
            "  if (items.length > 0) {",
            "    console.log(`Processing ${items.length} items`);",
            "    items.forEach(item => {",
            "      console.log(item);"
        ]
    }

    /// One-line search block
    public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
        ["console.log(item);"]
    }

    public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
        ["console.log('Item:', item);"]
    }

    /// Ambiguous search block
    public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
        ["}"]
    }

    public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
        [
            "  }",
            "}"
        ]
    }

    public func commentSyntax() -> String {
        "//"
    }

    // MARK: - File Editor Example Methods

    public func fileEditorExampleFileContents() -> [String] {
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

    public func fileEditorExampleChange1() -> [String] {
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

    public func fileEditorExampleChange2() -> [String] {
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

    public func fileEditorExampleSearchBlock() -> [String] {
        [
            "    this.isRunning = false;",
            "  }",
            "  ",
            "  reset() {"
        ]
    }

    public func fileEditorExampleContentBlock() -> [String] {
        [
            "    this.isRunning = false;",
            "    ",
            "    console.log('GameManager initialized');",
            "  }",
            "  ",
            "  reset() {"
        ]
    }

    public func fileEditorExampleSearchBlock2() -> [String] {
        [
            "    return 0.0;",
            "  }",
            "}"
        ]
    }

    public func fileEditorExampleContentBlock2() -> [String] {
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

    public func fileEditorRewriteExampleFileContents() -> [String] {
        // Using the default implementation from the protocol extension
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

    public func fileEditorRewriteExampleChange1() -> [String] {
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

    public func fileEditorRewriteExampleChange2() -> [String] {
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

    public func fileEditorRewriteExampleCompleteFile() -> [String] {
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
