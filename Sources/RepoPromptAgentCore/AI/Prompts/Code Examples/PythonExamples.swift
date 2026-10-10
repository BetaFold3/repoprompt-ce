//
//  PythonExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-01-14.
//

import Foundation

/**
 * PythonExamples implements CodeExamples for Python-specific snippets.
 */
public struct PythonExamples: CodeExamples {
    // MARK: 1) Search & Replace Lines for "User" class

    public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User:",
                "<s4>def __init__(self, id, name):",
                "<s8>self.id = id",
                "<s8>self.name = name"
            ]
        } else {
            [
                "class User:",
                "    def __init__(self, id, name):",
                "        self.id = id",
                "        self.name = name"
            ]
        }
    }

    public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>class User:",
                "<s4>def __init__(self, id, name, email):",
                "<s8>self.id = id",
                "<s8>self.name = name",
                "<s8>self.email = email"
            ]
        } else {
            [
                "class User:",
                "    def __init__(self, id, name, email):",
                "        self.id = id",
                "        self.name = name",
                "        self.email = email"
            ]
        }
    }

    // MARK: 2) Rewrite All Lines

    public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>from datetime import datetime",
                "<s0>",
                "<s0>class User:",
                "<s4>def __init__(self, id, name, email, role='user'):",
                "<s8>self.id = id",
                "<s8>self.name = name",
                "<s8>self.email = email",
                "<s8>self.role = role",
                "<s8>self.created_at = datetime.now()",
                "<s4>",
                "<s4>def get_display_name(self):",
                "<s8>return f\"{self.name} ({self.email})\""
            ]
        } else {
            [
                "from datetime import datetime",
                "",
                "class User:",
                "    def __init__(self, id, name, email, role='user'):",
                "        self.id = id",
                "        self.name = name",
                "        self.email = email",
                "        self.role = role",
                "        self.created_at = datetime.now()",
                "    ",
                "    def get_display_name(self):",
                "        return f\"{self.name} ({self.email})\""
            ]
        }
    }

    // MARK: 3) Create All Lines

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0># models/user.py",
                "<s0>from dataclasses import dataclass",
                "<s0>from typing import Dict, Any",
                "<s0>",
                "<s0>@dataclass",
                "<s0>class User:",
                "<s4>id: str",
                "<s4>name: str",
                "<s4>email: str",
                "<s4>",
                "<s4>def to_dict(self) -> Dict[str, Any]:",
                "<s8>return {",
                "<s12>'id': self.id,",
                "<s12>'name': self.name,",
                "<s12>'email': self.email",
                "<s8>}"
            ]
        } else {
            [
                "# models/user.py",
                "from dataclasses import dataclass",
                "from typing import Dict, Any",
                "",
                "@dataclass",
                "class User:",
                "    id: str",
                "    name: str",
                "    email: str",
                "    ",
                "    def to_dict(self) -> Dict[str, Any]:",
                "        return {",
                "            'id': self.id,",
                "            'name': self.name,",
                "            'email': self.email",
                "        }"
            ]
        }
    }

    // MARK: 4) NetworkManager Example

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import requests",
                "<s0>",
                "<s0>class APIClient:",
                "<s4>def fetch_data(self, endpoint):",
                "<s8>response = requests.get(endpoint)",
                "<s8>return response.json()"
            ]
        } else {
            [
                "import requests",
                "",
                "class APIClient:",
                "    def fetch_data(self, endpoint):",
                "        response = requests.get(endpoint)",
                "        return response.json()"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import requests",
                "<s0>import logging",
                "<s0>",
                "<s0>class APIClient:",
                "<s4>def fetch_data(self, endpoint, **kwargs):",
                "<s8>try:",
                "<s12>headers = kwargs.get('headers', {})",
                "<s12>headers['Content-Type'] = 'application/json'",
                "<s12>",
                "<s12>response = requests.get(endpoint, headers=headers, **kwargs)",
                "<s12>response.raise_for_status()",
                "<s12>",
                "<s12>return response.json()",
                "<s8>except requests.RequestException as e:",
                "<s12>logging.error(f'API request failed: {e}')",
                "<s12>raise"
            ]
        } else {
            [
                "import requests",
                "import logging",
                "",
                "class APIClient:",
                "    def fetch_data(self, endpoint, **kwargs):",
                "        try:",
                "            headers = kwargs.get('headers', {})",
                "            headers['Content-Type'] = 'application/json'",
                "            ",
                "            response = requests.get(endpoint, headers=headers, **kwargs)",
                "            response.raise_for_status()",
                "            ",
                "            return response.json()",
                "        except requests.RequestException as e:",
                "            logging.error(f'API request failed: {e}')",
                "            raise"
            ]
        }
    }

    // MARK: 5) Negative Examples

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        [
            "class User:",
            "    def __init__(self, id, name):",
            "        self.id = id",
            "        self.name = name",
            "        self.is_active = True",
            "    ",
            "    def get_info(self):",
            "        return f\"User: {self.name}\""
        ]
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        [
            "    def __init__(self, id, name):",
            "        self.id = id",
            "        self.name = name"
        ]
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        [
            "    def __init__(self, id, name, email):",
            "        self.id = id",
            "        self.name = name",
            "        self.email = email"
        ]
    }

    /// Brace mismatch example (Python uses indentation)
    public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
        [
            "def process_data(items):",
            "    if len(items) > 0:",
            "        for item in items:",
            "            print(item)",
            "    return len(items)"
        ]
    }

    public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
        [
            "    if len(items) > 0:",
            "        for item in items:",
            "            print(item)"
        ]
    }

    public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
        [
            "    if len(items) > 0:",
            "        print(f'Processing {len(items)} items')",
            "        for item in items:",
            "            print(item)"
        ]
    }

    /// One-line search block
    public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
        ["print(item)"]
    }

    public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
        ["print('Item:', item)"]
    }

    /// Ambiguous search block
    public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
        ["return"]
    }

    public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
        [
            "    logging.debug('Processing complete')",
            "    return"
        ]
    }

    public func commentSyntax() -> String {
        "#"
    }

    // MARK: - File Editor Example Methods

    public func fileEditorExampleFileContents() -> [String] {
        [
            "class GameManager:",
            "    def __init__(self):",
            "        self.score = 0",
            "        self.level = 1",
            "        self.is_running = False",
            "    ",
            "    def reset(self):",
            "        self.score = 0",
            "        self.level = 1",
            "        self.is_running = False",
            "    ",
            "    def check_proximity(self, position):",
            "        # Calculate distance logic here",
            "        return 0.0"
        ]
    }

    public func fileEditorExampleChange1() -> [String] {
        [
            "        # ... existing code ...",
            "        self.is_running = False",
            "        print('GameManager initialized')",
            "    ",
            "    def reset(self):",
            "        # ... existing code ..."
        ]
    }

    public func fileEditorExampleChange2() -> [String] {
        [
            "        # ... existing code ...",
            "        return 0.0",
            "    ",
            "    def __del__(self):",
            "        print('GameManager cleaned up')"
        ]
    }

    public func fileEditorExampleSearchBlock() -> [String] {
        [
            "        self.is_running = False",
            "    ",
            "    def reset(self):"
        ]
    }

    public func fileEditorExampleContentBlock() -> [String] {
        [
            "        self.is_running = False",
            "        print('GameManager initialized')",
            "    ",
            "    def reset(self):"
        ]
    }

    public func fileEditorExampleSearchBlock2() -> [String] {
        [
            "    def check_proximity(self, position):",
            "        # Calculate distance logic here",
            "        return 0.0"
        ]
    }

    public func fileEditorExampleContentBlock2() -> [String] {
        [
            "    def check_proximity(self, position):",
            "        # Calculate distance logic here",
            "        return 0.0",
            "    ",
            "    def __del__(self):",
            "        print('GameManager cleaned up')"
        ]
    }

    // MARK: - Rewrite-Only File Editor Example Methods

    public func fileEditorRewriteExampleFileContents() -> [String] {
        [
            "from typing import Dict, List",
            "",
            "class UserService:",
            "    def __init__(self):",
            "        self.users: List[Dict] = []",
            "    ",
            "    def process_user(self, user_data: Dict) -> Dict:",
            "        # Process user data",
            "        user = {",
            "            'id': user_data['id'],",
            "            'name': user_data['name']",
            "        }",
            "        return user",
            "    ",
            "    def save_user(self, user: Dict) -> None:",
            "        # Save user to database",
            "        self.users.append(user)"
        ]
    }

    public func fileEditorRewriteExampleChange1() -> [String] {
        [
            "    def process_user(self, user_data: Dict) -> Dict:",
            "        # Add validation",
            "        if not user_data or 'id' not in user_data or 'name' not in user_data:",
            "            raise ValueError('Invalid user data')",
            "        ",
            "        # ... existing code ..."
        ]
    }

    public func fileEditorRewriteExampleChange2() -> [String] {
        [
            "    def save_user(self, user: Dict) -> None:",
            "        try:",
            "            # ... existing code ...",
            "            print('User saved successfully')",
            "        except Exception as e:",
            "            print(f'Failed to save user: {e}')",
            "            raise"
        ]
    }

    public func fileEditorRewriteExampleCompleteFile() -> [String] {
        [
            "from typing import Dict, List",
            "",
            "class UserService:",
            "    def __init__(self):",
            "        self.users: List[Dict] = []",
            "    ",
            "    def process_user(self, user_data: Dict) -> Dict:",
            "        # Add validation",
            "        if not user_data or 'id' not in user_data or 'name' not in user_data:",
            "            raise ValueError('Invalid user data')",
            "        ",
            "        # Process user data",
            "        user = {",
            "            'id': user_data['id'],",
            "            'name': user_data['name']",
            "        }",
            "        return user",
            "    ",
            "    def save_user(self, user: Dict) -> None:",
            "        try:",
            "            # Save user to database",
            "            self.users.append(user)",
            "            print('User saved successfully')",
            "        except Exception as e:",
            "            print(f'Failed to save user: {e}')",
            "            raise"
        ]
    }
}
