import Testing
@testable import JBenchCore

struct ScaffoldTests {
    @Test func appSectionsAreCompleteAndStable() {
        #expect(AppSection.allCases == [.newRun, .history, .presets, .settings])
        #expect(AppSection.newRun.title == "New Run")
        #expect(AppSection.settings.systemImage == "gearshape")
    }
}
