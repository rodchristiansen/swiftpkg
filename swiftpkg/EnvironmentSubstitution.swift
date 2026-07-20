import Foundation

//  Build-time variable substitution for pre/postinstall scripts.
//
//  Ported to stay in sync with the munki-pkg fork's env feature.
//
//  IMPORTANT: substituted values are embedded verbatim in scripts, which end up
//  as plain text inside the resulting .pkg. Anyone with the package file can read
//  them via `pkgutil --expand`. This is for build-time variables (server URLs,
//  org identifiers, version metadata) -- NOT for secrets. For runtime secrets,
//  fetch from Keychain or an MDM-delivered profile inside the script itself.

/// Result of merging `.env` values with the process environment.
public struct EnvMergeResult: Sendable {
    public let vars: [String: String]
    /// Names (only) of MUNKIPKG_* keys picked up from the calling process environment.
    public let systemEnvKeys: [String]
}

/// Loads and merges build-time variables from a `.env` file and the environment.
public enum EnvLoader {

    /// Maximum size for a `.env` file (1 MB). Larger files are rejected.
    public static let maxFileSize: Int = 1_048_576

    /// Prefix a process-environment variable must carry to be merged into the
    /// substitution set. Namespaced so arbitrary environment variables (tokens,
    /// credentials) cannot leak into scripts.
    public static let systemEnvPrefix = "MUNKIPKG_"

