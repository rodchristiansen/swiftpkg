import Foundation
import Testing
@testable import SwiftPkgCore

struct EnvironmentSubstitutionTests {
    @Test("replaces ${VAR} and reports unresolved")
    func replacesCurlyAndReportsUnresolved() {
        let result = PlaceholderReplacer.replace(
            in: "url=${API_URL}\nkey=${MISSING}\n",
            with: ["API_URL": "https://example.com"]
        )
        #expect(result.content == "url=https://example.com\nkey=${MISSING}\n")
        #expect(result.unresolved == ["MISSING"])
    }

    @Test("supports all placeholder syntaxes")
    func supportsAllSyntaxes() {
        let vars = ["A": "1", "B": "2", "C": "3", "D": "4"]
        let result = PlaceholderReplacer.replace(in: "${A} {{B}} __C__ D_PLACEHOLDER", with: vars)
        #expect(result.content == "1 2 3 4")
        #expect(result.unresolved.isEmpty)
    }

    @Test("a substituted value is not re-expanded")
    func singlePassNoReexpansion() {
        let result = PlaceholderReplacer.replace(in: "${A}", with: ["A": "${B}", "B": "leaked"])
        #expect(result.content == "${B}")
    }

    @Test("empty value counts as resolved, not unresolved")
    func emptyValueIsResolved() {
        let result = PlaceholderReplacer.replace(in: "x=${EMPTY}", with: ["EMPTY": ""])
        #expect(result.content == "x=")
        #expect(result.unresolved.isEmpty)
    }

    @Test("merge picks up MUNKIPKG_ vars and .env wins on conflict")
    func mergePrecedence() {
        let key = "MUNKIPKG_TEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(key, "from-process", 1)
        defer { unsetenv(key) }

        let merged = EnvLoader.merge(envFileVars: [key: "from-dotenv"], includeSysEnv: true)
        #expect(merged.vars[key] == "from-dotenv")
        #expect(merged.systemEnvKeys.contains(key))

        let processOnly = EnvLoader.merge(envFileVars: [:], includeSysEnv: true)
        #expect(processOnly.vars[key] == "from-process")

        let excluded = EnvLoader.merge(envFileVars: [:], includeSysEnv: false)
        #expect(excluded.vars[key] == nil)
    }

    @Test("non-prefixed process vars are ignored")
    func ignoresUnprefixedProcessVars() {
        let key = "SWIFTPKG_UNPREFIXED_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        setenv(key, "nope", 1)
        defer { unsetenv(key) }
        let merged = EnvLoader.merge(envFileVars: [:], includeSysEnv: true)
        #expect(merged.vars[key] == nil)
    }

    @Test("load parses a .env with quotes and comments")
    func loadsDotEnv() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftpkg-envtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let envPath = dir.appendingPathComponent(".env").path
        try "# a comment\nA=1\nB=\"quoted value\"\nC='single'\n".write(toFile: envPath, atomically: true, encoding: .utf8)

        let vars = try EnvLoader.load(from: envPath, warnOnPermissiveMode: false)
        #expect(vars["A"] == "1")
        #expect(vars["B"] == "quoted value")
        #expect(vars["C"] == "single")
        #expect(vars.count == 3)
    }

    @Test("secret-like key detection")
    func detectsSecretLikeKeys() {
        #expect(EnvLoader.containsSecretLikeKey(["SERVER_URL", "API_KEY"]))
        #expect(EnvLoader.containsSecretLikeKey(["ORG_PASSPHRASE"]))
        #expect(!EnvLoader.containsSecretLikeKey(["SERVER_URL", "ORG_NAME"]))
    }
}
