import Foundation

public enum Privacy {
    public static let maxFileBytes = 1_048_576
    public static let maxSnapshotBytes = 8_388_608
    /// Directories inside skills that hold caches or dependencies rather than authored content.
    public static let junkDirectories: Set<String> = [".git", "__pycache__", "node_modules", ".venv", "venv", ".mypy_cache", ".pytest_cache", ".ruff_cache"]
    private static let deniedSuffixes = [".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".ppk", ".kdbx", ".auto.tfvars", ".auto.tfvars.json"]

    public static func denied(_ path: String) -> Bool {
        path.lowercased().split(separator: "/").contains { component in
            let name = String(component)
            return name == "auth.json" || name == ".claude.json" || name == ".env" || name.hasPrefix(".env.") || name == ".envrc"
                || name.contains("credentials") || name.contains("keychain") || deniedSuffixes.contains { name.hasSuffix($0) }
                || name == "id_rsa" || name == "id_ed25519" || name == ".ssh"
        }
    }

    /// Operating-system and interpreter byproducts are never versioned as part of a skill.
    public static func isJunk(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "Thumbs.db" || name == "desktop.ini" || name.hasSuffix(".pyc") || name.hasSuffix(".pyo")
    }

    /// Text is valid UTF-8 without NUL bytes; everything else is binary.
    public static func isText(_ data: Data) -> Bool { !data.contains(0) && String(data: data, encoding: .utf8) != nil }

    /// A key needs its body: a PEM header in prose (`never commit -----BEGIN RSA PRIVATE KEY-----`) is a mention.
    /// The body may follow real or JSON-escaped line breaks, indentation, and PEM headers such as `Proc-Type`.
    private static let privateKey = try! NSRegularExpression(pattern: #"-----BEGIN (?:[A-Z0-9 ]*PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----(?:\\[rn]|\s)+(?:(?:Proc-Type|DEK-Info|Version|Comment):[^\n]*?(?:\\[rn]|\n)(?:\\[rn]|\s)*)*[A-Za-z0-9+/=]{40,}"#)
    private static let tokenPrefixes = try! NSRegularExpression(pattern: #"\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{15,}|(?:AKIA|ASIA)[A-Z0-9]{16}|xox[abposr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]{20,}|hf_[A-Za-z0-9]{30,}|npm_[A-Za-z0-9]{36}|(?:sk|rk)_live_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"#)
    private static let assignment = try! NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9_.-])["']?([A-Za-z0-9_.-]*(?:api[_-]?key|apikey|access[_-]?key|secret|token|passw(?:or)?d|private[_-]?key)[A-Za-z0-9_.-]*)["']?\s*[:=]\s*(["']?)([^\s"'`,;}{]{8,})"#)
    private static let urlCredentials = try! NSRegularExpression(pattern: #"(?i)\b(?:https?|postgres(?:ql)?|mongodb(?:\+srv)?|rediss?|amqps?|mysql|ftp)://[^\s/:@]+:([^\s/@]+)@[^\s]+"#)
    private static let opaque = try! NSRegularExpression(pattern: #"[A-Za-z0-9_+/=-]{32,}"#)
    /// `sha256:`, `SHA-256 is`, `checksum =`, `digest of`: the next token is a content hash.
    private static let digestContext = try! NSRegularExpression(pattern: #"(?i)(?:sha[-_ ]?(?:1|224|256|384|512)?|checksum|digest|integrity|hash)(?:\s+(?:is|was|of|sum|value))?\W{0,4}$"#)
    private static let attributeAccess = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$"#)
    private static let uuid = try! NSRegularExpression(pattern: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#)
    /// Keys that name, locate, or describe a secret rather than hold one, such as `secretName` or `token_url`.
    private static let referenceKeySuffixes = ["name", "names", "ref", "refs", "file", "path", "url", "uri", "endpoint", "command", "cmd", "helper", "env", "var", "type", "id", "ids", "length", "len", "ttl", "count", "limit", "expiry", "expires", "lifetime", "header", "field", "param", "prefix", "policy", "source", "store", "provider", "mode", "format", "scope", "scopes", "property", "properties", "attribute"]

    /// Words that mark a value as a stand-in: `your_token`, `YOUR_API_KEY`, `my-secret-here`.
    private static let placeholderMarkers: Set<String> = ["your", "my", "our", "example", "sample", "placeholder", "dummy", "fake", "changeme", "replace", "insert", "enter", "paste", "redacted", "todo", "tbd", "here", "foo", "bar", "baz"]
    /// Words that only say what belongs there: `secret_value`, `api-key`, `password`.
    private static let placeholderWords: Set<String> = ["secret", "secrets", "token", "tokens", "password", "passwords", "passwd", "pass", "key", "keys", "api", "access", "value", "string", "id", "client", "private", "auth", "credential", "credentials", "the", "a", "an", "put", "set", "change", "me", "goes"]
    /// Fragments real credentials never contain, such as AWS's documented `AKIAIOSFODNN7EXAMPLE` or `ghp_xxxx...`.
    private static let dummyFragments = ["xxxx", "example", "your", "placeholder", "redacted", "dummy", "changeme"]

    /// A credential-like span and why it was flagged. The reason names the rule or key, never the value.
    struct Match { var range: Range<String.Index>; var reason: String }

    /// Ranges of credential-like text. Literal values are treated as secrets; references, placeholders,
    /// digests, paths, slugs, and identifiers are not. Heuristic: it can miss secrets and flag harmless text.
    static func sensitiveRanges(in text: String) -> [Range<String.Index>] { sensitiveMatches(in: text).map(\.range) }

    static func sensitiveMatches(in text: String) -> [Match] {
        let whole = NSRange(text.startIndex..., in: text)
        var matches: [Match] = []
        for match in privateKey.matches(in: text, range: whole) {
            if let range = Range(match.range, in: text) { matches.append(Match(range: range, reason: "a private key")) }
        }
        for match in tokenPrefixes.matches(in: text, range: whole) {
            if let range = Range(match.range, in: text), !isDummy(text[range]) { matches.append(Match(range: range, reason: "an API token")) }
        }
        for match in assignment.matches(in: text, range: whole) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 3), in: text) else { continue }
            if !isReferenceKey(text[key]), !namesStoredSecret(key: text[key], value: text[value]), isLiteralSecret(text[value], quoted: match.range(at: 2).length > 0) {
                matches.append(Match(range: value, reason: "a credential assigned to \(text[key])"))
            }
        }
        for match in urlCredentials.matches(in: text, range: whole) {
            if let password = Range(match.range(at: 1), in: text), !isReference(text[password]), !isPlaceholder(text[password]) {
                matches.append(Match(range: password, reason: "a password in a URL"))
            }
        }
        for match in opaque.matches(in: text, range: whole) {
            guard let token = Range(match.range, in: text) else { continue }
            let start = text.index(token.lowerBound, offsetBy: -20, limitedBy: text.startIndex) ?? text.startIndex
            if !isDummy(text[token]), isOpaqueSecret(text[token], after: String(text[start..<token.lowerBound])) {
                matches.append(Match(range: token, reason: "a random-looking token"))
            }
        }
        // One secret found by two rules counts once, under the first rule that found it.
        var merged: [Match] = []
        let ordered = matches.enumerated().sorted { ($0.element.range.lowerBound, $0.offset) < ($1.element.range.lowerBound, $1.offset) }.map(\.element)
        for match in ordered {
            if let last = merged.last, match.range.lowerBound <= last.range.upperBound {
                merged[merged.count - 1].range = last.range.lowerBound..<max(last.range.upperBound, match.range.upperBound)
            } else { merged.append(match) }
        }
        return merged
    }

    /// Plural keys (`secrets`, `imagePullSecrets`) list names; `existingSecret` points at a stored one.
    private static func isReferenceKey(_ key: Substring) -> Bool {
        let lowered = key.lowercased()
        return referenceKeySuffixes.contains { lowered.hasSuffix($0) } || ["secrets", "tokens", "passwords", "keys"].contains { lowered.hasSuffix($0) }
            || lowered.hasPrefix("existing")
    }

    /// `tlsSecret: wildcard-tls`, `githubConfigSecret: arc-github-app`: Kubernetes-style names of stored secrets.
    private static func namesStoredSecret(key: Substring, value: Substring) -> Bool {
        key.lowercased().hasSuffix("secret") && value.range(of: #"^[a-z]+(?:-[a-z]+)+$"#, options: .regularExpression) != nil
    }

    /// Environment references, templates, placeholders, and code expressions.
    private static func isReference(_ value: Substring) -> Bool {
        guard let first = value.first, !"$%<{([*#".contains(first), Set(value).count > 2 else { return true }
        if value.contains("${") || value.contains("$(") || value.contains("(") || value.contains("[") || value.contains("{") { return true }
        let text = String(value)
        return attributeAccess.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Unquoted plain words read as prose (`password: required`); quoted values and anything with digits, case, or symbols do not.
    private static func isLiteralSecret(_ value: Substring, quoted: Bool) -> Bool {
        guard !isReference(value), !isPlaceholder(value) else { return false }
        let plainWord = value.allSatisfy { $0.isLetter && $0.isLowercase }
        return !plainWord || (quoted && value.count >= 16)
    }

    /// Stand-ins written in place of a credential: `your_secret`, `YOUR_API_KEY`, `password`, `xxxx_xxxx`.
    /// Only letters and separators qualify, so `MyPassword123` still reads as a real value.
    static func isPlaceholder(_ value: Substring) -> Bool {
        if isDummy(value) { return true }
        guard value.allSatisfy({ $0.isLetter || "_-.".contains($0) }) else { return false }
        let words = placeholderTokens(value)
        guard !words.isEmpty else { return false }
        return words.contains { placeholderMarkers.contains($0) || ($0.count >= 3 && $0.allSatisfy { $0 == "x" }) }
            || words.allSatisfy { placeholderWords.contains($0) }
    }

    private static func isDummy(_ token: Substring) -> Bool {
        let lowered = token.lowercased()
        return dummyFragments.contains { lowered.contains($0) }
    }

    /// Lowercased words split at separators and camelCase boundaries: `yourApiKey` reads as your, api, key.
    private static func placeholderTokens(_ value: Substring) -> [String] {
        var words: [String] = [], current = ""
        var previous: Character?
        for character in value {
            if !character.isLetter {
                if !current.isEmpty { words.append(current) }
                current = ""; previous = nil; continue
            }
            if character.isUppercase, previous?.isLowercase == true { words.append(current); current = "" }
            current.append(character); previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    private static func isOpaqueSecret(_ token: Substring, after context: String) -> Bool {
        if digestContext.firstMatch(in: context, range: NSRange(context.startIndex..., in: context)) != nil { return false }
        if token.range(of: #"^sha(?:1|256|384|512)-"#, options: .regularExpression) != nil { return false }
        // Absolute and multi-segment paths are judged per segment; a hex folder name is an identifier.
        let isPath = token.hasPrefix("/") || token.filter({ $0 == "/" }).count >= 2
        return (isPath ? token.split(separator: "/") : [token]).contains { raw in
            // UUIDs identify things; on their own they are not credentials.
            let text = String(raw)
            let segment = Substring(uuid.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""))
            guard segment.count >= 32 else { return false }
            // Slugs and file names separate short parts; random tokens rarely contain separators.
            guard Double(segment.filter({ "-_/".contains($0) }).count) / Double(segment.count) < 0.08 else { return false }
            let entropy = entropy(segment)
            // Forty hex digits is a git object name, not a credential.
            if segment.allSatisfy(\.isHexDigit) { return !isPath && segment.count != 40 && entropy > 3.5 }
            let mixed = segment.contains(where: \.isUppercase) && segment.contains(where: \.isLowercase) && segment.contains(where: \.isNumber)
            return mixed && entropy > 4.2 && wordShare(segment) < 0.5
        }
    }

    private static func entropy(_ token: Substring) -> Double {
        Dictionary(grouping: token, by: { $0 }).values.reduce(0.0) { sum, group in
            let p = Double(group.count) / Double(token.count); return sum - p * log2(p)
        }
    }

    /// Share of characters in word-shaped runs: four or more lowercase letters, optionally after one capital.
    /// Slugs, paths, and identifiers score high; random tokens score low.
    static func wordShare(_ token: Substring) -> Double {
        var covered = 0, run = 0
        for character in token {
            if character.isLowercase { run += 1; continue }
            if run >= 4 { covered += run }
            run = character.isUppercase ? 1 : 0
        }
        if run >= 4 { covered += run }
        return Double(covered) / Double(token.count)
    }

    /// Where the first credential-like text is and why, without the value.
    public static func firstSensitive(in text: String) -> (line: Int, reason: String)? {
        guard let first = sensitiveMatches(in: text).first else { return nil }
        return (text[..<first.range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }, first.reason)
    }

    public static func redacted(_ text: String) -> (text: String, count: Int) {
        let ranges = sensitiveRanges(in: text)
        guard !ranges.isEmpty else { return (text, 0) }
        var output = "", cursor = text.startIndex
        for range in ranges {
            output += text[cursor..<range.lowerBound]; output += "[REDACTED]"; cursor = range.upperBound
        }
        output += text[cursor...]
        return (output, ranges.count)
    }

    public static func validate(_ data: Data, path: String) throws {
        guard !denied(path) else { throw HarnessError.blocked(path) }
        try validateText(data, label: path)
    }

    /// Content checks only, for text whose destination path is validated separately.
    public static func validateText(_ data: Data, label: String) throws {
        guard data.count <= maxFileBytes, isText(data) else {
            throw HarnessError.invalid("Only UTF-8 text up to 1 MiB is collected: \(label)")
        }
        if let first = firstSensitive(in: String(decoding: data, as: UTF8.self)) {
            throw HarnessError.sensitive(path: label, line: first.line, reason: first.reason)
        }
    }

    /// Skill bundles may carry binary assets: those skip text sniffing but never carry embedded private keys.
    public static func validateBundleEntry(_ data: Data, path: String) throws {
        guard !denied(path) else { throw HarnessError.blocked(path) }
        guard data.count <= maxFileBytes else { throw HarnessError.invalid("File exceeds the 1 MiB collection limit: \(path)") }
        if isText(data) { return try validateText(data, label: path) }
        guard data.range(of: Data("PRIVATE KEY-----".utf8)) == nil else { throw HarnessError.blocked(path) }
    }
}
