# iOS 免费 Apple ID 签名

查文档日期：2026-10-03。默认构建**不申请 App Group**。分享扩展在自己进程里完成编辑、复制和「仅添加照片」保存；主 App 可以单独安装，但收不到扩展暂存的文件。

## 文档里写明的事实

来源：[About your developer account](https://developer.apple.com/help/account/basics/about-your-developer-account/)（Personal Team，免费 Apple ID）。

- 最多 10 个 App ID，7 天后失效。
- 最多注册 3 台设备，注册 7 天后失效。
- 每台设备最多同时装 3 个用这个免费账号签名的 App。
- 描述文件从签发起 7 天有效。到期后要重新编译、重新安装。
- Certificates, Identifiers & Profiles、TestFlight、App Store Connect 属于付费账号。免费账号进不了这些门户。

来源：[Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios) 页面上的 HTML 表格（2026-10-03 直接看单元格里的勾，不是被转成 Markdown 后丢掉勾的版本）。最右一列是免费的 Apple Developer Program 会员资格。这一列对 **App Groups** 是勾选的，同时勾选的还有 Background modes、Data protection、HealthKit、HomeKit、Inter-App Audio、Keychain sharing、Maps、Wireless Accessory Configuration。付费的 ADP / ADEP 列勾得更多。Quinn（Eskimo）在开发者论坛说过：最右列就是 Personal Team。

App Extensions 不是这张能力表里的一行。

## 必须在 Kin 的 Mac / 真机上核对

文档表格给免费列勾了 App Groups，但免费账号进不了用来注册 App Group 的 Identifiers 门户。Xcode 在 Personal Team 上打开 App Groups 时，历史上经常直接报 `Personal development teams do not support the App Groups capability`。这两件事互相矛盾。**这次不能当成已经能用。** 要在 Kin 的 Xcode 里给 `group.app.prettyshot.ios` 打开能力，看描述文件能不能签发、`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` 是不是非 nil。论坛帖子不算 Apple 文档。

扩展会不会占那「每台设备 3 个 App」的名额，当前帮助页没有写。Xcode 11.5 发行说明里的 bug 59264389 说过扩展会计入这个上限（这同时说明当时扩展能装上）。现在的行为要在真机上数一次。

## 仓库里的默认

`PrettyShotIOS/Handoff.xcconfig` 和 `PrettyShotShare/Handoff.xcconfig` 同步，除了 entitlements 路径：

- `PRETTYSHOT_HANDOFF_MODE = inline`
- `PRETTYSHOT_HANDOFF_CONDITION = PRETTYSHOT_HANDOFF_INLINE`

两个 target 的 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 带上这个条件。`HandoffStoreFactory.live()` 读 Info.plist 的 `PrettyShotHandoffMode`。`inline` 使用 `InlineHandoffStore`：数据只在当前进程的临时目录里，`canTransferToApp == false`。另一个进程再开一个 store，看不到这些票。

`mode == app-group` 但 `containerURL` 为 nil 时，工厂退回 inline，不崩溃。

两份 `.entitlements`（`group.app.prettyshot.ios`）已经放在工程里，**默认不挂到签名上**。xcconfig 里的 `CODE_SIGN_ENTITLEMENTS` 保持注释。

Bundle ID：主 App `app.prettyshot.ios`，扩展 `app.prettyshot.ios.share`。URL scheme `prettyshot://handoff`。部署目标 iOS 17，仅 iPhone。

## 用免费 Apple ID 装到自己的手机

1. Xcode → Settings → Accounts，用 Apple ID 登录。团队选 Personal Team。
2. 打开 `PrettyShot.xcodeproj`，scheme 选 **PrettyShotIOS**。
3. PrettyShotIOS 和 PrettyShotShare 两个 target 都选 Signing & Capabilities → Automatically manage signing，Team 选这个 Personal Team。
4. **不要**在还是 inline 的时候勾 App Groups。两份 `Handoff.xcconfig` 保持默认。
5. 如果 Bundle ID 已被别人占用，只改这两个 target 的 Bundle ID，扩展必须是主 App 的子 ID（例如 `app.prettyshot.ios.kin` 和 `app.prettyshot.ios.kin.share`），并同步改 URL scheme 的 `CFBundleURLName`。
6. 选自己的 iPhone，Run。手机上：设置 → 通用 → VPN 与设备管理，信任这台开发者。
7. 7 天后描述文件过期。重新 Run 一次。设备或 App ID 名额满了，用 Xcode → Window → Devices and Simulators 删掉旧的描述文件 / App，再装。
8. 扩展交不出原图时（默认 inline 就是这样），出现「改用 PrettyShot App 选图」。它打开 App 里的照片选择器，按原分辨率重新选。扩展里不提供「按预览尺寸保存」。单张图在内存预算内仍可在扩展里编辑、复制、存入相册，导出是原分辨率 PNG。

## 若要试 App Group

1. 两份 `Handoff.xcconfig` 一起改：注释掉 inline 那两行，取消注释 `app-group`、`PRETTYSHOT_HANDOFF_APP_GROUP` 和 `CODE_SIGN_ENTITLEMENTS`。只改 xcconfig 不用重新跑 `scripts/gen_xcodeproj.py`。
2. 两个 target 都打开 App Groups，勾上 `group.app.prettyshot.ios`。
3. 装到手机后看扩展和 App 的 `containerURL` 是否非 nil、App 首页是否出现「继续上次分享」。失败就改回 inline，能力关掉。

TestFlight、公证和上架仍然要付费开发者账号。M4 的真机内存测量也一样。

## M3：免费个人团队下，扩展能不能把原图交给 App

CI 验不了。模拟器 job 关掉了签名（`CODE_SIGNING_ALLOWED=NO`），也没有 Personal Team。

仓库默认 `InlineHandoffStore.canTransferToApp == false`。能力表给免费列勾了 App Groups，但免费账号进不了 Identifiers 门户，Xcode 在 Personal Team 上是否肯签发 `group.app.prettyshot.ios` 还没在 Kin 的机器上试过。所以这次不能写成「免费签名下扩展可以把原图交给 App」。

交不出原图时走「改用 PrettyShot App 选图」（`prettyshot://pick`），原图留在相册里，用户在 App 里按原分辨率重选。转交失败不删已暂存的票，要等 App 确认收到才 `confirmReceipt`。

真机步骤见 [ios-manual-tests.md](ios-manual-tests.md) 第 4 步。

分享扩展的验收里，模拟器替代不了的步骤也写在那份手测说明里。
