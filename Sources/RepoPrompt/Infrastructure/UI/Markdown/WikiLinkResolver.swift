//
//  WikiLinkResolver.swift
//  RepoPrompt
//
//  Parsing and root-scoped resolution for `[[wiki links]]`.
//

import Foundation

// MARK: - Reference

/// The parsed inside of a `[[…]]` span.
///
/// Wiki links carry up to three parts: `[[target#fragment|alias]]`. The target
/// is the only required one — a reference with an empty target is not a link,
/// so parsing fails rather than producing a reference nothing can resolve.
struct WikiLinkReference: Equatable {
    /// The document being referenced, with alias and fragment removed.
    let target: String
    /// A heading or block anchor inside the target, if one was given.
    let fragment: String?
    /// Display text to show instead of the target, if one was given.
    let alias: String?

    /// Parses the text between `[[` and `]]`.
    ///
    /// - Returns: `nil` when no usable target remains after trimming.
    init?(rawInner: String) {
        var remainder = Substring(rawInner)

        var alias: String?
        if let pipeIndex = remainder.firstIndex(of: "|") {
            let aliasText = remainder[remainder.index(after: pipeIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            alias = aliasText.isEmpty ? nil : aliasText
            remainder = remainder[remainder.startIndex ..< pipeIndex]
        }

        var fragment: String?
        if let hashIndex = remainder.firstIndex(of: "#") {
            let fragmentText = remainder[remainder.index(after: hashIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fragment = fragmentText.isEmpty ? nil : fragmentText
            remainder = remainder[remainder.startIndex ..< hashIndex]
        }

        let target = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        self.target = target
        self.fragment = fragment
        self.alias = alias
    }

    /// The text a reader should see for this link.
    var displayText: String {
        alias ?? target
    }
}

// MARK: - Resolution outcome

enum WikiLinkResolution: Equatable {
    /// A path relative to the document root, guaranteed to be one of the
    /// candidates the root offered.
    case resolved(relativePath: String, fragment: String?)
    case rejected(WikiLinkRejection)
}

/// Classification returned for Obsidian's `![[…]]` syntax.
enum WikiLinkEmbedKind: Equatable {
    case image
    case note
}

enum WikiLinkEmbedResolution: Equatable {
    case resolved(relativePath: String, fragment: String?, kind: WikiLinkEmbedKind)
    case rejected(WikiLinkRejection)
}

enum WikiLinkRejection: Equatable, Error {
    /// Nothing addressable was left after trimming, or the path collapsed away.
    case emptyTarget
    /// The target names an absolute or home-relative location.
    case absolutePath
    /// The target carries a URL scheme and belongs to a browser, not the root.
    case externalScheme
    /// The target walks above the document root with `..`.
    case escapesRoot
    /// The target is well-formed but the root contains no such document.
    case notFound
}

// MARK: - Resolver

/// Resolves wiki-link targets against one document root, and only that root.
///
/// The resolver is pure: it is handed the root's relative paths up front and
/// never touches the filesystem, so containment is a property of the data
/// rather than of a check that could be raced. A resolved result is always one
/// of the supplied candidates, which is what makes "cannot escape the root" a
/// structural guarantee — `../../etc/passwd` is rejected during normalisation,
/// and even if it were not, it could not name a candidate.
///
/// Matching runs in a fixed order so the same link always resolves the same
/// way: exact path, exact path with `.md` inferred, then the same two forms
/// again case- and Unicode-normalisation-insensitively (macOS volumes are
/// routinely case-insensitive, so a link typed `[[readme]]` should still find
/// `README.md`). When a case-insensitive lookup matches several candidates the
/// lexicographically smallest wins, so resolution never depends on the order
/// the root was enumerated in.
struct WikiLinkResolver {
    private let candidates: [String]
    private let foldedIndex: [String: [String]]

    /// - Parameter rootRelativePaths: POSIX-style paths relative to the
    ///   document root, such as `notes/design.md`.
    init(rootRelativePaths: [String]) {
        candidates = rootRelativePaths
        var index: [String: [String]] = [:]
        for path in rootRelativePaths {
            index[Self.foldedKey(path), default: []].append(path)
        }
        foldedIndex = index.mapValues { $0.sorted() }
    }

    func resolve(_ reference: WikiLinkReference) -> WikiLinkResolution {
        switch Self.normalize(target: reference.target) {
        case let .failure(rejection):
            .rejected(rejection)
        case let .success(normalized):
            match(normalized, fragment: reference.fragment)
        }
    }

    /// Convenience for callers holding raw `[[…]]` inner text.
    func resolve(rawTarget: String) -> WikiLinkResolution {
        guard let reference = WikiLinkReference(rawInner: rawTarget) else {
            return .rejected(.emptyTarget)
        }
        return resolve(reference)
    }

    /// Resolves an Obsidian embed, additionally inferring common image extensions.
    ///
    /// Ordinary wiki links keep their existing `.md`-only inference. The wider image search is
    /// deliberately embed-only so `[[diagram]]` cannot unexpectedly navigate to a binary asset.
    func resolveEmbed(_ reference: WikiLinkReference) -> WikiLinkEmbedResolution {
        switch Self.normalize(target: reference.target) {
        case let .failure(rejection):
            return .rejected(rejection)
        case let .success(normalized):
            let forms = Self.embedCandidateForms(for: normalized)
            guard let path = matchFirst(forms) else { return .rejected(.notFound) }
            return .resolved(
                relativePath: path,
                fragment: reference.fragment,
                kind: Self.isImagePath(path) ? .image : .note
            )
        }
    }

    func resolveEmbed(rawTarget: String) -> WikiLinkEmbedResolution {
        guard let reference = WikiLinkReference(rawInner: rawTarget) else {
            return .rejected(.emptyTarget)
        }
        return resolveEmbed(reference)
    }

    static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: - Matching

    private func match(_ normalized: String, fragment: String?) -> WikiLinkResolution {
        guard let path = matchFirst(Self.candidateForms(for: normalized)) else {
            return .rejected(.notFound)
        }
        return .resolved(relativePath: path, fragment: fragment)
    }

    private func matchFirst(_ forms: [String]) -> String? {
        for form in forms where candidates.contains(form) {
            return form
        }
        for form in forms {
            if let matches = foldedIndex[Self.foldedKey(form)], let best = matches.first {
                return best
            }
        }
        return nil
    }

    /// The literal path, then the same path with `.md` inferred.
    private static func candidateForms(for normalized: String) -> [String] {
        var forms = [normalized]
        let hasMarkdownExtension = normalized.lowercased().hasSuffix(".md")
        if !hasMarkdownExtension {
            forms.append(normalized + ".md")
        }
        return forms
    }

    private static func embedCandidateForms(for normalized: String) -> [String] {
        let fileExtension = (normalized as NSString).pathExtension
        guard fileExtension.isEmpty else { return [normalized] }

        return [normalized, normalized + ".md"] + imageExtensions.map { normalized + "." + $0 }
    }

    /// Ordered for deterministic inference when a vault contains several encodings of one image.
    private static let imageExtensions = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic"]

    private static func foldedKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: - Normalisation

    private static func normalize(target: String) -> Result<String, WikiLinkRejection> {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTarget) }
        guard !hasURLScheme(trimmed) else { return .failure(.externalScheme) }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            return .failure(.absolutePath)
        }

        var components: [String] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return .failure(.escapesRoot) }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }

        guard !components.isEmpty else { return .failure(.emptyTarget) }
        return .success(components.joined(separator: "/"))
    }

    /// Schemes that address something other than a file in this root.
    private static let opaqueSchemes: Set<String> = ["mailto", "data", "javascript", "tel", "sms"]

    /// True for `https://…`, `file://…`, `mailto:…` and friends.
    ///
    /// The check is deliberately conservative: a bare colon is legal in a file
    /// name, so `Meeting: Notes` must stay a file name rather than becoming a
    /// `meeting:` scheme. Only an authority-style `scheme://` or a known opaque
    /// scheme counts. Anything that slips through is still contained, because a
    /// resolved path can only ever be one of the root's own candidates.
    private static func hasURLScheme(_ value: String) -> Bool {
        guard let colonIndex = value.firstIndex(of: ":") else { return false }
        let scheme = value[value.startIndex ..< colonIndex].lowercased()
        guard let first = scheme.first, first.isLetter else { return false }
        guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return false }
        if value[value.index(after: colonIndex)...].hasPrefix("//") {
            return true
        }
        return opaqueSchemes.contains(scheme)
    }
}
