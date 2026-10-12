import Carbon.HIToolbox
import XCTest
@testable import PrettyShot

final class ShortcutValidatorExternalTests: XCTestCase {
    private let optionCommand = Shortcut.option | Shortcut.command

    func testBuiltinConflictWithExternalUsesDuplicateExternal() {
        let externalShortcut = Shortcut(keyCode: kVK_ANSI_5, modifiers: optionCommand)
        let error = ShortcutValidator.validate(
            externalShortcut,
            for: .builtin(.captureRegion),
            builtin: defaults(),
            external: ["ext.alpha": externalShortcut],
            titleOf: { _ in "功能甲" }
        )
        XCTAssertEqual(error, .duplicateExternal(title: "功能甲"))
        XCTAssertEqual(error?.errorDescription, "已被「功能甲」使用")
    }

    func testExternalConflictWithBuiltinUsesDuplicateAction() {
        let error = ShortcutValidator.validate(
            HotkeyAction.captureRegion.defaultShortcut,
            for: .external("ext.alpha"),
            builtin: defaults(),
            external: [:],
            titleOf: { _ in "功能甲" }
        )
        XCTAssertEqual(error, .duplicate(.captureRegion))
        XCTAssertEqual(error?.errorDescription, "已被「捕获区域」使用")
    }

    func testExternalConflictWithExternal() {
        let taken = Shortcut(keyCode: kVK_ANSI_8, modifiers: optionCommand)
        let error = ShortcutValidator.validate(
            taken,
            for: .external("ext.beta"),
            builtin: defaults(),
            external: ["ext.alpha": taken],
            titleOf: { id in
                if case .external("ext.alpha") = id { return "功能甲" }
                return "功能乙"
            }
        )
        XCTAssertEqual(error, .duplicateExternal(title: "功能甲"))
    }

    func testSameBindingIsAllowed() {
        let shortcut = Shortcut(keyCode: kVK_ANSI_8, modifiers: optionCommand)
        XCTAssertNil(ShortcutValidator.validate(
            shortcut,
            for: .external("ext.alpha"),
            builtin: defaults(),
            external: ["ext.alpha": shortcut],
            titleOf: { _ in "功能甲" }
        ))
        XCTAssertNil(ShortcutValidator.validate(
            HotkeyAction.captureRegion.defaultShortcut,
            for: .builtin(.captureRegion),
            builtin: defaults(),
            external: [:],
            titleOf: { _ in "" }
        ))
    }

    func testSystemAndModifierRulesOnTheNewOverload() {
        let system = Shortcut(keyCode: kVK_ANSI_4, modifiers: Shortcut.command | Shortcut.shift)
        XCTAssertEqual(
            ShortcutValidator.validate(system, for: .external("ext.alpha"), builtin: [:], external: [:], titleOf: { _ in "" }),
            .reservedBySystem
        )
        XCTAssertEqual(
            ShortcutValidator.validate(
                Shortcut(keyCode: kVK_ANSI_A, modifiers: 0),
                for: .builtin(.openHistory),
                builtin: [:],
                external: [:],
                titleOf: { _ in "" }
            ),
            .needsModifier
        )
        XCTAssertNil(ShortcutValidator.validate(
            Shortcut(keyCode: kVK_F6, modifiers: 0),
            for: .external("ext.alpha"),
            builtin: [:],
            external: [:],
            titleOf: { _ in "" }
        ))
    }

    func testNewErrorCopyAndExistingDuplicateCopy() {
        XCTAssertEqual(
            ShortcutValidationError.inUseByOtherApp.errorDescription,
            "被其他 App 占用，没有保存，请换一个"
        )
        XCTAssertEqual(
            ShortcutValidationError.registrationFailed(7).errorDescription,
            "注册失败（7）"
        )
        XCTAssertEqual(
            ShortcutValidationError.duplicate(.captureScrolling).errorDescription,
            "已被「滚动捕获」使用"
        )
        XCTAssertEqual(
            ShortcutValidationError.needsModifier.errorDescription,
            "请至少包含 ⌘、⌥ 或 ⌃ 之一"
        )
        XCTAssertEqual(
            ShortcutValidationError.reservedBySystem.errorDescription,
            "⌘⇧3 / ⌘⇧4 / ⌘⇧5 / ⌘⇧6 是系统截图快捷键，PrettyShot 不会占用"
        )
    }

    private func defaults() -> [HotkeyAction: Shortcut] {
        Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultShortcut) })
    }
}
