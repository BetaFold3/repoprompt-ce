//
//  PHPExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * PHPExamples implements CodeExamples for PHP-specific snippets.
 */
public struct PHPExamples: CodeExamples {
    // MARK: 1) Search & Replace Lines for "User" class

    public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User",
                "<s0>{",
                "<s4>public $id;",
                "<s4>public $name;",
                "<s0>}"
            ]
        } else {
            [
                "class User",
                "{",
                "    public $id;",
                "    public $name;",
                "}"
            ]
        }
    }

    public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User",
                "<s0>{",
                "<s4>public $id;",
                "<s4>public $name;",
                "<s4>public $email;",
                "<s0>}"
            ]
        } else {
            [
                "class User",
                "{",
                "    public $id;",
                "    public $name;",
                "    public $email;",
                "}"
            ]
        }
    }

    // MARK: 2) Rewrite Entire File with an "Email" property

    public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0><?php",
                "<s0>",
                "<s0>namespace Models;",
                "<s0>",
                "<s0>class User",
                "<s0>{",
                "<s4>public $id;",
                "<s4>public $name;",
                "<s4>public $email;",
                "<s4>",
                "<s4>public function __construct($name, $email)",
                "<s4>{",
                "<s8>$this->id = uniqid();",
                "<s8>$this->name = $name;",
                "<s8>$this->email = $email;",
                "<s4>}",
                "<s4>",
                "<s4>public function toArray()",
                "<s4>{",
                "<s8>return [",
                "<s12>'id' => $this->id,",
                "<s12>'name' => $this->name,",
                "<s12>'email' => $this->email,",
                "<s8>];",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "<?php",
                "",
                "namespace Models;",
                "",
                "class User",
                "{",
                "    public $id;",
                "    public $name;",
                "    public $email;",
                "",
                "    public function __construct($name, $email)",
                "    {",
                "        $this->id = uniqid();",
                "        $this->name = $name;",
                "        $this->email = $email;",
                "    }",
                "",
                "    public function toArray()",
                "    {",
                "        return [",
                "            'id' => $this->id,",
                "            'name' => $this->name,",
                "            'email' => $this->email,",
                "        ];",
                "    }",
                "}"
            ]
        }
    }

    // MARK: 3) Create a new "RoundedButton" component

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0><?php",
                "<s0>",
                "<s0>namespace Components;",
                "<s0>",
                "<s0>class RoundedButton",
                "<s0>{",
                "<s4>private $text;",
                "<s4>private $onClick;",
                "<s4>private $borderRadius;",
                "<s4>private $backgroundColor;",
                "<s4>",
                "<s4>public function __construct($text, $onClick = null, $borderRadius = '8px', $backgroundColor = '#007bff')",
                "<s4>{",
                "<s8>$this->text = $text;",
                "<s8>$this->onClick = $onClick;",
                "<s8>$this->borderRadius = $borderRadius;",
                "<s8>$this->backgroundColor = $backgroundColor;",
                "<s4>}",
                "<s4>",
                "<s4>public function render()",
                "<s4>{",
                "<s8>$style = \"background-color: {$this->backgroundColor}; border-radius: {$this->borderRadius}; border: none; padding: 10px 20px; color: white; cursor: pointer;\";",
                "<s8>$onClickAttr = $this->onClick ? \"onclick='{$this->onClick}'\" : '';",
                "<s8>",
                "<s8>return \"<button style='$style' $onClickAttr>{$this->text}</button>\";",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "<?php",
                "",
                "namespace Components;",
                "",
                "class RoundedButton",
                "{",
                "    private $text;",
                "    private $onClick;",
                "    private $borderRadius;",
                "    private $backgroundColor;",
                "",
                "    public function __construct($text, $onClick = null, $borderRadius = '8px', $backgroundColor = '#007bff')",
                "    {",
                "        $this->text = $text;",
                "        $this->onClick = $onClick;",
                "        $this->borderRadius = $borderRadius;",
                "        $this->backgroundColor = $backgroundColor;",
                "    }",
                "",
                "    public function render()",
                "    {",
                "        $style = \"background-color: {$this->backgroundColor}; border-radius: {$this->borderRadius}; border: none; padding: 10px 20px; color: white; cursor: pointer;\";",
                "        $onClickAttr = $this->onClick ? \"onclick='{$this->onClick}'\" : '';",
                "",
                "        return \"<button style='$style' $onClickAttr>{$this->text}</button>\";",
                "    }",
                "}"
            ]
        }
    }

    // MARK: 4) NetworkManager cURL to Guzzle conversion

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>public function fetchData($url, $completion)",
                "<s0>{",
                "<s4>$ch = curl_init();",
                "<s4>curl_setopt($ch, CURLOPT_URL, $url);",
                "<s4>curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);",
                "<s4>$response = curl_exec($ch);",
                "<s4>curl_close($ch);",
                "<s4>$completion($response);",
                "<s0>}"
            ]
        } else {
            [
                "public function fetchData($url, $completion)",
                "{",
                "    $ch = curl_init();",
                "    curl_setopt($ch, CURLOPT_URL, $url);",
                "    curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);",
                "    $response = curl_exec($ch);",
                "    curl_close($ch);",
                "    $completion($response);",
                "}"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>public function fetchData($url)",
                "<s0>{",
                "<s4>$client = new \\GuzzleHttp\\Client();",
                "<s4>try {",
                "<s8>$response = $client->get($url);",
                "<s8>return $response->getBody()->getContents();",
                "<s4>} catch (\\Exception $e) {",
                "<s8>throw new \\Exception('Failed to fetch data: ' . $e->getMessage());",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "public function fetchData($url)",
                "{",
                "    $client = new \\GuzzleHttp\\Client();",
                "    try {",
                "        $response = $client->get($url);",
                "        return $response->getBody()->getContents();",
                "    } catch (\\Exception $e) {",
                "        throw new \\Exception('Failed to fetch data: ' . $e->getMessage());",
                "    }",
                "}"
            ]
        }
    }

    // MARK: Negative Examples

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>namespace Services;",
                "<s0>",
                "<s0>class UserService",
                "<s0>{",
                "<s4>private $logger;",
                "<s4>",
                "<s4>public function processUser($user)",
                "<s4>{",
                "<s8>if ($user === null) {",
                "<s12>throw new \\InvalidArgumentException('User cannot be null');",
                "<s8>}",
                "<s8>$this->logger->info(\"Processing user: {$user->name}\");",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "namespace Services;",
                "",
                "class UserService",
                "{",
                "    private $logger;",
                "",
                "    public function processUser($user)",
                "    {",
                "        if ($user === null) {",
                "            throw new \\InvalidArgumentException('User cannot be null');",
                "        }",
                "        $this->logger->info(\"Processing user: {$user->name}\");",
                "    }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        // Intentionally mismatched - missing braces and different indentation
        if includeIndentation {
            [
                "<s8>if ($user === null)",
                "<s12>throw new \\InvalidArgumentException('User cannot be null');"
            ]
        } else {
            [
                "        if ($user === null)",
                "            throw new \\InvalidArgumentException('User cannot be null');"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s8>if ($user === null || empty($user->name)) {",
                "<s12>throw new \\InvalidArgumentException('User is invalid');",
                "<s8>}"
            ]
        } else {
            [
                "        if ($user === null || empty($user->name)) {",
                "            throw new \\InvalidArgumentException('User is invalid');",
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
                "<s8>$this->logger->info(\"Processing user: {$user->name}\");",
                "<s4>}"
            ]
        } else {
            [
                "        }",
                "        $this->logger->info(\"Processing user: {$user->name}\");",
                "    }"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
        // Extra closing brace added
        if includeIndentation {
            [
                "<s8>}",
                "<s8>$this->logger->info(\"Processing user: {$user->name}\");",
                "<s8>// Additional processing",
                "<s8>$this->validateUser($user);",
                "<s4>}",
                "<s4>}" // Extra brace
            ]
        } else {
            [
                "        }",
                "        $this->logger->info(\"Processing user: {$user->name}\");",
                "        // Additional processing",
                "        $this->validateUser($user);",
                "    }",
                "    }" // Extra brace
            ]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<s8>$this->logger->info(\"Processing user: {$user->name}\");"]
        } else {
            ["        $this->logger->info(\"Processing user: {$user->name}\");"]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<s8>$this->logger->debug(\"Processing user: {$user->name} with ID: {$user->id}\");"]
        } else {
            ["        $this->logger->debug(\"Processing user: {$user->name} with ID: {$user->id}\");"]
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
            "<?php",
            "",
            "class UserService",
            "{",
            "    private $users = [];",
            "    ",
            "    public function __construct()",
            "    {",
            "        // Initialize service",
            "    }",
            "    ",
            "    public function processUser($userData)",
            "    {",
            "        // Process user data",
            "        $user = [",
            "            'id' => $userData['id'],",
            "            'name' => $userData['name']",
            "        ];",
            "        return $user;",
            "    }",
            "    ",
            "    public function saveUser($user)",
            "    {",
            "        // Save user to database",
            "        $this->users[] = $user;",
            "    }",
            "}"
        ]
    }

    public func fileEditorRewriteExampleChange1() -> [String] {
        [
            "    public function processUser($userData)",
            "    {",
            "        // Add validation",
            "        if (empty($userData) || empty($userData['id']) || empty($userData['name'])) {",
            "            throw new InvalidArgumentException('Invalid user data');",
            "        }",
            "        ",
            "        // ... existing code ...",
            "    }"
        ]
    }

    public func fileEditorRewriteExampleChange2() -> [String] {
        [
            "    public function saveUser($user)",
            "    {",
            "        try {",
            "            // ... existing code ...",
            "            echo \"User saved successfully\\n\";",
            "        } catch (Exception $e) {",
            "            error_log('Failed to save user: ' . $e->getMessage());",
            "            throw $e;",
            "        }",
            "    }"
        ]
    }

    public func fileEditorRewriteExampleCompleteFile() -> [String] {
        [
            "<?php",
            "",
            "class UserService",
            "{",
            "    private $users = [];",
            "    ",
            "    public function __construct()",
            "    {",
            "        // Initialize service",
            "    }",
            "    ",
            "    public function processUser($userData)",
            "    {",
            "        // Add validation",
            "        if (empty($userData) || empty($userData['id']) || empty($userData['name'])) {",
            "            throw new InvalidArgumentException('Invalid user data');",
            "        }",
            "        ",
            "        // Process user data",
            "        $user = [",
            "            'id' => $userData['id'],",
            "            'name' => $userData['name']",
            "        ];",
            "        return $user;",
            "    }",
            "    ",
            "    public function saveUser($user)",
            "    {",
            "        try {",
            "            // Save user to database",
            "            $this->users[] = $user;",
            "            echo \"User saved successfully\\n\";",
            "        } catch (Exception $e) {",
            "            error_log('Failed to save user: ' . $e->getMessage());",
            "            throw $e;",
            "        }",
            "    }",
            "}"
        ]
    }
}
