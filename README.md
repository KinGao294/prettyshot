# PrettyShot

**截一张图。三步，进剪贴板。出来的时候，它该像一张印好的卡片。**

纸感光晕 · Paper Bloom　·　macOS 14+　·　Swift / SwiftUI　·　没有云

菜单栏右侧有一枚光圈。按一下，画面冻住，拖出一块区域，松开。缩略图落在角落，主按钮只有一个：**Copy**。想再好看一点，就进编辑器：箭头、打码、九套自己的背景。截图只活在这台 Mac 上。

```
⌥⌘1 选区  →  Copy                         三步
              └→ Annotate → 标注 / 打码 / 背景 → Copy 或导出
```

不抢系统截图键。`⌘⇧3` `⌘⇧4` `⌘⇧5` 还是系统的。PrettyShot 用自己的 `⌥⌘1` `⌥⌘2` `⌥⌘3`。

---

## 你会用到的

**捕获。** 区域、窗口、全屏。捕获前先冻住画面，底部可以换模式。`Esc`，或者再按一次快捷键，取消。取消之后状态是干净的，可以立刻再截。

**Quick Overlay。** 截完先出现这块小面板，不是编辑器。`↩` 或 `⌘C` 复制，`⌘E` 去标注，`⌘S` 存到下载，缩略图可以拖进别的 App，`⌘P` 钉在桌面上。关掉之后，焦点回到截图前的那个 App，直接 `⌘V`。

**标注。** 箭头、矩形、椭圆、文字、计数序号、裁剪。能选、能挪、能撤销。

**打码。** 像素化或模糊。导出时烘焙进像素，不是盖一层能揭开的蒙版。

**背景。** 九套原创渐变，外加 Padding、圆角、阴影。也可以不要背景，只留标注。

| | | |
|---|---|---|
| Paper Mist 纸雾 | Ink Wash 墨洗 | Soft Bloom 柔瓣 |
| Moss Quiet 苔静 | Dusk Lilac 暮紫 | Ceramic White 瓷白 |
| Night Ink 夜墨 | Citrus Fog 柑雾 | Pastel Air 彩霭 |

彩霭是奶油、粉和天蓝从几个角晕开的浅色。强调色只有一个：Bloom Rose `#E8A0A8`。

**历史。** 最多 200 张，存在本机。可以重开编辑、Pin、复制、在 Finder 里显示、删掉。有旧图时，第一格是「新截图」。

**Pin。** 一张浮在所有窗口上面的图。透明度、尺寸、点击穿透。穿透之后从菜单栏找回。`Esc` 或 `⌘W` 关掉。

**权限。** 没开屏幕录制时，给你一页能读的说明，和一颗打开系统设置的按钮。不会交回一张黑图，假装截成功了。

---

## 跑起来

macOS 14 或更新。Xcode 15.4+。没有第三方依赖。

PrettyShot 是菜单栏应用，**不会出现在 Dock**。看屏幕最上方、摄像头右边的那枚小圆环。

```bash
git clone https://github.com/KinGao294/prettyshot.git
cd prettyshot

# 本机签一张固定证书。不签的话，每次重新编译 macOS 都会忘掉屏幕录制授权。
scripts/setup_local_signing.sh

xcodebuild -project PrettyShot.xcodeproj -scheme PrettyShot -configuration Debug \
  -derivedDataPath build build

open build/Build/Products/Debug/PrettyShot.app
```

也可以直接用 Xcode 打开 `PrettyShot.xcodeproj`，Scheme 选 PrettyShot，目标 My Mac，`⌘R`。

第一次截图：系统设置 › 隐私与安全性 › 录屏与系统录音 › 打开 PrettyShot › 回到应用里点「重新启动」。这张证书固定之后，再编译不用重新授权。

```bash
# 渲染、打码、历史、快捷键、编辑器、坐标
xcodebuild test -project PrettyShot.xcodeproj -scheme PrettyShot -destination 'platform=macOS'
```

证书只在你的登录钥匙串里，路径是 `~/Library/Application Support/PrettyShot/Signing/`，不进仓库。

---

## 键

| 在哪 | 按什么 |
|------|--------|
| 任何地方 | `⌥⌘1` 区域 · `⌥⌘2` 窗口 · `⌥⌘3` 全屏 · `⌥⌘H` 历史 · `⌥⌘P` Pin 最近一张 |
| 捕获时 | 拖选区，或点一个窗口。`Esc` 取消 |
| 截完的小面板 | `↩` / `⌘C` 复制 · `⌘E` 标注 · `⌘S` 保存 · `⌘P` Pin · `Esc` 关掉 |
| 编辑器 | `V` 选择 · `A` 箭头 · `R` 矩形 · `O` 椭圆 · `T` 文字 · `N` 计数 · `C` 裁剪 · `P` 像素 · `B` 模糊 · `⌫` 删除 · `⌘Z` |
| Pin | 拖动。悬停后调透明度、尺寸、穿透。`Esc` / `⌘W` 关 |

快捷键可以在设置里重录。全局热键走 Carbon `RegisterEventHotKey`，不申请辅助功能权限，也能发现和别的 App 撞车。

历史在 `~/Library/Application Support/PrettyShot/History/`。保存默认进「下载」。

---

## 这版不做

录屏、iPhone、云同步、滚动长图、OCR。界面里的系统图标来自 SF Symbols。品牌只有 PrettyShot 和 Paper Bloom，不用别人的名字、配色和截图来给自己当样子。

---

## 代码

预览和导出走同一套绘制。你在编辑器里看见的，就是 PNG 里的。

```
PrettyShot/
  App/           菜单栏、以及捕获 → Overlay → 编辑器 / 历史 / Pin 的编排
  Capture/       ScreenCaptureKit，冻结帧，选区
  Overlay/       截完之后的那块小面板
  Editor/        标注、打码、九套背景、同一条渲染路径
  History/       本机 PNG + index.json
  Pin/           置顶浮窗
  Permissions/   屏幕录制说人话的那一页
  Hotkeys/       全局热键
  Settings/
PrettyShotTests/
design/          设计真源：DESIGN.md、prototype.html
```

没开 App Sandbox，因为要写到你选的文件夹。开了 Hardened Runtime。和设计稿不一致的地方写在 [DEVIATIONS.md](DEVIATIONS.md)。

增删源文件之后：

```bash
python3 scripts/gen_xcodeproj.py
# 或 xcodegen generate
```

---

## 借鉴了什么，没抄什么

代码是这个仓库里写的。下面这些项目只提供过思路，没有复制它们的源码、资源和文案。

| 项目 | 许可证 | 参考了什么 |
|------|--------|------------|
| [dodoshot](https://github.com/DodoApps/dodoshot) | MIT | 模块怎么切开：捕获、标注、Pin、历史 |
| [openshots](https://github.com/Tracekit-Dev/openshots) | MIT | 背景可以是「一个有名字的渐变 + padding / 圆角 / 阴影」 |
| [simpleshot](https://github.com/alexrett/simpleshot) | MIT | 一张图包进渐变里，这件事可以做得很小 |

[SnapDress](https://github.com/xiangyizengdev/SnapDress)、[Snapper](https://github.com/Yonghero/Snapper) 没有落盘许可证，没有使用它们的代码。[skreenme](https://github.com/levskiy0/skreenme) 没有可用源码，没有使用。

---

## License

[MIT](LICENSE) © 2026 PrettyShot contributors
