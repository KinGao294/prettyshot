import Carbon.HIToolbox
import Combine
import XCTest
@testable import PrettyShot

@MainActor
final class FakeHotkeyRegistrar: HotkeyRegistrar {
    private final class Token {}

    private var tokens: [UInt: Token] = [:]
    private var carbonByBits: [UInt: UInt32] = [:]
    private(set) var registered: [UInt32: Shortcut] = [:]
    /// Consumed in order. A non-zero status fails that one attempt; `noErr` succeeds.
    var scriptedStatuses: [OSStatus] = []
    /// Used when `scriptedStatuses` is empty.
    var forcedStatus: OSStatus?

    func register(_ shortcut: Shortcut, carbonID: UInt32) -> Result<EventHotKeyRef, OSStatus> {
        if !scriptedStatuses.isEmpty {
            let status = scriptedStatuses.removeFirst()
            if status != noErr { return .failure(status) }
        } else if let forcedStatus, forcedStatus != noErr {
            return .failure(forcedStatus)
        }
        let token = Token()
        let pointer = Unmanaged.passUnretained(token).toOpaque()
        let bits = UInt(bitPattern: pointer)
        tokens[bits] = token
        carbonByBits[bits] = carbonID
        registered[carbonID] = shortcut
        return .success(Self.ref(for: pointer))
    }

    func unregister(_ ref: EventHotKeyRef) {
        let bits = Self.bits(of: ref)
        tokens[bits] = nil
        if let carbonID = carbonByBits.removeValue(forKey: bits) {
            registered[carbonID] = nil
        }
    }

    private static func ref(for pointer: UnsafeMutableRawPointer) -> EventHotKeyRef {
        unsafeBitCast(pointer, to: EventHotKeyRef.self)
    }

    private static func bits(of ref: EventHotKeyRef) -> UInt {
        UInt(bitPattern: unsafeBitCast(ref, to: UnsafeMutableRawPointer.self))
    }
}