    /// Load variables from a `.env` file.
    /// - Returns: key/value pairs, or an empty dictionary if the file does not exist.
    /// - Throws: `MunkiPkgError` if the file exists but can't be read or is too large.
    public static func load(from path: String, warnOnPermissiveMode: Bool = true) throws -> [String: String] {
        var envVars: [String: String] = [:]
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: path) else { return envVars }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fileManager.attributesOfItem(atPath: path)
        } catch {
            throw MunkiPkgError.message("Failed to read attributes of environment file: \(path)")
        }

        if let size = attrs[.size] as? Int, size > maxFileSize {
            throw MunkiPkgError.message("Environment file exceeds maximum size of \(maxFileSize) bytes: \(path)")
        }

        if warnOnPermissiveMode, let perms = attrs[.posixPermissions] as? Int {
            let groupReadable = (perms & 0o040) != 0
            let worldReadable = (perms & 0o004) != 0
            if groupReadable || worldReadable {
                let octal = String(perms, radix: 8)
                let msg = "WARNING: environment file \(path) has permissive mode 0\(octal) (group- or world-readable). Recommend `chmod 600 \(path)`.\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }

        guard let data = fileManager.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            throw MunkiPkgError.message("Failed to read environment file: \(path)")
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let rawKey = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            guard isValidKey(rawKey) else {
                let msg = "WARNING: skipping environment entry with invalid key: '\(rawKey)'\n"
                FileHandle.standardError.write(Data(msg.utf8))
                continue
            }
            var value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            envVars[rawKey] = value
        }

        return envVars
    }

    /// Merge `.env` file values with prefixed process-environment variables.
    /// `.env` values take precedence over process-environment vars with the same key.
    public static func merge(envFileVars: [String: String], includeSysEnv: Bool = true) -> EnvMergeResult {
        var result: [String: String] = [:]
        var sysKeys: [String] = []

        if includeSysEnv {
            for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix(systemEnvPrefix) {
                result[key] = value
                sysKeys.append(key)
            }
        }

        for (key, value) in envFileVars {
            result[key] = value
        }

        return EnvMergeResult(vars: result, systemEnvKeys: sysKeys.sorted())
    }

    /// Names look secret-like when they contain KEY/TOKEN/SECRET/PASSWORD/CREDENTIAL.
    public static func containsSecretLikeKey<S: Sequence>(_ keys: S) -> Bool where S.Element == String {
        let markers = ["KEY", "TOKEN", "SECRET", "PASSWORD", "PASSPHRASE", "CREDENTIAL"]
        return keys.contains { key in
            let upper = key.uppercased()
            return markers.contains { upper.contains($0) }
        }
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

/// Replaces build-time variable placeholders in script content.
///
/// Substitution is a single scan over the source: each placeholder is replaced
/// exactly once, so a value containing placeholder syntax is NOT re-expanded
/// against another key's value.
public enum PlaceholderReplacer {

    public struct Result: Sendable {
        public let content: String
        /// Placeholder names that appeared but had no matching env var.
        public let unresolved: Set<String>
    }

    public struct DirectoryResult: Sendable {
        public let scriptsDir: String
        public let unresolvedByScript: [String: Set<String>]
    }

    static let scriptNames: Set<String> = ["preinstall", "postinstall", "preupgrade", "postupgrade", "preexpansion"]

    // Capture groups 1-4: ${VAR}, {{VAR}}, __VAR__, VAR_PLACEHOLDER.
    private static let combinedPattern: NSRegularExpression = {
        let pattern =
            #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"# +
            #"|\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}"# +
            #"|__([A-Za-z_][A-Za-z0-9_]*)__"# +
            #"|(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)_PLACEHOLDER(?![A-Za-z0-9_])"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    public static func replace(in content: String, with envVars: [String: String]) -> Result {
        let ns = content as NSString
        let matches = combinedPattern.matches(in: content, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return Result(content: content, unresolved: []) }

        let output = NSMutableString()
        var cursor = 0
        var unresolved: Set<String> = []

        for match in matches {
            let r = match.range
            if r.location > cursor {
                output.append(ns.substring(with: NSRange(location: cursor, length: r.location - cursor)))
            }

            var key: String?
            for i in 1...4 where match.range(at: i).location != NSNotFound {
                key = ns.substring(with: match.range(at: i))
                break
            }

            let placeholder = ns.substring(with: r)
            if let key, let value = envVars[key] {
                output.append(value)
            } else {
                output.append(placeholder)
                if let key { unresolved.insert(key) }
            }

            cursor = r.location + r.length
        }

        if cursor < ns.length {
            output.append(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }

        return Result(content: output as String, unresolved: unresolved)
    }

    private static func scriptsToHandle(in scriptsDir: String) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: scriptsDir) else { return [] }
        return contents.filter { scriptNames.contains($0) || $0.hasSuffix(".sh") || $0.hasSuffix(".py") }
    }

    /// Scan a scripts directory for placeholder references without substituting.
    /// Used by strict mode when no variables are available.
    public static func scanScriptsDirectory(at scriptsDir: String) -> [String: Set<String>] {
        let scriptsURL = URL(fileURLWithPath: scriptsDir)
        var unresolvedByScript: [String: Set<String>] = [:]
        for scriptName in scriptsToHandle(in: scriptsDir) {
            let path = scriptsURL.appendingPathComponent(scriptName).path
            guard let data = FileManager.default.contents(atPath: path),
                  let content = String(data: data, encoding: .utf8) else { continue }
            let result = replace(in: content, with: [:])
            if !result.unresolved.isEmpty { unresolvedByScript[scriptName] = result.unresolved }
        }
        return unresolvedByScript
    }

    /// Process scripts, replacing placeholders. Processed scripts are written under
    /// `tempDir/scripts` (mode 0700); returns nil if there is nothing to process.
    public static func processScriptsDirectory(
        at scriptsDir: String,
        with envVars: [String: String],
        tempDir: String
    ) throws -> DirectoryResult? {
        let fileManager = FileManager.default
        let scriptsURL = URL(fileURLWithPath: scriptsDir)
        let tempScriptsDir = (tempDir as NSString).appendingPathComponent("scripts")

        guard fileManager.fileExists(atPath: scriptsDir),
              let contents = try? fileManager.contentsOfDirectory(atPath: scriptsDir) else { return nil }

        let scriptsToProcess = scriptsToHandle(in: scriptsDir)
        if envVars.isEmpty || scriptsToProcess.isEmpty { return nil }

        try fileManager.createDirectory(
            atPath: tempScriptsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir)

        var unresolvedByScript: [String: Set<String>] = [:]

        for scriptName in scriptsToProcess {
            let sourcePath = scriptsURL.appendingPathComponent(scriptName).path
            let destPath = (tempScriptsDir as NSString).appendingPathComponent(scriptName)

            guard let data = fileManager.contents(atPath: sourcePath),
                  let content = String(data: data, encoding: .utf8) else {
                try fileManager.copyItem(atPath: sourcePath, toPath: destPath)
                continue
            }

            let result = replace(in: content, with: envVars)
            try result.content.write(toFile: destPath, atomically: true, encoding: .utf8)
            if !result.unresolved.isEmpty { unresolvedByScript[scriptName] = result.unresolved }

            // Strip group/other bits (scripts hold substituted values); force owner
            // execute since pkgbuild requires runnable scripts.
            let sourceAttrs = try fileManager.attributesOfItem(atPath: sourcePath)
            let sourcePerms = (sourceAttrs[.posixPermissions] as? Int) ?? 0o700
            let safePerms = (sourcePerms & 0o700) | 0o100
            try fileManager.setAttributes([.posixPermissions: safePerms], ofItemAtPath: destPath)
        }

        // Copy any non-script files through unchanged.
        for item in contents where !scriptsToProcess.contains(item) {
            let sourcePath = scriptsURL.appendingPathComponent(item).path
            let destPath = (tempScriptsDir as NSString).appendingPathComponent(item)
            try? fileManager.copyItem(atPath: sourcePath, toPath: destPath)
        }

        return DirectoryResult(scriptsDir: tempScriptsDir, unresolvedByScript: unresolvedByScript)
    }
}
