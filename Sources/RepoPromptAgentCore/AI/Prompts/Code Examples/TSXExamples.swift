//
//  TSXExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * TSXExamples implements CodeExamples for TSX (TypeScript + JSX) specific snippets.
 */
public struct TSXExamples: CodeExamples {
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
                "<s0>import React from 'react';",
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
                "<s0>interface UserCardProps {",
                "<s4>user: User;",
                "<s4>onEdit?: (user: User) => void;",
                "<s0>}",
                "<s0>",
                "<s0>export const UserCard: React.FC<UserCardProps> = ({ user, onEdit }) => {",
                "<s4>const handleEdit = () => {",
                "<s8>onEdit?.(user);",
                "<s4>};",
                "<s4>",
                "<s4>return (",
                "<s8><div className=\"user-card\">",
                "<s12><h3>{user.name}</h3>",
                "<s12><p>Email: {user.email}</p>",
                "<s12><p>Role: {user.role || 'user'}</p>",
                "<s12>{onEdit && (",
                "<s16><button onClick={handleEdit}>Edit User</button>",
                "<s12>)}",
                "<s8></div>",
                "<s4>);",
                "<s0>};"
            ]
        } else {
            [
                "import React from 'react';",
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
                "interface UserCardProps {",
                "    user: User;",
                "    onEdit?: (user: User) => void;",
                "}",
                "",
                "export const UserCard: React.FC<UserCardProps> = ({ user, onEdit }) => {",
                "    const handleEdit = () => {",
                "        onEdit?.(user);",
                "    };",
                "",
                "    return (",
                "        <div className=\"user-card\">",
                "            <h3>{user.name}</h3>",
                "            <p>Email: {user.email}</p>",
                "            <p>Role: {user.role || 'user'}</p>",
                "            {onEdit && (",
                "                <button onClick={handleEdit}>Edit User</button>",
                "            )}",
                "        </div>",
                "    );",
                "};"
            ]
        }
    }

    // MARK: 3) Create a new "RoundedButton" component

    public func userCreateAllLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import React, { CSSProperties } from 'react';",
                "<s0>",
                "<s0>interface RoundedButtonProps {",
                "<s4>text: string;",
                "<s4>cornerRadius?: number;",
                "<s4>onClick?: () => void;",
                "<s4>variant?: 'primary' | 'secondary';",
                "<s4>disabled?: boolean;",
                "<s0>}",
                "<s0>",
                "<s0>export const RoundedButton: React.FC<RoundedButtonProps> = ({",
                "<s4>text,",
                "<s4>cornerRadius = 8,",
                "<s4>onClick,",
                "<s4>variant = 'primary',",
                "<s4>disabled = false",
                "<s0>}) => {",
                "<s4>const baseStyle: CSSProperties = {",
                "<s8>borderRadius: `${cornerRadius}px`,",
                "<s8>padding: '10px 20px',",
                "<s8>border: 'none',",
                "<s8>cursor: disabled ? 'not-allowed' : 'pointer',",
                "<s8>opacity: disabled ? 0.6 : 1,",
                "<s8>fontSize: '14px',",
                "<s8>fontWeight: 'medium'",
                "<s4>};",
                "<s4>",
                "<s4>const variantStyle: CSSProperties = variant === 'primary' ? {",
                "<s8>backgroundColor: '#007bff',",
                "<s8>color: 'white'",
                "<s4>} : {",
                "<s8>backgroundColor: '#f8f9fa',",
                "<s8>color: '#212529',",
                "<s8>border: '1px solid #dee2e6'",
                "<s4>};",
                "<s4>",
                "<s4>return (",
                "<s8><button",
                "<s12>style={{ ...baseStyle, ...variantStyle }}",
                "<s12>onClick={onClick}",
                "<s12>disabled={disabled}",
                "<s8>>",
                "<s12>{text}",
                "<s8></button>",
                "<s4>);",
                "<s0>};"
            ]
        } else {
            [
                "import React, { CSSProperties } from 'react';",
                "",
                "interface RoundedButtonProps {",
                "    text: string;",
                "    cornerRadius?: number;",
                "    onClick?: () => void;",
                "    variant?: 'primary' | 'secondary';",
                "    disabled?: boolean;",
                "}",
                "",
                "export const RoundedButton: React.FC<RoundedButtonProps> = ({",
                "    text,",
                "    cornerRadius = 8,",
                "    onClick,",
                "    variant = 'primary',",
                "    disabled = false",
                "}) => {",
                "    const baseStyle: CSSProperties = {",
                "        borderRadius: `${cornerRadius}px`,",
                "        padding: '10px 20px',",
                "        border: 'none',",
                "        cursor: disabled ? 'not-allowed' : 'pointer',",
                "        opacity: disabled ? 0.6 : 1,",
                "        fontSize: '14px',",
                "        fontWeight: 'medium'",
                "    };",
                "",
                "    const variantStyle: CSSProperties = variant === 'primary' ? {",
                "        backgroundColor: '#007bff',",
                "        color: 'white'",
                "    } : {",
                "        backgroundColor: '#f8f9fa',",
                "        color: '#212529',",
                "        border: '1px solid #dee2e6'",
                "    };",
                "",
                "    return (",
                "        <button",
                "            style={{ ...baseStyle, ...variantStyle }}",
                "            onClick={onClick}",
                "            disabled={disabled}",
                "        >",
                "            {text}",
                "        </button>",
                "    );",
                "};"
            ]
        }
    }

    // MARK: 4) Component lifecycle example (React hooks)

    public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>export const UserList: React.FC = () => {",
                "<s4>const [users, setUsers] = useState<User[]>([]);",
                "<s4>",
                "<s4>useEffect(() => {",
                "<s8>// old Promise-based approach",
                "<s8>fetchUsers().then(setUsers);",
                "<s4>}, []);",
                "<s4>",
                "<s4>return <div>{/* render users */}</div>;",
                "<s0>};"
            ]
        } else {
            [
                "export const UserList: React.FC = () => {",
                "    const [users, setUsers] = useState<User[]>([]);",
                "",
                "    useEffect(() => {",
                "        // old Promise-based approach",
                "        fetchUsers().then(setUsers);",
                "    }, []);",
                "",
                "    return <div>{/* render users */}</div>;",
                "};"
            ]
        }
    }

    public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>export const UserList: React.FC = () => {",
                "<s4>const [users, setUsers] = useState<User[]>([]);",
                "<s4>const [loading, setLoading] = useState(false);",
                "<s4>const [error, setError] = useState<string | null>(null);",
                "<s4>",
                "<s4>useEffect(() => {",
                "<s8>const loadUsers = async () => {",
                "<s12>setLoading(true);",
                "<s12>setError(null);",
                "<s12>try {",
                "<s16>const userData = await fetchUsers();",
                "<s16>setUsers(userData);",
                "<s12>} catch (err) {",
                "<s16>setError(err instanceof Error ? err.message : 'Unknown error');",
                "<s12>} finally {",
                "<s16>setLoading(false);",
                "<s12>}",
                "<s8>};",
                "<s8>",
                "<s8>loadUsers();",
                "<s4>}, []);",
                "<s4>",
                "<s4>if (loading) return <div>Loading...</div>;",
                "<s4>if (error) return <div>Error: {error}</div>;",
                "<s4>",
                "<s4>return <div>{/* render users */}</div>;",
                "<s0>};"
            ]
        } else {
            [
                "export const UserList: React.FC = () => {",
                "    const [users, setUsers] = useState<User[]>([]);",
                "    const [loading, setLoading] = useState(false);",
                "    const [error, setError] = useState<string | null>(null);",
                "",
                "    useEffect(() => {",
                "        const loadUsers = async () => {",
                "            setLoading(true);",
                "            setError(null);",
                "            try {",
                "                const userData = await fetchUsers();",
                "                setUsers(userData);",
                "            } catch (err) {",
                "                setError(err instanceof Error ? err.message : 'Unknown error');",
                "            } finally {",
                "                setLoading(false);",
                "            }",
                "        };",
                "",
                "        loadUsers();",
                "    }, []);",
                "",
                "    if (loading) return <div>Loading...</div>;",
                "    if (error) return <div>Error: {error}</div>;",
                "",
                "    return <div>{/* render users */}</div>;",
                "};"
            ]
        }
    }

    // MARK: - Negative Examples for Search/Replace

    public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>import React from 'react';",
                "<s0>",
                "<s0>export const Example: React.FC = () => {",
                "<s4>const foo = () => {",
                "<s8>bar();",
                "<s4>};",
                "<s4>",
                "<s4>return <div>Hello</div>;",
                "<s0>};"
            ]
        } else {
            [
                "import React from 'react';",
                "",
                "export const Example: React.FC = () => {",
                "    const foo = () => {",
                "        bar();",
                "    };",
                "",
                "    return <div>Hello</div>;",
                "};"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>const foo = () => {",
                "<s8>bar();",
                "<s4>};"
            ]
        } else {
            [
                "    const foo = () => {",
                "        bar();",
                "    };"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>const foo = () => {",
                "<s8>bar();",
                "<s8>bar2();",
                "<s4>};"
            ]
        } else {
            [
                "    const foo = () => {",
                "        bar();",
                "        bar2();",
                "    };"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s0>function someFunction(): JSX.Element {",
                "<s4>const foo = () => {",
                "<s8>bar();",
                "<s4>};",
                "<s4>return <div />;",
                "<s0>}"
            ]
        } else {
            [
                "function someFunction(): JSX.Element {",
                "    const foo = () => {",
                "        bar();",
                "    };",
                "    return <div />;",
                "}"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>const foo = () => {",
                "<s8>bar();",
                "<s4>};"
            ]
        } else {
            [
                "    const foo = () => {",
                "        bar();",
                "    };"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s4>const foo = () => {",
                "<s8>bar();",
                "<s4>};",
                "<s4>",
                "<s4>const baz = () => {",
                "<s8>foo2();",
                "<s4>};",
                "<s0>}"
            ]
        } else {
            [
                "    const foo = () => {",
                "        bar();",
                "    };",
                "",
                "    const baz = () => {",
                "        foo2();",
                "    };",
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
                "<s4>};",
                "<s0>};"
            ]
        } else {
            [
                "    };",
                "};"
            ]
        }
    }

    public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
        if includeIndentation {
            [
                "<s8>const foo = () => {",
                "<s8>};",
                "<s4>};",
                "<s0>};"
            ]
        } else {
            [
                "        const foo = () => {",
                "        };",
                "    };",
                "};"
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
            "import React, { useState } from 'react';",
            "",
            "interface User {",
            "  id: string;",
            "  name: string;",
            "}",
            "",
            "interface UserServiceProps {",
            "  onUserSaved?: (user: User) => void;",
            "}",
            "",
            "export const UserService: React.FC<UserServiceProps> = ({ onUserSaved }) => {",
            "  const [users, setUsers] = useState<User[]>([]);",
            "  ",
            "  const processUser = (userData: Partial<User>): User => {",
            "    // Process user data",
            "    const user: User = {",
            "      id: userData.id!,",
            "      name: userData.name!",
            "    };",
            "    return user;",
            "  };",
            "  ",
            "  const saveUser = (user: User): void => {",
            "    // Save user to database",
            "    setUsers([...users, user]);",
            "  };",
            "  ",
            "  return (",
            "    <div>",
            "      {/* User service UI */}",
            "    </div>",
            "  );",
            "};"
        ]
    }

    public func fileEditorRewriteExampleChange1() -> [String] {
        [
            "  const processUser = (userData: Partial<User>): User => {",
            "    // Add validation",
            "    if (!userData || !userData.id || !userData.name) {",
            "      throw new Error('Invalid user data');",
            "    }",
            "    ",
            "    // ... existing code ...",
            "  };"
        ]
    }

    public func fileEditorRewriteExampleChange2() -> [String] {
        [
            "  const saveUser = (user: User): void => {",
            "    try {",
            "      // ... existing code ...",
            "      console.log('User saved successfully');",
            "      onUserSaved?.(user);",
            "    } catch (error) {",
            "      console.error('Failed to save user:', error);",
            "      throw error;",
            "    }",
            "  };"
        ]
    }

    public func fileEditorRewriteExampleCompleteFile() -> [String] {
        [
            "import React, { useState } from 'react';",
            "",
            "interface User {",
            "  id: string;",
            "  name: string;",
            "}",
            "",
            "interface UserServiceProps {",
            "  onUserSaved?: (user: User) => void;",
            "}",
            "",
            "export const UserService: React.FC<UserServiceProps> = ({ onUserSaved }) => {",
            "  const [users, setUsers] = useState<User[]>([]);",
            "  ",
            "  const processUser = (userData: Partial<User>): User => {",
            "    // Add validation",
            "    if (!userData || !userData.id || !userData.name) {",
            "      throw new Error('Invalid user data');",
            "    }",
            "    ",
            "    // Process user data",
            "    const user: User = {",
            "      id: userData.id!,",
            "      name: userData.name!",
            "    };",
            "    return user;",
            "  };",
            "  ",
            "  const saveUser = (user: User): void => {",
            "    try {",
            "      // Save user to database",
            "      setUsers([...users, user]);",
            "      console.log('User saved successfully');",
            "      onUserSaved?.(user);",
            "    } catch (error) {",
            "      console.error('Failed to save user:', error);",
            "      throw error;",
            "    }",
            "  };",
            "  ",
            "  return (",
            "    <div>",
            "      {/* User service UI */}",
            "    </div>",
            "  );",
            "};"
        ]
    }
}
