/// Frontend-neutral choices that affect one package build.
public struct PackageBuildOptions: Sendable {
    public let requestedFormat: BuildInfoFormat?
    public let exportsBOM: Bool
    public let isQuiet: Bool
    public let skipsSigning: Bool
    public let skipsNotarization: Bool
    public let skipsStapling: Bool
    /// Path to a `.env` file of build-time variables. Defaults to `<project>/.env`.
    public let environmentFilePath: String?
    /// Merge `MUNKIPKG_*` variables from the process environment into scripts.
    public let includesSystemEnvironment: Bool
    /// Fail the build if any script placeholder has no matching variable.
    public let strictEnvironment: Bool

    public init(
        requestedFormat: BuildInfoFormat? = nil,
        exportsBOM: Bool = false,
        isQuiet: Bool = false,
        skipsSigning: Bool = false,
        skipsNotarization: Bool = false,
        skipsStapling: Bool = false,
        environmentFilePath: String? = nil,
        includesSystemEnvironment: Bool = true,
        strictEnvironment: Bool = false
    ) {
        self.requestedFormat = requestedFormat
        self.exportsBOM = exportsBOM
        self.isQuiet = isQuiet
        self.skipsSigning = skipsSigning
        self.skipsNotarization = skipsNotarization
        self.skipsStapling = skipsStapling
        self.environmentFilePath = environmentFilePath
        self.includesSystemEnvironment = includesSystemEnvironment
        self.strictEnvironment = strictEnvironment
    }
}
