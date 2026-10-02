# PrettyShot

做产品和做内容的人，每天都在截图。

系统那一下太素了。直角、硬边、一块没有收拾过的桌面。丢进文档、路演、推文里，整页立刻掉一档。你不是不会修：圆角、留白、一层浅浅的渐变，修完就对了。烦的是，每截一张都要再走一遍。

PrettyShot 把这件事收进菜单栏。选一块，松开。图已经像一张印好的卡片。复制，贴走。三步。

**https://github.com/KinGao294/prettyshot**

原生 macOS 应用。没有网页版，截图也不会离开这台电脑。

---

光圈在菜单栏右侧。它不进 Dock。`⌥⌘1` 框选，`⌥⌘2` 窗口，`⌥⌘3` 整屏。系统那三组 `⌘⇧3 / 4 / 5` 还是系统的，PrettyShot 不抢。

截完先出现一块小面板，主按钮只有 Copy。回车，或者 `⌘C`。焦点回到你刚才正在写的那个窗口，直接粘贴。需要箭头、打码、换一套背景，再按 `⌘E`。

九套背景都是自己配的：纸雾、墨洗、柔瓣、苔静、暮紫、瓷白、夜墨、柑雾，还有奶油、粉和天蓝从角上晕开的彩霭。圆角、边距、阴影可以拧。也可以不要背景，只在原图上画。打码会写进像素，不是盖一层还能揭开的膜。

历史留在本机，最多两百张。有旧图时，第一格是「新截图」。重要的一张可以钉在桌面上，半透明，点得穿。

没开屏幕录制时，会说清楚缺什么，并带你去系统设置。不会交回一张黑图，假装成功。

---

## 打开

macOS 14，Xcode。没有别的依赖。

```bash
git clone https://github.com/KinGao294/prettyshot.git
cd prettyshot
scripts/setup_local_signing.sh
xcodebuild -project PrettyShot.xcodeproj -scheme PrettyShot -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/PrettyShot.app
```

那张本地证书是为了让屏幕录制授权活过下一次编译。不签的话，系统会把新编出来的应用当成另一个程序，又问你一次。

第一次截图：隐私与安全性 › 录屏与系统录音 › 打开 PrettyShot › 回到应用里重新启动。之后就不用再走这一遍。

也可以打开 `PrettyShot.xcodeproj`，目标选你的 Mac，`⌘R`。

---

## 手不离开键盘

| | |
|---|---|
| 框选 | `⌥⌘1` |
| 窗口 | `⌥⌘2` |
| 整屏 | `⌥⌘3` |
| 复制 | `↩` · `⌘C` |
| 标注和背景 | `⌘E` |
| 历史 | `⌥⌘H` |
| 钉住最近一张 | `⌥⌘P` |

`Esc` 取消。这些键都可以改。

---

## 边界

这版不做录屏、滚动长图、识字、云同步、iPhone。一张图，从屏幕到剪贴板，中间可以变好看。先把这条路做干净。

代码写在这个仓库里。怎么分层、背景怎么做成一套有名字的渐变，思路上看过 [dodoshot](https://github.com/DodoApps/dodoshot)、[openshots](https://github.com/Tracekit-Dev/openshots)、[simpleshot](https://github.com/alexrett/simpleshot)，都是 MIT。没有用它们的代码和素材。

[MIT](LICENSE) © 2026 PrettyShot contributors
