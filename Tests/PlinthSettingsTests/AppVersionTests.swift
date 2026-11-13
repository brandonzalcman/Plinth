import Testing
@testable import PlinthSettings

@Suite struct AppVersionTests {
    @Test func versionAndBuild() {
        let v = AppVersion(infoDictionary: ["CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "3"])
        #expect(v.version == "0.1.2")
        #expect(v.build == "3")
        #expect(v.displayString == "Version 0.1.2 (3)")
    }

    @Test func versionWithoutBuild() {
        #expect(AppVersion(infoDictionary: ["CFBundleShortVersionString": "0.1.2"]).displayString == "Version 0.1.2")
    }

    @Test func unbundledRunIsADevelopmentBuild() {
        #expect(AppVersion(infoDictionary: nil).displayString == "Development build")
        #expect(AppVersion(infoDictionary: [:]).displayString == "Development build")
    }

    @Test func placeholdersAndBlanksCountAsMissing() {
        let v = AppVersion(infoDictionary: ["CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "  "])
        #expect(v.version == nil)
        #expect(v.build == nil)
        #expect(v.displayString == "Development build")
    }
}
