# PrettyShot

做产品的，还有天天发内容的朋友，大概都有这个烦法。

截图要发出去。系统自带的那一下又方又硬，边上还带着一截桌面，贴进文档、群聊、推文里，一看就是随手按的。想有点高级感，就得自己加圆角、留一圈空白，再垫一层渐变。每次都去另一款软件里折腾，截一张图要倒腾半天。

我自己被这个烦过很久，前后改了好几版，做成了 PrettyShot。菜单栏里一枚小光圈。选一块区域，松开，图已经带上圆角和背景。复制，贴走。

仓库在这，自己拿去用：

**https://github.com/KinGao294/prettyshot**

这不是网页，点开不会直接弹出一个在线工具。你用的是 Mac 的话，把仓库拉下来，下面几行命令跑完，菜单栏右边就会多出那枚光圈，之后截图用它就行。

有需要的朋友自取。用着顺手，转给同样要截图的人。觉得这个仓库还行，就点个 Star。

---

截图只留在你这台电脑上，不上传。不抢系统的 `⌘⇧3` `⌘⇧4` `⌘⇧5`，PrettyShot 用自己的 `⌥⌘1`。

背景一共九套，都是自己配的：纸雾、墨洗、柔瓣、苔静、暮紫、瓷白、夜墨、柑雾，还有一套奶油、粉、天蓝晕开的彩霭。圆角、边距、阴影都能拧。也可以不要背景，只在图上画箭头、打码。打码会真正写进像素里，不是盖一层还能揭开的膜。

---

## 在自己的 Mac 上打开

要 macOS 14，还要装 Xcode。没有别的依赖。

```bash
git clone https://github.com/KinGao294/prettyshot.git
cd prettyshot

# 先在这台电脑上签一张固定证书。
# 不签的话，你每次重新编译，系统都会把「屏幕录制」授权忘掉，又要你点一次。
scripts/setup_local_signing.sh

xcodebuild -project PrettyShot.xcodeproj -scheme PrettyShot -configuration Debug \
  -derivedDataPath build build

open build/Build/Products/Debug/PrettyShot.app
```

它不进 Dock。看屏幕最上面、摄像头右边的小圆环。

第一次截图，系统会问你允不允许录屏。到「隐私与安全性 › 录屏与系统录音」里把 PrettyShot 打开，回到应用里点「重新启动」。证书固定之后，再编译就不用重新授权了。

也可以用 Xcode 打开 `PrettyShot.xcodeproj`，选 PrettyShot，目标选你的 Mac，按 `⌘R`。

---

## 日常就这几个键

| 你想干什么 | 按 |
|---|---|
| 框一块区域 | `⌥⌘1` |
| 截一个窗口 | `⌥⌘2` |
| 截整屏 | `⌥⌘3` |
| 复制刚截的图 | `↩` 或 `⌘C` |
| 加箭头、圆角、背景 | `⌘E` |
| 看以前截过的 | `⌥⌘H` |
| 钉在桌面上 | `⌥⌘P` |

框选的时候按 `Esc` 就取消。复制完，焦点会回到你刚才正在用的那个软件，直接 `⌘V`。

这些键都能在设置里改成你顺手的。

---

## 这版先不做的

录屏、滚动长图、识别文字、同步到云、iPhone。先把「截一张好看的图」这件事做顺。

代码是这个仓库里写的。模块怎么切、背景怎么做成一套有名字的渐变，思路上参考过 [dodoshot](https://github.com/DodoApps/dodoshot)、[openshots](https://github.com/Tracekit-Dev/openshots)、[simpleshot](https://github.com/alexrett/simpleshot)，都是 MIT。没有抄它们的代码和素材。

[MIT](LICENSE) © 2026 PrettyShot contributors