final class HotkeyRegistryTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var fake: FakeHotkeyRegistrar!

    override func setUp() {
        super.setUp()
        suite = "PrettyShotTests.hotkeys.registry.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    @MainActor
    func testBuiltinCarbonIDsStayOneThroughSixAndExternalStartAt1000() {
        let manager = makeManager()
        let first = sampleAction(id: "ext.first", title: "功能甲", key: kVK_ANSI_8)
        let second = sampleAction(id: "ext.second", title: "功能乙", key: kVK_ANSI_9, order: 110)
        manager.register(first)
        manager.register(second)
        manager.registerAll()

        for (index, action) in HotkeyAction.allCases.enumerated() {
            XCTAssertEqual(fake.registered[UInt32(index + 1)], action.defaultShortcut, "\(action)")
        }
        XCTAssertEqual(fake.registered[1000], first.defaultShortcut)
        XCTAssertEqual(fake.registered[1001], second.defaultShortcut)
        XCTAssertNil(fake.registered[HotkeyCarbon.escapeID])
        XCTAssertEqual(HotkeyAction.allCases.map(\.rawValue), [
            "captureRegion", "captureWindow", "captureFullscreen", "captureScrolling", "openHistory", "pinLatest",
        ])
    }

    @MainActor
    func testUnsuspendedConflictDoesNotSaveAndRollsBack() {
        let manager = makeManager()
        manager.registerAll()
        let old = HotkeyAction.captureRegion.defaultShortcut
        XCTAssertEqual(fake.registered[1], old)
        XCTAssertNil(defaults.data(forKey: "hotkeys.v1"))

        let blocked = Shortcut(keyCode: kVK_ANSI_R, modifiers: Shortcut.command | Shortcut.option)
        fake.scriptedStatuses = [OSStatus(eventHotKeyExistsErr)]
        XCTAssertEqual(manager.setShortcut(blocked, for: .captureRegion), .inUseByOtherApp)
        XCTAssertEqual(manager.shortcut(for: .captureRegion), old)
        XCTAssertNil(defaults.data(forKey: "hotkeys.v1"))
        XCTAssertEqual(fake.registered[1], old)
        XCTAssertFalse(fake.registered.values.contains(blocked))
    }

    @MainActor
    func testUnsuspendedOtherStatusDoesNotSave() {
        let manager = makeManager()
        manager.registerAll()
        let before = defaults.data(forKey: "hotkeys.v1")
        fake.scriptedStatuses = [42]
        let blocked = Shortcut(keyCode: kVK_ANSI_R, modifiers: Shortcut.command | Shortcut.option)
        XCTAssertEqual(manager.setShortcut(blocked, for: .captureRegion), .registrationFailed(42))
        XCTAssertEqual(manager.shortcut(for: .captureRegion), HotkeyAction.captureRegion.defaultShortcut)
        XCTAssertEqual(defaults.data(forKey: "hotkeys.v1"), before)
        XCTAssertEqual(fake.registered[1], HotkeyAction.captureRegion.defaultShortcut)
    }

    @MainActor
    func testSuspendedSetShortcutStillPersistsWithoutRegistering() {
        let manager = makeManager()
        manager.suspend()
        fake.scriptedStatuses = [OSStatus(eventHotKeyExistsErr)]
        let custom = Shortcut(keyCode: kVK_ANSI_R, modifiers: Shortcut.control | Shortcut.option)
        XCTAssertNil(manager.setShortcut(custom, for: .captureRegion))
        XCTAssertEqual(manager.shortcut(for: .captureRegion), custom)
        XCTAssertEqual(fake.scriptedStatuses, [OSStatus(eventHotKeyExistsErr)])
        XCTAssertTrue(fake.registered.isEmpty)

        let reloaded = HotkeyManager(defaults: defaults, registrar: FakeHotkeyRegistrar())
        XCTAssertEqual(reloaded.shortcut(for: .captureRegion), custom)
    }

    @MainActor
    func testExternalBindingPersistsSeparatelyFromBuiltin() {
        let manager = makeManager()
        manager.suspend()
        let action = sampleAction(id: "ext.live", title: "功能甲", key: kVK_ANSI_8)
        manager.register(action)
        let custom = Shortcut(keyCode: kVK_ANSI_7, modifiers: Shortcut.command | Shortcut.option)
        XCTAssertNil(manager.setShortcut(custom, for: .external(action.id)))
        XCTAssertNil(defaults.data(forKey: "hotkeys.v1"))

        let stored = decodeExternal()
        XCTAssertEqual(stored[action.id]?.shortcut, custom)

        let reloaded = HotkeyManager(defaults: defaults, registrar: FakeHotkeyRegistrar())
        reloaded.suspend()
        reloaded.register(action)
        XCTAssertEqual(reloaded.shortcut(for: .external(action.id)), custom)
        XCTAssertEqual(reloaded.shortcut(for: .captureRegion), HotkeyAction.captureRegion.defaultShortcut)
    }

    @MainActor
    func testExternalStorageKeepsUnregisteredIDs() {
        let orphan = Shortcut(keyCode: kVK_ANSI_9, modifiers: Shortcut.command)
        defaults.set(try! JSONEncoder().encode(["module.orphan": StoredShortcut(shortcut: orphan)]), forKey: "hotkeys.external.v1")

        let manager = makeManager()
        manager.suspend()
        XCTAssertNil(manager.setShortcut(
            Shortcut(keyCode: kVK_ANSI_B, modifiers: Shortcut.command | Shortcut.option),
            for: .captureWindow
        ))
        var stored = decodeExternal()
        XCTAssertEqual(stored["module.orphan"]?.shortcut, orphan)

        let action = sampleAction(id: "ext.live", title: "功能甲", key: kVK_ANSI_8)
        manager.register(action)
        let custom = Shortcut(keyCode: kVK_ANSI_7, modifiers: Shortcut.command | Shortcut.shift)
        XCTAssertNil(manager.setShortcut(custom, for: .external(action.id)))
        stored = decodeExternal()
        XCTAssertEqual(stored["module.orphan"]?.shortcut, orphan)
        XCTAssertEqual(stored["ext.live"]?.shortcut, custom)

        let builtin = try! JSONDecoder().decode(
            [String: StoredShortcut].self,
            from: defaults.data(forKey: "hotkeys.v1")!
        )
        XCTAssertEqual(Set(builtin.keys), Set(HotkeyAction.allCases.map(\.rawValue)))
        XCTAssertNil(builtin["ext.live"])
        XCTAssertNil(builtin["module.orphan"])
    }

    @MainActor
    func testRegistrationFailuresIncludeBuiltinAndExternal() {
        let manager = makeManager()
        manager.suspend()
        let action = sampleAction(id: "ext.fail", title: "功能甲", key: kVK_ANSI_8)
        manager.register(action)
        fake.forcedStatus = OSStatus(eventHotKeyExistsErr)

        var latest: [HotkeyBindingID] = []
        let cancellable = manager.registrationFailures.sink { latest = $0 }
        manager.resume()

        let occupied = "与其它 App 的全局快捷键冲突，请在上方重新设置"
        XCTAssertEqual(manager.registrationErrors[.captureScrolling], occupied)
        XCTAssertEqual(manager.externalRegistrationErrors[action.id], occupied)
        XCTAssertEqual(latest, HotkeyAction.allCases.map { .builtin($0) } + [.external(action.id)])
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testSetShortcutConflictDoesNotPublishRegistrationFailure() {
        let manager = makeManager()
        manager.registerAll()
        var emissions = 0
        let cancellable = manager.registrationFailures.sink { _ in emissions += 1 }
        let baseline = emissions
        fake.scriptedStatuses = [OSStatus(eventHotKeyExistsErr)]
        _ = manager.setShortcut(
            Shortcut(keyCode: kVK_ANSI_R, modifiers: Shortcut.command | Shortcut.option),
            for: .captureRegion
        )
        XCTAssertEqual(emissions, baseline)
        XCTAssertTrue(manager.registrationErrors.isEmpty)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testHotKeyDispatchUsesExternalIDs() {
        let manager = makeManager()
        var externalHits = 0
        var builtin: HotkeyAction?
        var escaped = false
        let action = sampleAction(id: "ext.dispatch", title: "功能甲", key: kVK_ANSI_8) {
            externalHits += 1
        }
        manager.register(action)
        manager.onTrigger = { builtin = $0 }
        manager.onEscape = { escaped = true }

        manager.handleHotKey(id: 1000)
        manager.handleHotKey(id: 1)
        manager.handleHotKey(id: HotkeyCarbon.escapeID)

        XCTAssertEqual(externalHits, 1)
        XCTAssertEqual(builtin, .captureRegion)
        XCTAssertTrue(escaped)
    }

    @MainActor
    func testFailureNoticeCopyForSingleMultipleAndOverride() {
        let single = HotkeyFailureNoticeContent.make(items: [
            .init(shortcut: "⌥⌘1", title: "捕获区域", registrationFailedTitle: nil, registrationFailedDetail: nil),
        ])
        XCTAssertEqual(single?.title, "⌥⌘1 被其他 App 占用，捕获区域快捷键暂不可用")
        XCTAssertEqual(single?.detail, HotkeyFailureNoticeContent.singleDetail)

        let custom = HotkeyFailureNoticeContent.make(items: [
            .init(
                shortcut: "⌥⌘8",
                title: "功能甲",
                registrationFailedTitle: "自定义标题",
                registrationFailedDetail: "自定义说明"
            ),
        ])
        XCTAssertEqual(custom?.title, "自定义标题")
        XCTAssertEqual(custom?.detail, "自定义说明")

        let multiple = HotkeyFailureNoticeContent.make(items: [
            .init(shortcut: "⌥⌘1", title: "捕获区域", registrationFailedTitle: "自定义标题", registrationFailedDetail: "自定义说明"),
            .init(shortcut: "⌥⌘8", title: "功能甲", registrationFailedTitle: nil, registrationFailedDetail: nil),
        ])
        XCTAssertEqual(multiple?.title, "2 个快捷键被其他 App 占用")
        XCTAssertEqual(multiple?.detail, HotkeyFailureNoticeContent.multipleDetail)
        XCTAssertEqual(HotkeyFailureNoticeContent.changeButton, "去更换")
        XCTAssertEqual(HotkeyFailureNoticeContent.laterButton, "稍后")
        XCTAssertEqual(HotkeyFailureNoticeContent.autoDismiss, 8)
        XCTAssertEqual(HotkeyFailureNoticeContent.inactiveCapsule, "未生效")
    }

    @MainActor
    func testManagerNoticeUsesExternalCopyForOneFailure() {
        let manager = makeManager()
        manager.suspend()
        let action = ExternalHotkeyAction(
            id: "ext.notice",
            group: HotkeyGroup(id: "group.tools", title: "工具", order: 100),
            title: "功能甲",
            defaultShortcut: Shortcut(keyCode: kVK_ANSI_8, modifiers: Shortcut.option | Shortcut.command),
            copy: HotkeyCopy(registrationFailedTitle: "自定义标题", registrationFailedDetail: "自定义说明"),
            handler: {}
        )
        manager.register(action)
        fake.forcedStatus = OSStatus(eventHotKeyExistsErr)
        fake.scriptedStatuses = Array(repeating: noErr, count: HotkeyAction.allCases.count)
        manager.resume()
        let content = manager.failureNoticeContent()
        XCTAssertEqual(content?.title, "自定义标题")
        XCTAssertEqual(content?.detail, "自定义说明")
    }

    @MainActor
    func testResetToDefaultsLeavesExternalBindings() {
        let manager = makeManager()
        manager.suspend()
        let action = sampleAction(id: "ext.keep", title: "功能甲", key: kVK_ANSI_8)
        manager.register(action)
        let custom = Shortcut(keyCode: kVK_ANSI_7, modifiers: Shortcut.command | Shortcut.option)
        XCTAssertNil(manager.setShortcut(custom, for: .external(action.id)))
        XCTAssertNil(manager.setShortcut(
            Shortcut(keyCode: kVK_ANSI_B, modifiers: Shortcut.command),
            for: .captureRegion
        ))
        manager.resetToDefaults()
        XCTAssertEqual(manager.shortcut(for: .captureRegion), HotkeyAction.captureRegion.defaultShortcut)
        XCTAssertEqual(manager.shortcut(for: .external(action.id)), custom)
    }

    @MainActor
    func testMenuHintShowsInactiveOnlyWhenRegistrationFailed() {
        let manager = makeManager()
        XCTAssertEqual(manager.menuHint(for: .captureRegion), "⌥⌘1")
        fake.forcedStatus = OSStatus(eventHotKeyExistsErr)
        manager.registerAll()
        XCTAssertEqual(manager.menuHint(for: .captureRegion), "未生效")
        XCTAssertEqual(manager.displayString(for: .captureRegion), "⌥⌘1")
    }

    @MainActor
    private func makeManager() -> HotkeyManager {
        let registrar = FakeHotkeyRegistrar()
        fake = registrar
        return HotkeyManager(defaults: defaults, registrar: registrar)
    }

    @MainActor
    private func sampleAction(
        id: String,
        title: String,
        key: Int,
        order: Int = 100,
        handler: @escaping @MainActor () -> Void = {}
    ) -> ExternalHotkeyAction {
        ExternalHotkeyAction(
            id: id,
            group: HotkeyGroup(id: "group.\(order)", title: "工具", order: order),
            title: title,
            subtitle: "次要说明",
            defaultShortcut: Shortcut(keyCode: key, modifiers: Shortcut.option | Shortcut.command),
            handler: handler
        )
    }

    private func decodeExternal() -> [String: StoredShortcut] {
        guard let data = defaults.data(forKey: "hotkeys.external.v1") else {
            XCTFail("missing hotkeys.external.v1")
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: StoredShortcut].self, from: data)
        } catch {
            XCTFail("\(error)")
            return [:]
        }
    }
}

private struct StoredShortcut: Codable {
    var shortcut: Shortcut?
}
