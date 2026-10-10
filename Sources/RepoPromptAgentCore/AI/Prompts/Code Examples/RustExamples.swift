//
//  RustExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * RustExamples implements CodeExamples for Rust-specific snippets.
 */
public struct RustExamples: CodeExamples {
    // MARK: 1) Search & Replace Lines for "User" struct

    public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>pub struct User {",
                "<s4>pub id: Uuid,",
                "<s4>pub name: String,",
                "<s0>}"
            ]
        } else {
            [
                "pub struct User {",
                "    pub id: Uuid,",
                "    pub name: String,",
                "}"
            ]
        }
    }

    public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>pub struct User {",
                "<s4>pub id: Uuid,",
                "<s4>pub name: String,",
                "<s4>pub email: String,",
                "<s0>}"
            ]
        } else {
            [
                "pub struct User {",
                "    pub id: Uuid,",
                "    pub name: String,",
                "    pub email: String,",
                "}"
            ]
        }
    }

    // MARK: 2) Rewrite Entire File with an "email" field

    public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>use uuid::Uuid;",
                "<s0>",
                "<s0>#[derive(Debug, Clone)]",
                "<s0>pub struct User {",
                "<s4>pub id: Uuid,",
                "<s4>pub name: String,",
                "<s4>pub email: String,",
                "<s0>}",
                "<s0>",
                "<s0>impl User {",
                "<s4>pub fn new(name: String, email: String) -> Self {",
                "<s8>Self {",
                "<s12>id: Uuid::new_v4(),",
                "<s12>name,",
                "<s12>email,",
                "<s8>}",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "use uuid::Uuid;",
                "",
                "#[derive(Debug, Clone)]",
                "pub struct User {",
                "    pub id: Uuid,",
                "    pub name: String,",
                "    pub email: String,",
                "}",
                "",
                "impl User {",
                "    pub fn new(name: String, email: String) -> Self {",
                "        Self {",
                "            id: Uuid::new_v4(),",
                "            name,",
                "            email,",
                "        }",
                "    }",
                "}"
            ]
        }
    }

    // MARK: 3) Create a new "RoundedButton" file

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>use iced::{Button, Element, Length, Sandbox};",
                "<s0>",
                "<s0>pub struct RoundedButton {",
                "<s4>corner_radius: f32,",
                "<s4>button: Button,",
                "<s0>}",
                "<s0>",
                "<s0>impl RoundedButton {",
                "<s4>pub fn new() -> Self {",
                "<s8>Self {",
                "<s12>corner_radius: 0.0,",
                "<s12>button: Button::new(),",
                "<s8>}",
                "<s4>}",
                "<s4>",
                "<s4>pub fn corner_radius(mut self, radius: f32) -> Self {",
                "<s8>self.corner_radius = radius;",
                "<s8>self",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "use iced::{Button, Element, Length, Sandbox};",
                "",
                "pub struct RoundedButton {",
                "    corner_radius: f32,",
                "    button: Button,",
                "}",
                "",
                "impl RoundedButton {",
                "    pub fn new() -> Self {",
                "        Self {",
                "            corner_radius: 0.0,",
                "            button: Button::new(),",
                "        }",
                "    }",
                "",
                "    pub fn corner_radius(mut self, radius: f32) -> Self {",
                "        self.corner_radius = radius;",
                "        self",
                "    }",
                "}"
            ]
        }
    }

    // MARK: 4) NetworkManager async/await conversion

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>pub fn fetch_data(url: &str, completion: impl FnOnce(String)) {",
                "<s4>let response = reqwest::blocking::get(url)",
                "<s8>.expect(\"Failed to fetch\")",
                "<s8>.text()",
                "<s8>.expect(\"Failed to read\");",
                "<s4>completion(response);",
                "<s0>}"
            ]
        } else {
            [
                "pub fn fetch_data(url: &str, completion: impl FnOnce(String)) {",
                "    let response = reqwest::blocking::get(url)",
                "        .expect(\"Failed to fetch\")",
                "        .text()",
                "        .expect(\"Failed to read\");",
                "    completion(response);",
                "}"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>pub async fn fetch_data(url: &str) -> Result<String, reqwest::Error> {",
                "<s4>let response = reqwest::get(url)",
                "<s8>.await?",
                "<s8>.text()",
                "<s8>.await?;",
                "<s4>Ok(response)",
                "<s0>}"
            ]
        } else {
            [
                "pub async fn fetch_data(url: &str) -> Result<String, reqwest::Error> {",
                "    let response = reqwest::get(url)",
                "        .await?",
                "        .text()",
                "        .await?;",
                "    Ok(response)",
                "}"
            ]
        }
    }

    // MARK: Negative Examples

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>use log::{error, info};",
                "<s0>",
                "<s0>pub fn process_user(user: Option<&User>) {",
                "<s4>match user {",
                "<s8>None => {",
                "<s12>error!(\"User is None\");",
                "<s12>return;",
                "<s8>}",
                "<s8>Some(u) => {",
                "<s12>info!(\"Processing user: {}\", u.name);",
                "<s8>}",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "use log::{error, info};",
                "",
                "pub fn process_user(user: Option<&User>) {",
                "    match user {",
                "        None => {",
                "            error!(\"User is None\");",
                "            return;",
                "        }",
                "        Some(u) => {",
                "            info!(\"Processing user: {}\", u.name);",
                "        }",
                "    }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        // Intentionally mismatched - missing match arm structure
        if includeIndentation {
            [
                "<s8>None => {",
                "<s12>error!(\"User is None\");"
            ]
        } else {
            [
                "        None => {",
                "            error!(\"User is None\");"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s8>None => {",
                "<s12>error!(\"User is None or invalid\");",
                "<s12>panic!(\"Cannot process invalid user\");",
                "<s8>}"
            ]
        } else {
            [
                "        None => {",
                "            error!(\"User is None or invalid\");",
                "            panic!(\"Cannot process invalid user\");",
                "        }"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
        userSearchReplaceNegativeExampleFileContents(includeIndentation: includeIndentation)
    }

    public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s8>}",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "        }",
                "    }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
        // Extra closing brace added
        if includeIndentation {
            [
                "<s8>}",
                "<s4>}",
                "<s4>// Additional validation",
                "<s4>validate_user(user);",
                "<s0>}",
                "<s0>}" // Extra brace
            ]
        } else {
            [
                "        }",
                "    }",
                "    // Additional validation",
                "    validate_user(user);",
                "}",
                "}" // Extra brace
            ]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<s12>info!(\"Processing user: {}\", u.name);"]
        } else {
            ["            info!(\"Processing user: {}\", u.name);"]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<s12>debug!(\"Processing user: {} (ID: {})\", u.name, u.id);"]
        } else {
            ["            debug!(\"Processing user: {} (ID: {})\", u.name, u.id);"]
        }
    }

    public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
        // Just closing braces - ambiguous
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
                "<s4>}",
                "<s4>// TODO: Add more processing",
                "<s0>}"
            ]
        } else {
            [
                "    }",
                "    // TODO: Add more processing",
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
            "use std::error::Error;",
            "",
            "#[derive(Debug, Clone)]",
            "struct User {",
            "    id: String,",
            "    name: String,",
            "}",
            "",
            "struct UserService {",
            "    users: Vec<User>,",
            "}",
            "",
            "impl UserService {",
            "    fn new() -> Self {",
            "        UserService {",
            "            users: Vec::new(),",
            "        }",
            "    }",
            "    ",
            "    fn process_user(&self, user_data: &User) -> Result<User, Box<dyn Error>> {",
            "        // Process user data",
            "        let user = User {",
            "            id: user_data.id.clone(),",
            "            name: user_data.name.clone(),",
            "        };",
            "        Ok(user)",
            "    }",
            "    ",
            "    fn save_user(&mut self, user: User) -> Result<(), Box<dyn Error>> {",
            "        // Save user to database",
            "        self.users.push(user);",
            "        Ok(())",
            "    }",
            "}"
        ]
    }

    public func fileEditorRewriteExampleChange1() -> [String] {
        [
            "    fn process_user(&self, user_data: &User) -> Result<User, Box<dyn Error>> {",
            "        // Add validation",
            "        if user_data.id.is_empty() || user_data.name.is_empty() {",
            "            return Err(\"Invalid user data\".into());",
            "        }",
            "        ",
            "        // ... existing code ...",
            "    }"
        ]
    }

    public func fileEditorRewriteExampleChange2() -> [String] {
        [
            "    fn save_user(&mut self, user: User) -> Result<(), Box<dyn Error>> {",
            "        // ... existing code ...",
            "        println!(\"User saved successfully\");",
            "        Ok(())",
            "    }"
        ]
    }

    public func fileEditorRewriteExampleCompleteFile() -> [String] {
        [
            "use std::error::Error;",
            "",
            "#[derive(Debug, Clone)]",
            "struct User {",
            "    id: String,",
            "    name: String,",
            "}",
            "",
            "struct UserService {",
            "    users: Vec<User>,",
            "}",
            "",
            "impl UserService {",
            "    fn new() -> Self {",
            "        UserService {",
            "            users: Vec::new(),",
            "        }",
            "    }",
            "    ",
            "    fn process_user(&self, user_data: &User) -> Result<User, Box<dyn Error>> {",
            "        // Add validation",
            "        if user_data.id.is_empty() || user_data.name.is_empty() {",
            "            return Err(\"Invalid user data\".into());",
            "        }",
            "        ",
            "        // Process user data",
            "        let user = User {",
            "            id: user_data.id.clone(),",
            "            name: user_data.name.clone(),",
            "        };",
            "        Ok(user)",
            "    }",
            "    ",
            "    fn save_user(&mut self, user: User) -> Result<(), Box<dyn Error>> {",
            "        // Save user to database",
            "        self.users.push(user);",
            "        println!(\"User saved successfully\");",
            "        Ok(())",
            "    }",
            "}"
        ]
    }
}
