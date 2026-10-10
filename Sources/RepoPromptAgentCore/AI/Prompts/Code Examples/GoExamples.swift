//
//  GoExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * GoExamples implements CodeExamples for Go-specific snippets.
 */
public struct GoExamples: CodeExamples {
    // MARK: 1) Search & Replace Lines for "User" struct

    public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>type User struct {",
                "<t1>ID   string `json:\"id\"`",
                "<t1>Name string `json:\"name\"`",
                "<s0>}"
            ]
        } else {
            [
                "type User struct {",
                "\tID   string `json:\"id\"`",
                "\tName string `json:\"name\"`",
                "}"
            ]
        }
    }

    public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>type User struct {",
                "<t1>ID    string `json:\"id\"`",
                "<t1>Name  string `json:\"name\"`",
                "<t1>Email string `json:\"email\"`",
                "<s0>}"
            ]
        } else {
            [
                "type User struct {",
                "\tID    string `json:\"id\"`",
                "\tName  string `json:\"name\"`",
                "\tEmail string `json:\"email\"`",
                "}"
            ]
        }
    }

    // MARK: 2) Rewrite Entire File with an "email" field

    public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>package models",
                "<s0>",
                "<s0>import (",
                "<t1>\"github.com/google/uuid\"",
                "<s0>)",
                "<s0>",
                "<s0>// User represents a user in the system",
                "<s0>type User struct {",
                "<t1>ID    string `json:\"id\"`",
                "<t1>Name  string `json:\"name\"`",
                "<t1>Email string `json:\"email\"`",
                "<s0>}",
                "<s0>",
                "<s0>// NewUser creates a new user with the given name and email",
                "<s0>func NewUser(name, email string) *User {",
                "<t1>return &User{",
                "<t2>ID:    uuid.New().String(),",
                "<t2>Name:  name,",
                "<t2>Email: email,",
                "<t1>}",
                "<s0>}"
            ]
        } else {
            [
                "package models",
                "",
                "import (",
                "\t\"github.com/google/uuid\"",
                ")",
                "",
                "// User represents a user in the system",
                "type User struct {",
                "\tID    string `json:\"id\"`",
                "\tName  string `json:\"name\"`",
                "\tEmail string `json:\"email\"`",
                "}",
                "",
                "// NewUser creates a new user with the given name and email",
                "func NewUser(name, email string) *User {",
                "\treturn &User{",
                "\t\tID:    uuid.New().String(),",
                "\t\tName:  name,",
                "\t\tEmail: email,",
                "\t}",
                "}"
            ]
        }
    }

    // MARK: 3) Create a new "RoundedButton" file

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>package views",
                "<s0>",
                "<s0>import (",
                "<t1>\"fyne.io/fyne/v2\"",
                "<t1>\"fyne.io/fyne/v2/widget\"",
                "<s0>)",
                "<s0>",
                "<s0>// RoundedButton is a button with configurable corner radius",
                "<s0>type RoundedButton struct {",
                "<t1>widget.Button",
                "<t1>cornerRadius float32",
                "<s0>}",
                "<s0>",
                "<s0>// NewRoundedButton creates a new rounded button",
                "<s0>func NewRoundedButton(label string, tapped func()) *RoundedButton {",
                "<t1>btn := &RoundedButton{",
                "<t2>Button:       *widget.NewButton(label, tapped),",
                "<t2>cornerRadius: 0.0,",
                "<t1>}",
                "<t1>return btn",
                "<s0>}",
                "<s0>",
                "<s0>// SetCornerRadius sets the corner radius",
                "<s0>func (b *RoundedButton) SetCornerRadius(radius float32) {",
                "<t1>b.cornerRadius = radius",
                "<t1>b.Refresh()",
                "<s0>}"
            ]
        } else {
            [
                "package views",
                "",
                "import (",
                "\t\"fyne.io/fyne/v2\"",
                "\t\"fyne.io/fyne/v2/widget\"",
                ")",
                "",
                "// RoundedButton is a button with configurable corner radius",
                "type RoundedButton struct {",
                "\twidget.Button",
                "\tcornerRadius float32",
                "}",
                "",
                "// NewRoundedButton creates a new rounded button",
                "func NewRoundedButton(label string, tapped func()) *RoundedButton {",
                "\tbtn := &RoundedButton{",
                "\t\tButton:       *widget.NewButton(label, tapped),",
                "\t\tcornerRadius: 0.0,",
                "\t}",
                "\treturn btn",
                "}",
                "",
                "// SetCornerRadius sets the corner radius",
                "func (b *RoundedButton) SetCornerRadius(radius float32) {",
                "\tb.cornerRadius = radius",
                "\tb.Refresh()",
                "}"
            ]
        }
    }

    // MARK: 4) NetworkManager async/await conversion

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>func fetchData(url string, completion func(string)) {",
                "<t1>resp, err := http.Get(url)",
                "<t1>if err != nil {",
                "<t2>completion(\"\")",
                "<t2>return",
                "<t1>}",
                "<t1>defer resp.Body.Close()",
                "<t1>body, _ := ioutil.ReadAll(resp.Body)",
                "<t1>completion(string(body))",
                "<s0>}"
            ]
        } else {
            [
                "func fetchData(url string, completion func(string)) {",
                "\tresp, err := http.Get(url)",
                "\tif err != nil {",
                "\t\tcompletion(\"\")",
                "\t\treturn",
                "\t}",
                "\tdefer resp.Body.Close()",
                "\tbody, _ := ioutil.ReadAll(resp.Body)",
                "\tcompletion(string(body))",
                "}"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>func fetchData(ctx context.Context, url string) (string, error) {",
                "<t1>req, err := http.NewRequestWithContext(ctx, \"GET\", url, nil)",
                "<t1>if err != nil {",
                "<t2>return \"\", err",
                "<t1>}",
                "<t1>resp, err := http.DefaultClient.Do(req)",
                "<t1>if err != nil {",
                "<t2>return \"\", err",
                "<t1>}",
                "<t1>defer resp.Body.Close()",
                "<t1>body, err := io.ReadAll(resp.Body)",
                "<t1>return string(body), err",
                "<s0>}"
            ]
        } else {
            [
                "func fetchData(ctx context.Context, url string) (string, error) {",
                "\treq, err := http.NewRequestWithContext(ctx, \"GET\", url, nil)",
                "\tif err != nil {",
                "\t\treturn \"\", err",
                "\t}",
                "\tresp, err := http.DefaultClient.Do(req)",
                "\tif err != nil {",
                "\t\treturn \"\", err",
                "\t}",
                "\tdefer resp.Body.Close()",
                "\tbody, err := io.ReadAll(resp.Body)",
                "\treturn string(body), err",
                "}"
            ]
        }
    }

    // MARK: Negative Examples

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>package services",
                "<s0>",
                "<s0>import \"log\"",
                "<s0>",
                "<s0>func processUser(user *User) {",
                "<t1>if user == nil {",
                "<t2>log.Println(\"User is nil\")",
                "<t2>return",
                "<t1>}",
                "<t1>log.Printf(\"Processing user: %s\\n\", user.Name)",
                "<s0>}"
            ]
        } else {
            [
                "package services",
                "",
                "import \"log\"",
                "",
                "func processUser(user *User) {",
                "\tif user == nil {",
                "\t\tlog.Println(\"User is nil\")",
                "\t\treturn",
                "\t}",
                "\tlog.Printf(\"Processing user: %s\\n\", user.Name)",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        // Intentionally mismatched - missing braces
        if includeIndentation {
            [
                "<t1>if user == nil",
                "<t2>log.Println(\"User is nil\")"
            ]
        } else {
            [
                "\tif user == nil",
                "\t\tlog.Println(\"User is nil\")"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<t1>if user == nil || user.Name == \"\" {",
                "<t2>log.Println(\"User is invalid\")",
                "<t2>panic(\"invalid user\")",
                "<t1>}"
            ]
        } else {
            [
                "\tif user == nil || user.Name == \"\" {",
                "\t\tlog.Println(\"User is invalid\")",
                "\t\tpanic(\"invalid user\")",
                "\t}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
        userSearchReplaceNegativeExampleFileContents(includeIndentation: includeIndentation)
    }

    public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<t1>}",
                "<t1>log.Printf(\"Processing user: %s\\n\", user.Name)",
                "<s0>}"
            ]
        } else {
            [
                "\t}",
                "\tlog.Printf(\"Processing user: %s\\n\", user.Name)",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
        // Extra closing brace added
        if includeIndentation {
            [
                "<t1>}",
                "<t1>log.Printf(\"Processing user: %s\\n\", user.Name)",
                "<t1>// Additional validation",
                "<t1>validateUser(user)",
                "<s0>}",
                "<s0>}" // Extra brace
            ]
        } else {
            [
                "\t}",
                "\tlog.Printf(\"Processing user: %s\\n\", user.Name)",
                "\t// Additional validation",
                "\tvalidateUser(user)",
                "}",
                "}" // Extra brace
            ]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<t1>log.Printf(\"Processing user: %s\\n\", user.Name)"]
        } else {
            ["\tlog.Printf(\"Processing user: %s\\n\", user.Name)"]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<t1>log.Printf(\"Processing user: %s (ID: %s)\\n\", user.Name, user.ID)"]
        } else {
            ["\tlog.Printf(\"Processing user: %s (ID: %s)\\n\", user.Name, user.ID)"]
        }
    }

    public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
        // Just closing braces - ambiguous
        if includeIndentation {
            [
                "<t1>}",
                "<s0>}"
            ]
        } else {
            [
                "\t}",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<t1>}",
                "<t1>// TODO: Add more processing",
                "<s0>}"
            ]
        } else {
            [
                "\t}",
                "\t// TODO: Add more processing",
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
            "package services",
            "",
            "import (",
            "    \"errors\"",
            "    \"fmt\"",
            ")",
            "",
            "type UserService struct {",
            "    users []User",
            "}",
            "",
            "func NewUserService() *UserService {",
            "    return &UserService{",
            "        users: make([]User, 0),",
            "    }",
            "}",
            "",
            "func (s *UserService) ProcessUser(userData UserData) (User, error) {",
            "    // Process user data",
            "    user := User{",
            "        ID:   userData.ID,",
            "        Name: userData.Name,",
            "    }",
            "    return user, nil",
            "}",
            "",
            "func (s *UserService) SaveUser(user User) error {",
            "    // Save user to database",
            "    s.users = append(s.users, user)",
            "    return nil",
            "}"
        ]
    }

    public func fileEditorRewriteExampleChange1() -> [String] {
        [
            "func (s *UserService) ProcessUser(userData UserData) (User, error) {",
            "    // Add validation",
            "    if userData.ID == \"\" || userData.Name == \"\" {",
            "        return User{}, errors.New(\"invalid user data\")",
            "    }",
            "    ",
            "    // ... existing code ...",
            "}"
        ]
    }

    public func fileEditorRewriteExampleChange2() -> [String] {
        [
            "func (s *UserService) SaveUser(user User) error {",
            "    // ... existing code ...",
            "    fmt.Println(\"User saved successfully\")",
            "    return nil",
            "}"
        ]
    }

    public func fileEditorRewriteExampleCompleteFile() -> [String] {
        [
            "package services",
            "",
            "import (",
            "    \"errors\"",
            "    \"fmt\"",
            ")",
            "",
            "type UserService struct {",
            "    users []User",
            "}",
            "",
            "func NewUserService() *UserService {",
            "    return &UserService{",
            "        users: make([]User, 0),",
            "    }",
            "}",
            "",
            "func (s *UserService) ProcessUser(userData UserData) (User, error) {",
            "    // Add validation",
            "    if userData.ID == \"\" || userData.Name == \"\" {",
            "        return User{}, errors.New(\"invalid user data\")",
            "    }",
            "    ",
            "    // Process user data",
            "    user := User{",
            "        ID:   userData.ID,",
            "        Name: userData.Name,",
            "    }",
            "    return user, nil",
            "}",
            "",
            "func (s *UserService) SaveUser(user User) error {",
            "    // Save user to database",
            "    s.users = append(s.users, user)",
            "    fmt.Println(\"User saved successfully\")",
            "    return nil",
            "}"
        ]
    }
}
