import Carbon.HIToolbox
import XCTest
@testable import PrettyShot

final class HotkeySettingsLayoutTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "PrettyShotTests.hotkeys.layout.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    @MainActor
    func testEmptyExternalGroupMatchesBuiltinSnapshot() {
        let manager = makeManager()
        XCTAssertEqual(manager.externalSettingsGroups, [])
        XCTAssertEqual(HotkeyAction.allCases.map(\.title), [
            "捕获区域",
            "捕获窗口",
            "捕获全屏",
            "滚动捕获",
            "打开历史",
            "Pin 最近一张",
        ])
        let page = ShortcutSettings(hotkeys: manager)
        _ = page.body
    }

    @MainActor
    func testExternalGroupRendersTitleFootnoteAndRows() {
        let manager = makeManager()
        manager.suspend()
        manager.register(action(
            id: "ext.alpha",
            groupID: "group.tools",
            groupTitle: "工具",
            footnote: "组内说明",
            title: "功能甲",
            subtitle: "次要说明",
            order: 100
        ))
        manager.register(action(
            id: "ext.beta",
            groupID: "group.tools",
            groupTitle: "工具",
            footnote: "组内说明",
            title: "功能乙",
            subtitle: nil,
            order: 100
        ))

        XCTAssertEqual(manager.externalSettingsGroups.count, 1)
        let group = manager.externalSettingsGroups[0]
        XCTAssertEqual(group.id, "group.tools")
        XCTAssertEqual(group.title, "工具")
        XCTAssertEqual(group.footnote, "组内说明")
        XCTAssertEqual(group.rows.map(\.title), ["功能甲", "功能乙"])
        XCTAssertEqual(group.rows.map(\.subtitle), ["次要说明", nil])
        let page = ShortcutSettings(hotkeys: manager)
        _ = page.body
    }

    @MainActor
    func testEmptyGroupIsOmitted() {
        let manager = makeManager()
        manager.suspend()
        manager.register(action(
            id: "ext.alpha",
            groupID: "group.tools",
            groupTitle: "工具",
            footnote: nil,
            title: "功能甲",
            subtitle: nil,
            order: 100
        ))
        XCTAssertEqual(manager.externalSettingsGroups.map(\.id), ["group.tools"])
        manager.unregister(id: "ext.alpha")
        XCTAssertEqual(manager.externalSettingsGroups, [])
        let page = ShortcutSettings(hotkeys: manager)
        _ = page.body
    }

    @MainActor
    func testGroupsSortByOrderThenRegistration() {
        let manager = makeManager()
        manager.suspend()
        manager.register(action(
            id: "ext.later",
            groupID: "group.later",
            groupTitle: "后一组",
            footnote: nil,
            title: "功能乙",
            subtitle: nil,
            order: 200
        ))
        manager.register(action(
            id: "ext.sooner",
            groupID: "group.sooner",
            groupTitle: "先一组",
            footnote: nil,
            title: "功能甲",
            subtitle: nil,
            order: 100
        ))
        manager.register(action(
            id: "ext.same",
            groupID: "group.same",
            groupTitle: "同序后到",
            footnote: nil,
            title: "功能丙",
            subtitle: nil,
            order: 200
        ))
        XCTAssertEqual(manager.externalSettingsGroups.map(\.title), ["先一组", "后一组", "同序后到"])
    }

    @MainActor
    private func makeManager() -> HotkeyManager {
        HotkeyManager(defaults: defaults, registrar: FakeHotkeyRegistrar())
    }

    @MainActor
    private func action(
        id: String,
        groupID: String,
        groupTitle: String,
        footnote: String?,
        title: String,
        subtitle: String?,
        order: Int
    ) -> ExternalHotkeyAction {
        ExternalHotkeyAction(
            id: id,
            group: HotkeyGroup(id: groupID, title: groupTitle, footnote: footnote, order: order),
            title: title,
            subtitle: subtitle,
            defaultShortcut: Shortcut(keyCode: kVK_ANSI_8, modifiers: Shortcut.option | Shortcut.command),
            handler: {}
        )
    }
}
