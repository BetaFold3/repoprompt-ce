//
//  CppExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * CppExamples implements CodeExamples for C++-specific snippets.
 */
public struct CppExamples: CodeExamples {
    // MARK: 1) Search & Replace Lines for "User" class

    public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User {",
                "<s0>public:",
                "<s4>std::string id;",
                "<s4>std::string name;",
                "<s0>};"
            ]
        } else {
            [
                "class User {",
                "public:",
                "    std::string id;",
                "    std::string name;",
                "};"
            ]
        }
    }

    public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User {",
                "<s0>public:",
                "<s4>std::string id;",
                "<s4>std::string name;",
                "<s4>std::string email;",
                "<s0>};"
            ]
        } else {
            [
                "class User {",
                "public:",
                "    std::string id;",
                "    std::string name;",
                "    std::string email;",
                "};"
            ]
        }
    }

    // MARK: 2) Rewrite Entire File with an "email" field

    public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>#pragma once",
                "<s0>#include <string>",
                "<s0>#include <uuid/uuid.h>",
                "<s0>",
                "<s0>class User {",
                "<s0>private:",
                "<s4>std::string id;",
                "<s4>std::string name;",
                "<s4>std::string email;",
                "<s0>",
                "<s0>public:",
                "<s4>User(const std::string& name, const std::string& email) ",
                "<s8>: name(name), email(email) {",
                "<s8>// Generate UUID",
                "<s8>uuid_t uuid;",
                "<s8>uuid_generate(uuid);",
                "<s8>char uuid_str[37];",
                "<s8>uuid_unparse(uuid, uuid_str);",
                "<s8>id = std::string(uuid_str);",
                "<s4>}",
                "<s4>",
                "<s4>const std::string& getId() const { return id; }",
                "<s4>const std::string& getName() const { return name; }",
                "<s4>const std::string& getEmail() const { return email; }",
                "<s0>};"
            ]
        } else {
            [
                "#pragma once",
                "#include <string>",
                "#include <uuid/uuid.h>",
                "",
                "class User {",
                "private:",
                "    std::string id;",
                "    std::string name;",
                "    std::string email;",
                "",
                "public:",
                "    User(const std::string& name, const std::string& email) ",
                "        : name(name), email(email) {",
                "        // Generate UUID",
                "        uuid_t uuid;",
                "        uuid_generate(uuid);",
                "        char uuid_str[37];",
                "        uuid_unparse(uuid, uuid_str);",
                "        id = std::string(uuid_str);",
                "    }",
                "",
                "    const std::string& getId() const { return id; }",
                "    const std::string& getName() const { return name; }",
                "    const std::string& getEmail() const { return email; }",
                "};"
            ]
        }
    }

    // MARK: 3) Create a new "RoundedButton" file

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>#pragma once",
                "<s0>#include <QPushButton>",
                "<s0>",
                "<s0>class RoundedButton : public QPushButton {",
                "<s4>Q_OBJECT",
                "<s4>Q_PROPERTY(double cornerRadius READ cornerRadius WRITE setCornerRadius)",
                "<s0>",
                "<s0>private:",
                "<s4>double m_cornerRadius;",
                "<s0>",
                "<s0>public:",
                "<s4>explicit RoundedButton(QWidget* parent = nullptr)",
                "<s8>: QPushButton(parent), m_cornerRadius(0.0) {}",
                "<s4>",
                "<s4>double cornerRadius() const { return m_cornerRadius; }",
                "<s4>void setCornerRadius(double radius) { ",
                "<s8>m_cornerRadius = radius;",
                "<s8>update();",
                "<s4>}",
                "<s0>};"
            ]
        } else {
            [
                "#pragma once",
                "#include <QPushButton>",
                "",
                "class RoundedButton : public QPushButton {",
                "    Q_OBJECT",
                "    Q_PROPERTY(double cornerRadius READ cornerRadius WRITE setCornerRadius)",
                "",
                "private:",
                "    double m_cornerRadius;",
                "",
                "public:",
                "    explicit RoundedButton(QWidget* parent = nullptr)",
                "        : QPushButton(parent), m_cornerRadius(0.0) {}",
                "",
                "    double cornerRadius() const { return m_cornerRadius; }",
                "    void setCornerRadius(double radius) { ",
                "        m_cornerRadius = radius;",
                "        update();",
                "    }",
                "};"
            ]
        }
    }

    // MARK: 4) NetworkManager async/await conversion

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>void fetchData(const std::string& url, std::function<void(std::string)> completion) {",
                "<s4>std::thread([url, completion]() {",
                "<s8>// Simulated blocking network call",
                "<s8>std::string response = performBlockingRequest(url);",
                "<s8>completion(response);",
                "<s4>}).detach();",
                "<s0>}"
            ]
        } else {
            [
                "void fetchData(const std::string& url, std::function<void(std::string)> completion) {",
                "    std::thread([url, completion]() {",
                "        // Simulated blocking network call",
                "        std::string response = performBlockingRequest(url);",
                "        completion(response);",
                "    }).detach();",
                "}"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>std::future<std::string> fetchData(const std::string& url) {",
                "<s4>return std::async(std::launch::async, [url]() {",
                "<s8>// Async network call",
                "<s8>return performAsyncRequest(url);",
                "<s4>});",
                "<s0>}"
            ]
        } else {
            [
                "std::future<std::string> fetchData(const std::string& url) {",
                "    return std::async(std::launch::async, [url]() {",
                "        // Async network call",
                "        return performAsyncRequest(url);",
                "    });",
                "}"
            ]
        }
    }

    // MARK: Negative Examples

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>#include \"user_service.h\"",
                "<s0>#include \"logger.h\"",
                "<s0>",
                "<s0>void UserService::processUser(User* user) {",
                "<s4>if (user == nullptr) {",
                "<s8>Logger::error(\"User is nullptr\");",
                "<s8>return;",
                "<s4>}",
                "<s4>Logger::info(\"Processing user: \" + user->getName());",
                "<s0>}"
            ]
        } else {
            [
                "#include \"user_service.h\"",
                "#include \"logger.h\"",
                "",
                "void UserService::processUser(User* user) {",
                "    if (user == nullptr) {",
                "        Logger::error(\"User is nullptr\");",
                "        return;",
                "    }",
                "    Logger::info(\"Processing user: \" + user->getName());",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        // Intentionally mismatched - missing braces
        if includeIndentation {
            [
                "<s4>if (user == nullptr)",
                "<s8>Logger::error(\"User is nullptr\");"
            ]
        } else {
            [
                "    if (user == nullptr)",
                "        Logger::error(\"User is nullptr\");"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>if (user == nullptr || user->getName().empty()) {",
                "<s8>Logger::error(\"User is invalid\");",
                "<s8>throw std::invalid_argument(\"Invalid user\");",
                "<s4>}"
            ]
        } else {
            [
                "    if (user == nullptr || user->getName().empty()) {",
                "        Logger::error(\"User is invalid\");",
                "        throw std::invalid_argument(\"Invalid user\");",
                "    }"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
        userSearchReplaceNegativeExampleFileContents(includeIndentation: includeIndentation)
    }

    public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>}",
                "<s4>Logger::info(\"Processing user: \" + user->getName());",
                "<s0>}"
            ]
        } else {
            [
                "    }",
                "    Logger::info(\"Processing user: \" + user->getName());",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
        // Extra closing brace added
        if includeIndentation {
            [
                "<s4>}",
                "<s4>Logger::info(\"Processing user: \" + user->getName());",
                "<s4>// Additional validation",
                "<s4>validateUser(user);",
                "<s0>}",
                "<s0>}" // Extra brace
            ]
        } else {
            [
                "    }",
                "    Logger::info(\"Processing user: \" + user->getName());",
                "    // Additional validation",
                "    validateUser(user);",
                "}",
                "}" // Extra brace
            ]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<s4>Logger::info(\"Processing user: \" + user->getName());"]
        } else {
            ["    Logger::info(\"Processing user: \" + user->getName());"]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<s4>Logger::debug(\"Processing user: \" + user->getName() + \" (ID: \" + user->getId() + \")\");"]
        } else {
            ["    Logger::debug(\"Processing user: \" + user->getName() + \" (ID: \" + user->getId() + \")\");"]
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
            "#include <iostream>",
            "#include <vector>",
            "#include <string>",
            "#include <stdexcept>",
            "",
            "struct User {",
            "    std::string id;",
            "    std::string name;",
            "};",
            "",
            "class UserService {",
            "private:",
            "    std::vector<User> users;",
            "    ",
            "public:",
            "    UserService() {",
            "        // Initialize service",
            "    }",
            "    ",
            "    User processUser(const User& userData) {",
            "        // Process user data",
            "        User user;",
            "        user.id = userData.id;",
            "        user.name = userData.name;",
            "        return user;",
            "    }",
            "    ",
            "    void saveUser(const User& user) {",
            "        // Save user to database",
            "        users.push_back(user);",
            "    }",
            "};"
        ]
    }

    public func fileEditorRewriteExampleChange1() -> [String] {
        [
            "    User processUser(const User& userData) {",
            "        // Add validation",
            "        if (userData.id.empty() || userData.name.empty()) {",
            "            throw std::invalid_argument(\"Invalid user data\");",
            "        }",
            "        ",
            "        // ... existing code ...",
            "    }"
        ]
    }

    public func fileEditorRewriteExampleChange2() -> [String] {
        [
            "    void saveUser(const User& user) {",
            "        try {",
            "            // ... existing code ...",
            "            std::cout << \"User saved successfully\" << std::endl;",
            "        } catch (const std::exception& e) {",
            "            std::cerr << \"Failed to save user: \" << e.what() << std::endl;",
            "            throw;",
            "        }",
            "    }"
        ]
    }

    public func fileEditorRewriteExampleCompleteFile() -> [String] {
        [
            "#include <iostream>",
            "#include <vector>",
            "#include <string>",
            "#include <stdexcept>",
            "",
            "struct User {",
            "    std::string id;",
            "    std::string name;",
            "};",
            "",
            "class UserService {",
            "private:",
            "    std::vector<User> users;",
            "    ",
            "public:",
            "    UserService() {",
            "        // Initialize service",
            "    }",
            "    ",
            "    User processUser(const User& userData) {",
            "        // Add validation",
            "        if (userData.id.empty() || userData.name.empty()) {",
            "            throw std::invalid_argument(\"Invalid user data\");",
            "        }",
            "        ",
            "        // Process user data",
            "        User user;",
            "        user.id = userData.id;",
            "        user.name = userData.name;",
            "        return user;",
            "    }",
            "    ",
            "    void saveUser(const User& user) {",
            "        try {",
            "            // Save user to database",
            "            users.push_back(user);",
            "            std::cout << \"User saved successfully\" << std::endl;",
            "        } catch (const std::exception& e) {",
            "            std::cerr << \"Failed to save user: \" << e.what() << std::endl;",
            "            throw;",
            "        }",
            "    }",
            "};"
        ]
    }
}
