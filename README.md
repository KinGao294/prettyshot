# PrettyShot

一个优雅、简洁的 macOS 菜单栏截图工具。

截完自动加上圆角、边距、阴影和背景，复制后直接粘贴到文档、幻灯片或推文里。系统自带的截图是直角，背景也是当时桌面的样子，放进正式材料里通常还得再修一遍；PrettyShot 把这一步省掉了。

原生 macOS 应用，全部在本机处理，截图不会上传。

## 用法

PrettyShot 只在菜单栏有图标，不出现在 Dock 里。

- `⌥⌘1` 框选，`⌥⌘2` 窗口，`⌥⌘3` 整屏
- 系统自带的 `⌘⇧3 / 4 / 5` 照常可用，不冲突

截完会弹出一个小面板。按回车或 `⌘C` 复制，焦点会回到你之前用的窗口，可以直接粘贴。要加箭头、打码或换背景，按 `⌘E` 进入编辑。

## 功能

- **背景**：内置 9 套（纸雾、墨洗、柔瓣、苔静、暮紫、瓷白、夜墨、柑雾、彩霭），也可以不加背景，只在原图上标注
- **样式**：圆角、边距、阴影都能调
- **标注**：箭头和打码。打码直接改写像素，导出后无法还原
- **历史**：保存在本机，最多 200 张
- **钉图**：可以把一张截图钉在桌面上，半透明，鼠标点击会穿过去
- **权限提示**：没有开屏幕录制权限时，会提示缺什么并跳转到系统设置，不会输出黑图

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 框选 | `⌥⌘1` |
| 窗口 | `⌥⌘2` |
| 整屏 | `⌥⌘3` |
| 复制 | `↩` / `⌘C` |
| 标注和背景 | `⌘E` |
| 历史 | `⌥⌘H` |
| 钉住最近一张 | `⌥⌘P` |
| 取消 | `Esc` |

快捷键都可以修改。

## 安装

### 方式一：clone 源码编译

需要 macOS 14 和 Xcode，没有其他依赖。

```bash
git clone https://github.com/KinGao294/prettyshot.git
cd prettyshot
scripts/setup_local_signing.sh
xcodebuild -project PrettyShot.xcodeproj -scheme PrettyShot -configuration Debug \
  -derivedDataPath build build
open build/Build/Products/Debug/PrettyShot.app
```

`setup_local_signing.sh` 会创建一张本地签名证书。不签名的话，每次重新编译后系统都会把它当成新应用，要重新授权屏幕录制。

也可以直接打开 `PrettyShot.xcodeproj`，目标选你的 Mac，按 `⌘R` 运行。

### 方式二：下载安装包

到 [Releases](https://github.com/KinGao294/prettyshot/releases/latest) 下载最新的 `PrettyShot-x.y.z.dmg`，打开后把 PrettyShot 拖进「应用程序」。支持 macOS 14 及以上，Apple 芯片和 Intel 都能用。

这个版本没有经过 Apple 签名和公证，第一次打开时系统会拦下来。点「完成」后，去「系统设置 › 隐私与安全性」，在页面下方点「仍要打开」。也可以在终端运行：

```bash
xattr -dr com.apple.quarantine /Applications/PrettyShot.app
```

### 屏幕录制权限

两种方式都需要：第一次截图前，到「系统设置 › 隐私与安全性 › 录屏与系统录音」里打开 PrettyShot，然后重启应用。之后不用再设置。

## 协议

[MIT](LICENSE) © 2026 PrettyShot contributors
