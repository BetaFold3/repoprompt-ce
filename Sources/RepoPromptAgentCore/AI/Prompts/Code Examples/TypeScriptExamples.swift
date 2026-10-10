//
//  TypeScriptExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-01-14.
//

import Foundation

/**
 * TypeScriptExamples implements CodeExamples for TypeScript-specific snippets.
 */
public struct TypeScriptExamples: CodeExamples {
    // MARK: 1) Search & Replace Lines for "User" interface

    public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>interface User {",
                "<s4>id: string;",
                "<s4>name: string;",
                "<s0>}"
            ]
        } else {
            [
                "interface User {",
                "    id: string;",
                "    name: string;",
                "}"
            ]
        }
    }

    public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>interface User {",
                "<s4>id: string;",
                "<s4>name: string;",
                "<s4>email: string;",
                "<s0>}"
            ]
        } else {
            [
                "interface User {",
                "    id: string;",
                "    name: string;",
                "    email: string;",
                "}"
            ]
        }
    }

    // MARK: 2) Rewrite Entire File with an "email" field

    public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import { v4 as uuidv4 } from 'uuid';",
                "<s0>",
                "<s0>export interface User {",
                "<s4>id: string;",
                "<s4>name: string;",
                "<s4>email: string;",
                "<s4>role?: 'admin' | 'user';",
                "<s4>createdAt: Date;",
                "<s0>}",
                "<s0>",
                "<s0>export class UserService {",
                "<s4>createUser(name: string, email: string, role: 'admin' | 'user' = 'user'): User {",
                "<s8>return {",
                "<s12>id: uuidv4(),",
                "<s12>name,",
                "<s12>email,",
                "<s12>role,",
                "<s12>createdAt: new Date()",
                "<s8>};",
                "<s4>}",
                "<s4>",
                "<s4>getDisplayName(user: User): string {",
                "<s8>return `${user.name} (${user.email})`;",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "import { v4 as uuidv4 } from 'uuid';",
                "",
                "export interface User {",
                "    id: string;",
                "    name: string;",
                "    email: string;",
                "    role?: 'admin' | 'user';",
                "    createdAt: Date;",
                "}",
                "",
                "export class UserService {",
                "    createUser(name: string, email: string, role: 'admin' | 'user' = 'user'): User {",
                "        return {",
                "            id: uuidv4(),",
                "            name,",
                "            email,",
                "            role,",
                "            createdAt: new Date()",
                "        };",
                "    }",
                "    ",
                "    getDisplayName(user: User): string {",
                "        return `${user.name} (${user.email})`;",
                "    }",
                "}"
            ]
        }
    }

    // MARK: 3) Create a new "RoundedButton" component

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import { CSSProperties } from 'react';",
                "<s0>",
                "<s0>interface RoundedButtonProps {",
                "<s4>text: string;",
                "<s4>cornerRadius?: number;",
                "<s4>onClick?: () => void;",
                "<s0>}",
                "<s0>",
                "<s0>export function RoundedButton({ text, cornerRadius = 0, onClick }: RoundedButtonProps) {",
                "<s4>const style: CSSProperties = {",
                "<s8>borderRadius: `${cornerRadius}px`,",
                "<s8>padding: '10px 20px',",
                "<s8>cursor: 'pointer'",
                "<s4>};",
                "<s4>",
                "<s4>return (",
                "<s8><button style={style} onClick={onClick}>",
                "<s12>{text}",
                "<s8></button>",
                "<s4>);",
                "<s0>}"
            ]
        } else {
            [
                "import { CSSProperties } from 'react';",
                "",
                "interface RoundedButtonProps {",
                "    text: string;",
                "    cornerRadius?: number;",
                "    onClick?: () => void;",
                "}",
                "",
                "export function RoundedButton({ text, cornerRadius = 0, onClick }: RoundedButtonProps) {",
                "    const style: CSSProperties = {",
                "        borderRadius: `${cornerRadius}px`,",
                "        padding: '10px 20px',",
                "        cursor: 'pointer'",
                "    };",
                "    ",
                "    return (",
                "        <button style={style} onClick={onClick}>",
                "            {text}",
                "        </button>",
                "    );",
                "}"
            ]
        }
    }

    // MARK: 4) Indentation-Preserving Example (async/await)

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>export class NetworkManager {",
                "<s4>fetchData(url: string, callback: (data: any) => void): void {",
                "<s8>// old callback-based code",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "export class NetworkManager {",
                "    fetchData(url: string, callback: (data: any) => void): void {",
                "        // old callback-based code",
                "    }",
                "}"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>export class NetworkManager {",
                "<s4>async fetchData(url: string): Promise<any> {",
                "<s8>const response = await fetch(url);",
                "<s8>if (!response.ok) {",
                "<s12>throw new Error(`HTTP error! status: ${response.status}`);",
                "<s8>}",
                "<s8>return await response.json();",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "export class NetworkManager {",
                "    async fetchData(url: string): Promise<any> {",
                "        const response = await fetch(url);",
                "        if (!response.ok) {",
                "            throw new Error(`HTTP error! status: ${response.status}`);",
                "        }",
                "        return await response.json();",
                "    }",
                "}"
            ]
        }
    }

    // MARK: - Negative Examples for Search/Replace

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import { Component } from '@angular/core';",
                "<s0>export class Example {",
                "<s0>    foo(): void {",
                "<s0>        bar();",
                "<s0>    }",
                "<s0>}"
            ]
        } else {
            [
                "import { Component } from '@angular/core';",
                "export class Example {",
                "    foo(): void {",
                "        bar();",
                "    }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>foo(): void {",
                "<s8>bar();",
                "<s4>}"
            ]
        } else {
            [
                "    foo(): void {",
                "        bar();",
                "    }"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>foo(): void {",
                "<s8>bar();",
                "<s8>bar2();",
                "<s4>}"
            ]
        } else {
            [
                "    foo(): void {",
                "        bar();",
                "        bar2();",
                "    }"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>function someFunction(): void {",
                "<s4>foo() {",
                "<s8>bar();",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "function someFunction(): void {",
                "    foo() {",
                "        bar();",
                "    }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>foo() {",
                "<s8>bar();",
                "<s4>}"
            ]
        } else {
            [
                "    foo() {",
                "        bar();",
                "    }"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>foo() {",
                "<s8>bar();",
                "<s4>}",
                "",
                "<s4>baz() {",
                "<s8>foo2();",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "    foo() {",
                "        bar();",
                "    }",
                "",
                "    baz() {",
                "        foo2();",
                "    }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>email: string;"
            ]
        } else {
            [
                "email: string;"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>emailAddress: string;"
            ]
        } else {
            [
                "emailAddress: string;"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "    }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s8>foo() {",
                "<s8>}",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "        foo() {",
                "        }",
                "    }",
                "}"
            ]
        }
    }

    public func commentSyntax() -> String {
        "//"
    }

    // File editor examples use default implementation from protocol extension

    // MARK: - Rewrite-Only File Editor Example Methods

    public func fileEditorRewriteExampleFileContents() -> [String] {
        [
            "interface UserData {",
            "  id: string;",
            "  name: string;",
            "}",
            "",
            "interface User {",
            "  id: string;",
            "  name: string;",
            "}",
            "",
            "class UserService {",
            "  private users: User[] = [];",
            "  ",
            "  constructor() {",
            "    // Initialize service",
            "  }",
            "  ",
            "  processUser(userData: UserData): User {",
            "    // Process user data",
            "    const user: User = {",
            "      id: userData.id,",
            "      name: userData.name",
            "    };",
            "    return user;",
            "  }",
            "  ",
            "  saveUser(user: User): void {",
            "    // Save user to database",
            "    this.users.push(user);",
            "  }",
            "}"
        ]
    }

    public func fileEditorRewriteExampleChange1() -> [String] {
        [
            "  processUser(userData: UserData): User {",
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
            "  saveUser(user: User): void {",
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
            "interface UserData {",
            "  id: string;",
            "  name: string;",
            "}",
            "",
            "interface User {",
            "  id: string;",
            "  name: string;",
            "}",
            "",
            "class UserService {",
            "  private users: User[] = [];",
            "  ",
            "  constructor() {",
            "    // Initialize service",
            "  }",
            "  ",
            "  processUser(userData: UserData): User {",
            "    // Add validation",
            "    if (!userData || !userData.id || !userData.name) {",
            "      throw new Error('Invalid user data');",
            "    }",
            "    ",
            "    // Process user data",
            "    const user: User = {",
            "      id: userData.id,",
            "      name: userData.name",
            "    };",
            "    return user;",
            "  }",
            "  ",
            "  saveUser(user: User): void {",
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
