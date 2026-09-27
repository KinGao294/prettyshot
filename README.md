# PrettyShot

**Mac 截图 · 标注 + 美化**　—　纸感光晕 · Paper Bloom

原生 Swift / SwiftUI 菜单栏应用（macOS 14+，ScreenCaptureKit）。v0.1 MVP 主路径：

```
⌥⌘1 选区 → Quick Overlay → Copy        （≤ 3 步到剪贴板）
            └→ Annotate → 标注 / 打码 / 背景美化 → Copy / Export
```

截图只保存在本机，v0.1 没有任何云端功能。

---

## 功能（v0.1 MVP）

| 能力 | 说明 |
|------|------|
| 捕获 | 区域 / 窗口 / 全屏；捕获前冻结画面，HUD 底部 区域·窗口·全屏 chips 可切换；Esc 取消 |
| Quick Overlay | **Copy 主按钮**（↩ / ⌘C）· Annotate（⌘E）· Save（⌘S）· 拖拽缩略图到其它 App · Pin（⌘P）· Dismiss（Esc） |
| 标注 | 箭头、矩形、椭圆、文字、计数序号、裁剪；选择/移动、撤销/重做、颜色与粗细 |
| 打码 | 像素化 / 模糊（导出时不可逆烘焙进像素） |
| 美化 | 8 套原创背景：paper-mist · ink-wash · soft-bloom · moss-quiet · dusk-lilac · ceramic-white · night-ink · citrus-fog；Padding / Radius / Shadow；或「无背景」 |
| 历史 | 本地历史（最多 200 张），空态、网格、编辑/重开、Pin、复制、Finder 中显示、删除 |
| Pin | 置顶浮窗；透明度、尺寸；点击穿透（可在菜单栏恢复）；Esc / ⌘W 关闭 |
| 快捷键 | 默认 ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘H / ⌥⌘P，设置中可重映射；**不会占用** ⌘⇧3 / ⌘⇧4 / ⌘⇧5（录制时直接拒绝） |
| 权限 | 未授权「屏幕录制」时显示可读说明 + 打开系统设置 + 重新启动；绝不静默黑屏 |

明确不做（v0.1）：录屏 / Recording Studio、iPhone、云同步、滚动截图、OCR。

---

## 在 Mac 上打开与运行

**要求**：macOS 14 Sonoma 或更新；Xcode 15.4+（推荐 Xcode 16）。无第三方依赖。

### Xcode

1. 打开 `PrettyShot.xcodeproj`
2. Scheme 选 **PrettyShot**，目标 **My Mac**
3. ⌘R 运行 —— PrettyShot 是菜单栏应用（`LSUIElement`），**不会出现在 Dock**，看菜单栏右侧的光圈图标
4. 第一次捕获会引导你授权：系统设置 › 隐私与安全性 › 屏幕录制 → 打开 PrettyShot → 回到 PrettyShot 点「重新启动」

> **签名说明**：工程默认使用 “Sign to Run Locally”（ad-hoc），无需开发者账号即可编译。
> 但 ad-hoc 签名每次重新编译都会变化，macOS 可能要求重新授权屏幕录制。
> 日常开发建议在 *Target › Signing & Capabilities* 里选择你的 Team（`CODE_SIGN_STYLE = Automatic`）。

### 命令行

```bash
# 编译
xcodebuild -project PrettyShot.xcodeproj -scheme PrettyShot -configuration Debug \
  -derivedDataPath build build

# 运行
open build/Build/Products/Debug/PrettyShot.app

# 单元测试（渲染、打码、历史、快捷键规则、编辑器交互、坐标换算）
xcodebuild test -project PrettyShot.xcodeproj -scheme PrettyShot -destination 'platform=macOS'
```

### 重新生成工程文件（可选）

`PrettyShot.xcodeproj` 由脚本生成并提交在仓库中。增删源文件后：

```bash
python3 scripts/gen_xcodeproj.py      # 生成 project.pbxproj + 共享 scheme（ID 稳定，diff 最小）
# 或
xcodegen generate                      # 使用 project.yml
```

App 图标由 `scripts/make_app_icon.py`（Pillow）从品牌标记生成。

---

## 使用速查

