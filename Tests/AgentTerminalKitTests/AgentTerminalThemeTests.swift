import XCTest
@testable import AgentTerminalKit

@MainActor
final class AgentTerminalThemeTests: XCTestCase {
    func testPresetLookupAcceptsStableId() {
        let theme = AgentTerminalTheme.preset(for: "solarized-light")
        XCTAssertEqual(theme?.title, "Solarized Light")
    }

    func testPresetLookupAcceptsLegacyDisplayName() {
        let theme = AgentTerminalTheme.preset(for: "Solarized Light")
        XCTAssertEqual(theme?.id, "solarized-light")
    }

    func testPresetExpandsToConcreteGhosttyColors() {
        let theme = AgentTerminalTheme.preset(for: "dracula")
        XCTAssertEqual(theme?.lines.first, "background = #282A36")
        XCTAssertEqual(theme?.lines.filter { $0.hasPrefix("palette = ") }.count, 16)
    }

    func testSettingsThemeSelectionPreservesUnknownRawTheme() {
        let state = AgentTerminalSettingsModel.themeSelection(for: "/Users/me/.config/ghostty/themes/custom")
        XCTAssertEqual(state.selection, AgentTerminalSettingsModel.customThemeSelection)
        XCTAssertEqual(
            AgentTerminalSettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: state.customRawValue
            ),
            "/Users/me/.config/ghostty/themes/custom"
        )
    }

    func testSettingsDefaultThemeSelectionClearsRawThemeWhenChosen() {
        let defaultSelection = AgentTerminalSettingsModel.themeSelection(for: nil).selection
        XCTAssertNil(
            AgentTerminalSettingsModel.persistedThemeValue(
                selection: defaultSelection,
                customRawValue: "/Users/me/.config/ghostty/themes/custom"
            )
        )
    }

    func testSettingsPresetThemeSelectionPersistsStableId() {
        let state = AgentTerminalSettingsModel.themeSelection(for: "Solarized Light")
        XCTAssertEqual(state.selection, "solarized-light")
        XCTAssertEqual(
            AgentTerminalSettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: nil
            ),
            "solarized-light"
        )
    }

    func testUserThemesLoadsGhosttyThemeDirectoryFiles() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let themeURL = dir.appendingPathComponent("My Custom Theme")
        try """
        # comments are ignored
        background = #101820
        foreground = "F2AA4C"
        palette = 0=#101820
        """.write(to: themeURL, atomically: true, encoding: .utf8)

        let themes = AgentTerminalTheme.userThemes(in: dir)
        XCTAssertEqual(themes.map(\.title), ["My Custom Theme"])
        XCTAssertEqual(themes.first?.storedValue, "My Custom Theme")
        XCTAssertEqual(themes.first?.backgroundHex, "#101820")
        XCTAssertEqual(themes.first?.foregroundHex, "F2AA4C")
    }

    func testSettingsThemeSelectionAcceptsUserThemeByFileName() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Issue 17")
        try "background = #000000\nforeground = #ffffff\n"
            .write(to: url, atomically: true, encoding: .utf8)

        let custom = AgentTerminalTheme.userThemes(in: dir)
        let state = AgentTerminalSettingsModel.themeSelection(for: "Issue 17", in: AgentTerminalTheme.presets + custom)
        XCTAssertEqual(state.selection, "ghostty-user:Issue 17")
        XCTAssertEqual(
            AgentTerminalSettingsModel.persistedThemeValue(
                selection: state.selection,
                customRawValue: nil,
                in: AgentTerminalTheme.presets + custom
            ),
            "Issue 17"
        )
    }

    func testGhosttyUserThemesDirectoryHonorsXDGConfigHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let xdg = AgentTerminalTheme.ghosttyUserThemesDirectory(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg"],
            homeDirectory: home
        )
        XCTAssertEqual(xdg.path, "/tmp/xdg/ghostty/themes")

        let fallback = AgentTerminalTheme.ghosttyUserThemesDirectory(
            environment: [:],
            homeDirectory: home
        )
        XCTAssertEqual(fallback.path, "/Users/example/.config/ghostty/themes")
    }

    func testThemeApplyThemeIncrementsVersionForDifferentTheme() {
        let before = Theme.version

        Theme.applyTheme(AgentTerminalTheme.preset(for: "macos-dark"))
        Theme.applyTheme(AgentTerminalTheme.preset(for: "macos-light"))

        XCTAssertGreaterThan(Theme.version, before)
    }

    func testThemeApplyThemeDoesNotIncrementVersionForSameTheme() {
        Theme.applyTheme(AgentTerminalTheme.preset(for: "dracula"))
        let before = Theme.version

        Theme.applyTheme(AgentTerminalTheme.preset(for: "dracula"))

        XCTAssertEqual(Theme.version, before)
    }

    func testCrossWorkspaceMessagingPersistsOnlyWhenEnabled() {
        XCTAssertEqual(AgentTerminalSettingsModel.persistedAllowCrossWorkspaceValue(true), true)
        XCTAssertNil(AgentTerminalSettingsModel.persistedAllowCrossWorkspaceValue(false))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentterminal-theme-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
