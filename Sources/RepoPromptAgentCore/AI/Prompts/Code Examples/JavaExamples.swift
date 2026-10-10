//
//  JavaExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-01-14.
//

import Foundation

/**
 * JavaExamples implements CodeExamples for Java-specific snippets.
 */
public struct JavaExamples: CodeExamples {
    // MARK: 1) Search & Replace Lines for "User" class

    public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>public class User {",
                "<s4>private UUID id;",
                "<s4>private String name;",
                "<s0>}"
            ]
        } else {
            [
                "public class User {",
                "    private UUID id;",
                "    private String name;",
                "}"
            ]
        }
    }

    public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>public class User {",
                "<s4>private UUID id;",
                "<s4>private String name;",
                "<s4>private String email;",
                "<s0>}"
            ]
        } else {
            [
                "public class User {",
                "    private UUID id;",
                "    private String name;",
                "    private String email;",
                "}"
            ]
        }
    }

    // MARK: 2) Rewrite Entire File with an "email" field

    public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import java.util.UUID;",
                "<s0>",
                "<s0>public class User {",
                "<s4>private final UUID id;",
                "<s4>private String name;",
                "<s4>private String email;",
                "<s4>",
                "<s4>public User(String name, String email) {",
                "<s8>this.id = UUID.randomUUID();",
                "<s8>this.name = name;",
                "<s8>this.email = email;",
                "<s4>}",
                "<s4>",
                "<s4>public UUID getId() {",
                "<s8>return id;",
                "<s4>}",
                "<s4>",
                "<s4>public String getName() {",
                "<s8>return name;",
                "<s4>}",
                "<s4>",
                "<s4>public void setName(String name) {",
                "<s8>this.name = name;",
                "<s4>}",
                "<s4>",
                "<s4>public String getEmail() {",
                "<s8>return email;",
                "<s4>}",
                "<s4>",
                "<s4>public void setEmail(String email) {",
                "<s8>this.email = email;",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "import java.util.UUID;",
                "",
                "public class User {",
                "    private final UUID id;",
                "    private String name;",
                "    private String email;",
                "    ",
                "    public User(String name, String email) {",
                "        this.id = UUID.randomUUID();",
                "        this.name = name;",
                "        this.email = email;",
                "    }",
                "    ",
                "    public UUID getId() {",
                "        return id;",
                "    }",
                "    ",
                "    public String getName() {",
                "        return name;",
                "    }",
                "    ",
                "    public void setName(String name) {",
                "        this.name = name;",
                "    }",
                "    ",
                "    public String getEmail() {",
                "        return email;",
                "    }",
                "    ",
                "    public void setEmail(String email) {",
                "        this.email = email;",
                "    }",
                "}"
            ]
        }
    }

    // MARK: 3) Create a new "RoundedButton" file

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import javax.swing.JButton;",
                "<s0>import java.awt.Graphics;",
                "<s0>import java.awt.Graphics2D;",
                "<s0>import java.awt.RenderingHints;",
                "<s0>",
                "<s0>public class RoundedButton extends JButton {",
                "<s4>private int cornerRadius = 0;",
                "<s4>",
                "<s4>public RoundedButton(String text) {",
                "<s8>super(text);",
                "<s8>setOpaque(false);",
                "<s4>}",
                "<s4>",
                "<s4>public void setCornerRadius(int cornerRadius) {",
                "<s8>this.cornerRadius = cornerRadius;",
                "<s8>repaint();",
                "<s4>}",
                "<s4>",
                "<s4>@Override",
                "<s4>protected void paintComponent(Graphics g) {",
                "<s8>Graphics2D g2 = (Graphics2D) g.create();",
                "<s8>g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);",
                "<s8>g2.fillRoundRect(0, 0, getWidth()-1, getHeight()-1, cornerRadius, cornerRadius);",
                "<s8>super.paintComponent(g2);",
                "<s8>g2.dispose();",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "import javax.swing.JButton;",
                "import java.awt.Graphics;",
                "import java.awt.Graphics2D;",
                "import java.awt.RenderingHints;",
                "",
                "public class RoundedButton extends JButton {",
                "    private int cornerRadius = 0;",
                "    ",
                "    public RoundedButton(String text) {",
                "        super(text);",
                "        setOpaque(false);",
                "    }",
                "    ",
                "    public void setCornerRadius(int cornerRadius) {",
                "        this.cornerRadius = cornerRadius;",
                "        repaint();",
                "    }",
                "    ",
                "    @Override",
                "    protected void paintComponent(Graphics g) {",
                "        Graphics2D g2 = (Graphics2D) g.create();",
                "        g2.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);",
                "        g2.fillRoundRect(0, 0, getWidth()-1, getHeight()-1, cornerRadius, cornerRadius);",
                "        super.paintComponent(g2);",
                "        g2.dispose();",
                "    }",
                "}"
            ]
        }
    }

    // MARK: 4) Indentation-Preserving Example (async/await equivalent using CompletableFuture)

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>public class NetworkManager {",
                "<s4>public void fetchData(URL url, Consumer<byte[]> callback) {",
                "<s8>// old synchronous code",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "public class NetworkManager {",
                "    public void fetchData(URL url, Consumer<byte[]> callback) {",
                "        // old synchronous code",
                "    }",
                "}"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>public class NetworkManager {",
                "<s4>public CompletableFuture<byte[]> fetchData(URL url) {",
                "<s8>return CompletableFuture.supplyAsync(() -> {",
                "<s12>try {",
                "<s16>HttpURLConnection conn = (HttpURLConnection) url.openConnection();",
                "<s16>return conn.getInputStream().readAllBytes();",
                "<s12>} catch (IOException e) {",
                "<s16>throw new CompletionException(e);",
                "<s12>}",
                "<s8>});",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "public class NetworkManager {",
                "    public CompletableFuture<byte[]> fetchData(URL url) {",
                "        return CompletableFuture.supplyAsync(() -> {",
                "            try {",
                "                HttpURLConnection conn = (HttpURLConnection) url.openConnection();",
                "                return conn.getInputStream().readAllBytes();",
                "            } catch (IOException e) {",
                "                throw new CompletionException(e);",
                "            }",
                "        });",
                "    }",
                "}"
            ]
        }
    }

    // MARK: - Negative Examples for Search/Replace

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import java.util.*;",
                "<s0>public class Example {",
                "<s0>    void foo() {",
                "<s0>        bar();",
                "<s0>    }",
                "<s0>}"
            ]
        } else {
            [
                "import java.util.*;",
                "public class Example {",
                "    void foo() {",
                "        bar();",
                "    }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>void foo() {",
                "<s8>bar();",
                "<s4>}"
            ]
        } else {
            [
                "    void foo() {",
                "        bar();",
                "    }"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>void foo() {",
                "<s8>bar();",
                "<s8>bar2();",
                "<s4>}"
            ]
        } else {
            [
                "    void foo() {",
                "        bar();",
                "        bar2();",
                "    }"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>public void someMethod() {",
                "<s4>foo() {",
                "<s8>bar();",
                "<s4>}",
                "<s0>}"
            ]
        } else {
            [
                "public void someMethod() {",
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
                "<s0>private String email;"
            ]
        } else {
            [
                "private String email;"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>private String emailAddress;"
            ]
        } else {
            [
                "private String emailAddress;"
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
            "import java.util.ArrayList;",
            "import java.util.List;",
            "",
            "public class UserService {",
            "    private List<User> users;",
            "    ",
            "    public UserService() {",
            "        this.users = new ArrayList<>();",
            "    }",
            "    ",
            "    public User processUser(UserData userData) {",
            "        // Process user data",
            "        User user = new User(",
            "            userData.getId(),",
            "            userData.getName()",
            "        );",
            "        return user;",
            "    }",
            "    ",
            "    public void saveUser(User user) {",
            "        // Save user to database",
            "        users.add(user);",
            "    }",
            "}"
        ]
    }

    public func fileEditorRewriteExampleChange1() -> [String] {
        [
            "    public User processUser(UserData userData) {",
            "        // Add validation",
            "        if (userData == null || userData.getId() == null || userData.getName() == null) {",
            "            throw new IllegalArgumentException(\"Invalid user data\");",
            "        }",
            "        ",
            "        // ... existing code ...",
            "    }"
        ]
    }

    public func fileEditorRewriteExampleChange2() -> [String] {
        [
            "    public void saveUser(User user) {",
            "        try {",
            "            // ... existing code ...",
            "            System.out.println(\"User saved successfully\");",
            "        } catch (Exception e) {",
            "            System.err.println(\"Failed to save user: \" + e.getMessage());",
            "            throw e;",
            "        }",
            "    }"
        ]
    }

    public func fileEditorRewriteExampleCompleteFile() -> [String] {
        [
            "import java.util.ArrayList;",
            "import java.util.List;",
            "",
            "public class UserService {",
            "    private List<User> users;",
            "    ",
            "    public UserService() {",
            "        this.users = new ArrayList<>();",
            "    }",
            "    ",
            "    public User processUser(UserData userData) {",
            "        // Add validation",
            "        if (userData == null || userData.getId() == null || userData.getName() == null) {",
            "            throw new IllegalArgumentException(\"Invalid user data\");",
            "        }",
            "        ",
            "        // Process user data",
            "        User user = new User(",
            "            userData.getId(),",
            "            userData.getName()",
            "        );",
            "        return user;",
            "    }",
            "    ",
            "    public void saveUser(User user) {",
            "        try {",
            "            // Save user to database",
            "            users.add(user);",
            "            System.out.println(\"User saved successfully\");",
            "        } catch (Exception e) {",
            "            System.err.println(\"Failed to save user: \" + e.getMessage());",
            "            throw e;",
            "        }",
            "    }",
            "}"
        ]
    }
}