| 位置 | 按键 |
|------|------|
| 全局 | ⌥⌘1 区域 · ⌥⌘2 窗口 · ⌥⌘3 全屏 · ⌥⌘H 历史 · ⌥⌘P Pin 最近一张（均可重映射） |
| 捕获 HUD | 拖拽选区 / 点击窗口 · Esc 取消 · 再按一次捕获快捷键也会取消 |
| Quick Overlay | ↩ 或 ⌘C 复制 · ⌘E 标注 · ⌘S 保存 · ⌘P Pin · Esc 关闭 · 拖动缩略图到其它 App |
| 编辑器 | V 选择 · A 箭头 · R 矩形 · O 椭圆 · T 文字 · N 计数 · C 裁剪 · P 像素化 · B 模糊 · ⌫ 删除所选 · ⌘Z / ⇧⌘Z · ⌘C 复制 · ⌘S 导出 |
| Pin | 拖动移动 · 悬停显示 透明度 / 尺寸 / 点击穿透 / 关闭 · Esc / ⌘W 关闭 |

复制或关闭 Overlay 后，焦点会回到截图前的 App，可以直接 ⌘V。

---

## 工程结构

```
PrettyShot/
  App/          入口、AppCoordinator（捕获→Overlay→编辑器/历史/Pin 的编排）、菜单栏 Popover (F1)
  Capture/      ScreenCaptureKit 服务、窗口列表、冻结帧 Capture HUD (F2)
  Overlay/      Quick Access Overlay (F3)
  Editor/       标注模型、EditorDocument（撤销/交互）、Renderer（预览与导出共用，一套绘制代码）、背景预设 (F4)
  History/      本地历史存储（PNG + index.json）与界面 (F5)
  Pin/          Pin 浮窗 (F6)
  Permissions/  屏幕录制权限状态与说明页 (F7)
  Hotkeys/      Carbon RegisterEventHotKey 全局热键、快捷键录制与校验
  Settings/     设置（通用 / 快捷键 / 权限 / 关于）
  Support/      Paper Bloom 主题、品牌标记、PNG/剪贴板、Toast、偏好
PrettyShotTests/  XCTest 单元测试
design/           设计稿（DESIGN.md、prototype.html、frames/）— 视觉与交互真源
```

- 全局热键使用 Carbon `RegisterEventHotKey`：**不需要辅助功能权限**，并能检测与其它 App 的冲突。
- 历史目录：`~/Library/Application Support/PrettyShot/History/`；Save 默认写入「下载」文件夹（可在设置中更改）。
- 未开启 App Sandbox（v0.1 需直接写入用户选择的文件夹）；启用了 Hardened Runtime。

与设计稿的差异见 [DEVIATIONS.md](DEVIATIONS.md)。

---

## 开源借鉴边界（Attribution boundaries）

PrettyShot 的全部代码为本仓库原创编写。以下项目仅作为**思路**参考，**没有复制任何源代码、资源或文案**：

| 项目 | 许可证（落盘情况） | 我们参考了什么 | 边界 |
|------|------------------|----------------|------|
| [DodoApps/dodoshot](https://github.com/DodoApps/dodoshot) | MIT | 原生 SwiftUI 截图工具的模块边界（捕获 / 标注 / Pin / 历史分层） | 架构思路，代码重写 |
| [Tracekit-Dev/openshots](https://github.com/Tracekit-Dev/openshots) | MIT | 「命名渐变预设 + padding / radius / shadow」的美化参数结构 | 结构思路；8 套背景为 PrettyShot 设计稿原创配色，Swift 重写 |
| [alexrett/simpleshot](https://github.com/alexrett/simpleshot) | MIT | 极简「渐变包裹截图」的产品思路 | 仅思路 |
| [xiangyizengdev/SnapDress](https://github.com/xiangyizengdev/SnapDress) | 未见 LICENSE 落盘 | — | **未查看/未使用其代码**，只知其公开的产品概念 |
| [Yonghero/Snapper](https://github.com/Yonghero/Snapper) | 未见 LICENSE 落盘 | — | 同上，**不拷贝代码** |
| [levskiy0/skreenme](https://github.com/levskiy0/skreenme) | 无源码可用 | — | **未使用** |

品牌：仅使用 **PrettyShot** 名称与 Paper Bloom 视觉语言（Bloom Rose `#E8A0A8`）。不使用 CleanShot 的商标、图形、口号、截图资产或其青绿/深铬配色；界面中的系统图标均来自 Apple SF Symbols。

---

## 状态与已知限制

- v0.1 MVP 代码完整，但本轮在 Linux 环境编写：**尚未在 macOS 上编译运行验证**（仅做了 Swift 语法检查）。首次在 Xcode 编译若有少量 API 细节报错，请参考 PR 说明。
- ad-hoc 签名下每次重编译可能需要重新授权屏幕录制（见上方签名说明）。

## License

[MIT](LICENSE) © 2026 PrettyShot contributors
