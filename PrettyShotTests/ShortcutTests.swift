import Carbon.HIToolbox
import XCTest
@testable import PrettyShot

final class ShortcutTests: XCTestCase {
    func testDefaultsMatchDesign() {
        XCTAssertEqual(HotkeyAction.captureRegion.defaultShortcut.displayString, "⌥⌘1")
        XCTAssertEqual(HotkeyAction.captureWindow.defaultShortcut.displayString, "⌥⌘2")
        XCTAssertEqual(HotkeyAction.captureFullscreen.defaultShortcut.displayString, "⌥⌘3")
        XCTAssertEqual(HotkeyAction.captureScrolling.defaultShortcut.displayString, "⌥⌘4")
        XCTAssertEqual(HotkeyAction.openHistory.defaultShortcut.displayString, "⌥⌘H")
        XCTAssertEqual(HotkeyAction.pinLatest.defaultShortcut.displayString, "⌥⌘P")
    }

    func testDefaultsNeverClaimSystemScreenshotKeys() {
        for action in HotkeyAction.allCases {
            XCTAssertFalse(action.defaultShortcut.isSystemScreenshotShortcut, "\(action)")
        }
    }

    func testSystemScreenshotShortcutsAreRejected() {
        let cmdShift = Shortcut.command | Shortcut.shift
        for key in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6] {
            let shortcut = Shortcut(keyCode: key, modifiers: cmdShift)
            XCTAssertTrue(shortcut.isSystemScreenshotShortcut)
            XCTAssertEqual(ShortcutValidator.validate(shortcut, for: .captureRegion, existing: [:]), .reservedBySystem)
            // Control variants (copy-to-clipboard) are also the system's.
            XCTAssertTrue(Shortcut(keyCode: key, modifiers: cmdShift | Shortcut.control).isSystemScreenshotShortcut)
        }
        // ⌥⌘⇧4 is not a system screenshot key.
        XCTAssertFalse(Shortcut(keyCode: kVK_ANSI_4, modifiers: cmdShift | Shortcut.option).isSystemScreenshotShortcut)
    }

    func testValidatorRequiresModifierUnlessFunctionKey() {
        XCTAssertEqual(ShortcutValidator.validate(Shortcut(keyCode: kVK_ANSI_A, modifiers: 0), for: .openHistory, existing: [:]),
                       .needsModifier)
        XCTAssertEqual(ShortcutValidator.validate(Shortcut(keyCode: kVK_ANSI_A, modifiers: Shortcut.shift), for: .openHistory, existing: [:]),
                       .needsModifier)
        XCTAssertNil(ShortcutValidator.validate(Shortcut(keyCode: kVK_F6, modifiers: 0), for: .openHistory, existing: [:]))
    }

    func testValidatorDetectsDuplicates() {
        let existing = [HotkeyAction.captureRegion: HotkeyAction.captureRegion.defaultShortcut]
        XCTAssertEqual(ShortcutValidator.validate(HotkeyAction.captureRegion.defaultShortcut, for: .pinLatest, existing: existing),
                       .duplicate(.captureRegion))
        // Re-assigning the same combo to the same action is fine.
        XCTAssertNil(ShortcutValidator.validate(HotkeyAction.captureRegion.defaultShortcut, for: .captureRegion, existing: existing))
    }

    @MainActor
    func testManagerPersistsAndRejects() {
        let suite = "PrettyShotTests.hotkeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = HotkeyManager(defaults: defaults)
        manager.suspend() // don't touch real global registrations from tests

        let reserved = Shortcut(keyCode: kVK_ANSI_4, modifiers: Shortcut.command | Shortcut.shift)
        XCTAssertEqual(manager.setShortcut(reserved, for: .captureRegion), .reservedBySystem)
        XCTAssertEqual(manager.shortcut(for: .captureRegion), HotkeyAction.captureRegion.defaultShortcut)

        let custom = Shortcut(keyCode: kVK_ANSI_R, modifiers: Shortcut.control | Shortcut.option)
        XCTAssertNil(manager.setShortcut(custom, for: .captureRegion))
        XCTAssertNil(manager.setShortcut(nil, for: .pinLatest))

        let reloaded = HotkeyManager(defaults: defaults)
        XCTAssertEqual(reloaded.shortcut(for: .captureRegion), custom)
        XCTAssertNil(reloaded.shortcut(for: .pinLatest))
        XCTAssertEqual(reloaded.displayString(for: .captureRegion), "⌃⌥R")

        reloaded.suspend()
        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.shortcut(for: .pinLatest), HotkeyAction.pinLatest.defaultShortcut)
    }
}
