//
//  DartExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * DartExamples implements CodeExamples for Dart-specific snippets.
 */
public struct DartExamples: CodeExamples {
    // MARK: 1) Search & Replace Lines for "User" class

    public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User {",
                "<s2>final String id;",
                "<s2>final String name;",
                "<s0>}"
            ]
        } else {
            [
                "class User {",
                "  final String id;",
                "  final String name;",
                "}"
            ]
        }
    }

    public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User {",
                "<s2>final String id;",
                "<s2>final String name;",
                "<s2>final String email;",
                "<s0>}"
            ]
        } else {
            [
                "class User {",
                "  final String id;",
                "  final String name;",
                "  final String email;",
                "}"
            ]
        }
    }

    // MARK: 2) Rewrite Entire File with an "Email" property

    public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User {",
                "<s2>final String id;",
                "<s2>final String name;",
                "<s2>final String email;",
                "<s2>",
                "<s2>User({required this.id, required this.name, required this.email});",
                "<s2>",
                "<s2>factory User.fromJson(Map<String, dynamic> json) {",
                "<s4>return User(",
                "<s6>id: json['id'],",
                "<s6>name: json['name'],",
                "<s6>email: json['email'],",
                "<s4>);",
                "<s2>}",
                "<s2>",
                "<s2>Map<String, dynamic> toJson() {",
                "<s4>return {",
                "<s6>'id': id,",
                "<s6>'name': name,",
                "<s6>'email': email,",
                "<s4>};",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "class User {",
                "  final String id;",
                "  final String name;",
                "  final String email;",
                "",
                "  User({required this.id, required this.name, required this.email});",
                "",
                "  factory User.fromJson(Map<String, dynamic> json) {",
                "    return User(",
                "      id: json['id'],",
                "      name: json['name'],",
                "      email: json['email'],",
                "    );",
                "  }",
                "",
                "  Map<String, dynamic> toJson() {",
                "    return {",
                "      'id': id,",
                "      'name': name,",
                "      'email': email,",
                "    };",
                "  }",
                "}"
            ]
        }
    }

    // MARK: 3) Create a new "RoundedButton" widget

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import 'package:flutter/material.dart';",
                "<s0>",
                "<s0>class RoundedButton extends StatelessWidget {",
                "<s2>final String text;",
                "<s2>final VoidCallback? onPressed;",
                "<s2>final double borderRadius;",
                "<s2>final Color backgroundColor;",
                "<s2>",
                "<s2>const RoundedButton({",
                "<s4>Key? key,",
                "<s4>required this.text,",
                "<s4>this.onPressed,",
                "<s4>this.borderRadius = 8.0,",
                "<s4>this.backgroundColor = Colors.blue,",
                "<s2>}) : super(key: key);",
                "<s2>",
                "<s2>@override",
                "<s2>Widget build(BuildContext context) {",
                "<s4>return ElevatedButton(",
                "<s6>onPressed: onPressed,",
                "<s6>style: ElevatedButton.styleFrom(",
                "<s8>backgroundColor: backgroundColor,",
                "<s8>shape: RoundedRectangleBorder(",
                "<s10>borderRadius: BorderRadius.circular(borderRadius),",
                "<s8>),",
                "<s6>),",
                "<s6>child: Text(text),",
                "<s4>);",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "import 'package:flutter/material.dart';",
                "",
                "class RoundedButton extends StatelessWidget {",
                "  final String text;",
                "  final VoidCallback? onPressed;",
                "  final double borderRadius;",
                "  final Color backgroundColor;",
                "",
                "  const RoundedButton({",
                "    Key? key,",
                "    required this.text,",
                "    this.onPressed,",
                "    this.borderRadius = 8.0,",
                "    this.backgroundColor = Colors.blue,",
                "  }) : super(key: key);",
                "",
                "  @override",
                "  Widget build(BuildContext context) {",
                "    return ElevatedButton(",
                "      onPressed: onPressed,",
                "      style: ElevatedButton.styleFrom(",
                "        backgroundColor: backgroundColor,",
                "        shape: RoundedRectangleBorder(",
                "          borderRadius: BorderRadius.circular(borderRadius),",
                "        ),",
                "      ),",
                "      child: Text(text),",
                "    );",
                "  }",
                "}"
            ]
        }
    }

    // MARK: 4) NetworkManager async/await conversion

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>void fetchData(String url, Function(String) completion) {",
                "<s2>http.get(Uri.parse(url)).then((response) {",
                "<s4>if (response.statusCode == 200) {",
                "<s6>completion(response.body);",
                "<s4>} else {",
                "<s6>completion('Error: ${response.statusCode}');",
                "<s4>}",
                "<s2>}).catchError((error) {",
                "<s4>completion('Error: $error');",
                "<s2>});",
                "<s0>}"
            ]
        } else {
            [
                "void fetchData(String url, Function(String) completion) {",
                "  http.get(Uri.parse(url)).then((response) {",
                "    if (response.statusCode == 200) {",
                "      completion(response.body);",
                "    } else {",
                "      completion('Error: ${response.statusCode}');",
                "    }",
                "  }).catchError((error) {",
                "    completion('Error: $error');",
                "  });",
                "}"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>Future<String> fetchData(String url) async {",
                "<s2>try {",
                "<s4>final response = await http.get(Uri.parse(url));",
                "<s4>if (response.statusCode == 200) {",
                "<s6>return response.body;",
                "<s4>} else {",
                "<s6>throw Exception('HTTP Error: ${response.statusCode}');",
                "<s4>}",
                "<s2>} catch (error) {",
                "<s4>throw Exception('Network Error: $error');",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "Future<String> fetchData(String url) async {",
                "  try {",
                "    final response = await http.get(Uri.parse(url));",
                "    if (response.statusCode == 200) {",
                "      return response.body;",
                "    } else {",
                "      throw Exception('HTTP Error: ${response.statusCode}');",
                "    }",
                "  } catch (error) {",
                "    throw Exception('Network Error: $error');",
                "  }",
                "}"
            ]
        }
    }

    // MARK: Negative Examples

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class UserService {",
                "<s2>final ApiClient _apiClient;",
                "<s2>",
                "<s2>UserService(this._apiClient);",
                "<s2>",
                "<s2>Future<void> processUser(User user) async {",
                "<s4>if (user == null) {",
                "<s6>throw ArgumentError('User cannot be null');",
                "<s4>}",
                "<s4>print('Processing user: ${user.name}');",
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "class UserService {",
                "  final ApiClient _apiClient;",
                "",
                "  UserService(this._apiClient);",
                "",
                "  Future<void> processUser(User user) async {",
                "    if (user == null) {",
                "      throw ArgumentError('User cannot be null');",
                "    }",
                "    print('Processing user: ${user.name}');",
                "  }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        // Intentionally mismatched - missing braces and different indentation
        if includeIndentation {
            [
                "<s4>if (user == null)",
                "<s6>throw ArgumentError('User cannot be null');"
            ]
        } else {
            [
                "    if (user == null)",
                "      throw ArgumentError('User cannot be null');"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>if (user == null || user.name.isEmpty) {",
                "<s6>throw ArgumentError('User is invalid');",
                "<s4>}"
            ]
        } else {
            [
                "    if (user == null || user.name.isEmpty) {",
                "      throw ArgumentError('User is invalid');",
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
                "<s4>print('Processing user: ${user.name}');",
                "<s2>}"
            ]
        } else {
            [
                "    }",
                "    print('Processing user: ${user.name}');",
                "  }"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
        // Extra closing brace added
        if includeIndentation {
            [
                "<s4>}",
                "<s4>print('Processing user: ${user.name}');",
                "<s4>// Additional processing",
                "<s4>validateUser(user);",
                "<s2>}",
                "<s2>}" // Extra brace
            ]
        } else {
            [
                "    }",
                "    print('Processing user: ${user.name}');",
                "    // Additional processing",
                "    validateUser(user);",
                "  }",
                "  }" // Extra brace
            ]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<s4>print('Processing user: ${user.name}');"]
        } else {
            ["    print('Processing user: ${user.name}');"]
        }
    }

    public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            ["<s4>print('Processing user: ${user.name} with ID: ${user.id}');"]
        } else {
            ["    print('Processing user: ${user.name} with ID: ${user.id}');"]
        }
    }

    public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
        // Just closing braces - ambiguous
        if includeIndentation {
            [
                "<s2>}",
                "<s0>}"
            ]
        } else {
            [
                "  }",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s2>}",
                "<s2>// TODO: Add more processing",
                "<s0>}"
            ]
        } else {
            [
                "  }",
                "  // TODO: Add more processing",
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
            "class User {",
            "  final String id;",
            "  final String name;",
            "  ",
            "  User({required this.id, required this.name});",
            "}",
            "",
            "class UserService {",
            "  final List<User> _users = [];",
            "  ",
            "  UserService() {",
            "    // Initialize service",
            "  }",
            "  ",
            "  User processUser(Map<String, dynamic> userData) {",
            "    // Process user data",
            "    final user = User(",
            "      id: userData['id'],",
            "      name: userData['name'],",
            "    );",
            "    return user;",
            "  }",
            "  ",
            "  void saveUser(User user) {",
            "    // Save user to database",
            "    _users.add(user);",
            "  }",
            "}"
        ]
    }

    public func fileEditorRewriteExampleChange1() -> [String] {
        [
            "  User processUser(Map<String, dynamic> userData) {",
            "    // Add validation",
            "    if (userData['id'] == null || userData['name'] == null ||",
            "        userData['id'].isEmpty || userData['name'].isEmpty) {",
            "      throw ArgumentError('Invalid user data');",
            "    }",
            "    ",
            "    // ... existing code ...",
            "  }"
        ]
    }

    public func fileEditorRewriteExampleChange2() -> [String] {
        [
            "  void saveUser(User user) {",
            "    try {",
            "      // ... existing code ...",
            "      print('User saved successfully');",
            "    } catch (e) {",
            "      print('Failed to save user: $e');",
            "      rethrow;",
            "    }",
            "  }"
        ]
    }

    public func fileEditorRewriteExampleCompleteFile() -> [String] {
        [
            "class User {",
            "  final String id;",
            "  final String name;",
            "  ",
            "  User({required this.id, required this.name});",
            "}",
            "",
            "class UserService {",
            "  final List<User> _users = [];",
            "  ",
            "  UserService() {",
            "    // Initialize service",
            "  }",
            "  ",
            "  User processUser(Map<String, dynamic> userData) {",
            "    // Add validation",
            "    if (userData['id'] == null || userData['name'] == null ||",
            "        userData['id'].isEmpty || userData['name'].isEmpty) {",
            "      throw ArgumentError('Invalid user data');",
            "    }",
            "    ",
            "    // Process user data",
            "    final user = User(",
            "      id: userData['id'],",
            "      name: userData['name'],",
            "    );",
            "    return user;",
            "  }",
            "  ",
            "  void saveUser(User user) {",
            "    try {",
            "      // Save user to database",
            "      _users.add(user);",
            "      print('User saved successfully');",
            "    } catch (e) {",
            "      print('Failed to save user: $e');",
            "      rethrow;",
            "    }",
            "  }",
            "}"
        ]
    }
}
