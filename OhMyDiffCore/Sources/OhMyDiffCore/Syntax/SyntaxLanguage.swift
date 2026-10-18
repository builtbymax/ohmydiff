import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// A language with a bundled tree-sitter grammar and highlight queries.
public enum SyntaxLanguage: String, Sendable, Hashable, CaseIterable {
    case swift
    case typescript
    case tsx
    case javascript
    case python
    case go
    case rust
    case json
    case yaml
    case markdown
    case css
    case html
    case bash

    /// The language of a file, from its extension or well-known name; `nil` when none is bundled.
    public init?(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "swift": self = .swift
        case "ts", "mts", "cts": self = .typescript
        case "tsx": self = .tsx
        case "js", "jsx", "mjs", "cjs": self = .javascript
        case "py", "pyi": self = .python
        case "go": self = .go
        case "rs": self = .rust
        case "json", "jsonc", "json5": self = .json
        case "yml", "yaml": self = .yaml
        case "md", "markdown": self = .markdown
        case "css": self = .css
        case "html", "htm": self = .html
        case "sh", "bash", "zsh": self = .bash
        default:
            switch name {
            case ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile": self = .bash
            default: return nil
            }
        }
    }

    var tsLanguage: OpaquePointer {
        switch self {
        case .swift: tree_sitter_swift()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .javascript: tree_sitter_javascript()
        case .python: tree_sitter_python()
        case .go: tree_sitter_go()
        case .rust: tree_sitter_rust()
        case .json: tree_sitter_json()
        case .yaml: tree_sitter_yaml()
        case .markdown: tree_sitter_markdown()
        case .css: tree_sitter_css()
        case .html: tree_sitter_html()
        case .bash: tree_sitter_bash()
        }
    }

    /// Highlight query files as (resource bundle, file name), concatenated in order. TypeScript builds
    /// on the JavaScript queries, the same way the grammar's own `tree-sitter.json` does.
    var querySources: [(bundle: String, file: String)] {
        let javaScript = "TreeSitterJavaScript_TreeSitterJavaScript"
        switch self {
        case .swift: return [("TreeSitterSwift_TreeSitterSwift", "highlights.scm")]
        case .typescript:
            return [(javaScript, "highlights.scm"), ("TreeSitterTypeScript_TreeSitterTypeScript", "highlights.scm")]
        case .tsx:
            return [(javaScript, "highlights.scm"), (javaScript, "highlights-jsx.scm"), ("TreeSitterTypeScript_TreeSitterTSX", "highlights.scm")]
        case .javascript: return [(javaScript, "highlights.scm"), (javaScript, "highlights-jsx.scm")]
        case .python: return [("TreeSitterPython_TreeSitterPython", "highlights.scm")]
        case .go: return [("TreeSitterGo_TreeSitterGo", "highlights.scm")]
        case .rust: return [("TreeSitterRust_TreeSitterRust", "highlights.scm")]
        case .json: return [("TreeSitterJSON_TreeSitterJSON", "highlights.scm")]
        case .yaml: return [("TreeSitterYAML_TreeSitterYAML", "highlights.scm")]
        case .markdown: return [("TreeSitterMarkdown_TreeSitterMarkdown", "highlights.scm")]
        case .css: return [("TreeSitterCSS_TreeSitterCSS", "highlights.scm")]
        case .html: return [("TreeSitterHTML_TreeSitterHTML", "highlights.scm")]
        case .bash: return [("TreeSitterBash_TreeSitterBash", "highlights.scm")]
        }
    }
}

/// What a highlighted piece of source code is, reduced from tree-sitter capture names to the few
/// kinds that get their own color.
public enum SyntaxToken: UInt8, Sendable, Hashable, CaseIterable {
    case keyword = 1
    case string
    case comment
    case number
    case constant
    case type
    case function
    case property
    case attribute
    case tag
    case escape
    case heading
    case link

    /// Maps a capture name such as `function.method` or `string.special.key`; `nil` leaves the text plain.
    init?(captureName name: String) {
        let parts = name.split(separator: ".")
        guard let head = parts.first else { return nil }
        let second = parts.dropFirst().first
        switch head {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass":
            self = .keyword
        case "string":
            switch second {
            case "escape": self = .escape
            case "special" where parts.dropFirst(2).first == "key": self = .property
            default: self = .string
            }
        case "character": self = .string
        case "escape": self = .escape
        case "comment": self = .comment
        case "number", "float", "boolean": self = .number
        case "constant":
            self = second == "builtin" ? .keyword : .constant
        case "type", "constructor", "namespace", "module": self = .type
        case "function", "method": self = .function
        case "property", "field": self = .property
        case "variable":
            switch second {
            case "builtin": self = .keyword
            case "member": self = .property
            default: return nil
            }
        case "attribute", "label", "decorator": self = .attribute
        case "tag": self = .tag
        case "text", "markup":
            switch second {
            case "title", "heading": self = .heading
            case "uri", "reference", "link": self = .link
            case "literal", "raw": self = .string
            default: return nil
            }
        case "embedded", "punctuation", "operator", "none", "spell":
            return nil
        default:
            // At-rules in CSS (`@media`, `@import`, …) are captured under their own names.
            switch head {
            case "media", "import", "charset", "keyframes", "supports": self = .keyword
            default: return nil
            }
        }
    }
}
