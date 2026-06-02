enum WelcomeGuideToolDetector {
    static func cliExists(source: String) -> Bool {
        ConfigInstaller.cliExists(source: source)
    }
}
