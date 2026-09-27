# PrettyShot v0.1 Mac MVP — 设计规范（非工程实现）

> **文档性质**：设计交付物 · 交互与视觉规范 · 供 Kin / 御前总管评审与工程参考  
> **明确声明：本文档与同目录 `prototype.html` 均为设计稿，不是生产代码，不是 Swift / AppKit 实现。**  
> **品牌**：PrettyShot（禁止 SoftShot / CleanShot 等混淆命名与商标资产）  
> **视觉语言**：「纸感光晕 · Paper Bloom」  
> **日期**：2026-09-27（JST） · 设计角色：设计师

---

## 0. 产品一句话

PrettyShot = Mac 截图 **标注 + 美化** 工具。MVP：区域 / 窗口 / 全屏捕获 → Quick Overlay 一键复制 → 标注 / 打码 → ≥8 原创背景 → 历史 → Pin 浮窗。  
本轮 **不做**：Recording Studio、Cloud、iPhone 同步。

---

## 1. 体验原则（锁定）

| # | 原则 | 设计含义 |
|---|------|----------|
| P1 | **Capture → Copy ≤ 3 步** | Overlay 上 **Copy** 是主 CTA；默认路径不强迫进编辑器 |
| P2 | **Beautify 永不挡住 Annotate** | 背景抽屉为次级面板；标注工具栏始终可达 |
| P3 | **权限失败可读** | 屏幕录制 / 辅助功能拒绝时，展示可读说明 + 打开系统设置 CTA；**禁止**静默黑屏 |

---

## 2. 信息架构（IA）

```
菜单栏图标 PrettyShot
 ├─ Popover（空闲）
 │   ├─ 捕获：区域 / 窗口 / 全屏（附快捷键提示）
 │   ├─ 历史 History
 │   └─ 设置 Settings
 ├─ Capture HUD（区域选择等）
 ├─ Quick Access Overlay（捕获后浮层）
 │   ├─ Copy（主） / Annotate / Save / Drag / Pin / Dismiss
 ├─ Editor（标注 + 背景抽屉 + Export/Copy）
 ├─ History Panel（空 / 有内容网格）
 ├─ Pin Window（浮窗：透明度 + 尺寸）
 └─ Permission Denied（权限拒绝态）
```

**主路径（快乐路径）**  
菜单栏 → 区域捕获 → Overlay → **Copy**（≤3 步到剪贴板）  
旁路：Overlay → Annotate → 标注 / 美化 → Export 或 Copy  
旁路：History → 重开 / Pin / 删除

---

## 3. 视觉语言「纸感光晕 · Paper Bloom」

### 3.1 色板（禁止 CleanShot 青绿深铬仿制）

| Token | Hex / 值 | 用途 |
|-------|----------|------|
| Overlay Chrome | `#1C1C1E` @ 88% + frosted | Overlay / HUD 深色毛玻璃 |
| Soft Radius | `14px` | Overlay 圆角 |
| **Bloom Rose**（强调） | `#E8A0A8` | 主 CTA、选中、焦点环 |
| Soft Mint（成功） | `#7EB8A8` | Copy 成功、已 Pin |
| Ivory 文字 | `#F5F2EC` | 深色表面上的正文 |
| Canvas | `#ECE8E1` | 编辑器画布暖灰 |
| Tool Rail | `#F7F4EE` | 浅色工具轨 |
| Charcoal Icon | `#2C2A28` | 浅轨上图标 |
| Border Soft | `rgba(255,255,255,0.12)` / `#E2DDD4` | 深/浅描边 |

### 3.2 字标与标记

- **Wordmark**：PrettyShot（Title Case，无空格变体）
- **Mark**：软圆角光圈（aperture）+ 一瓣 bloom 花瓣暗示 — 简洁 SVG，原创；见 `prototype.html` 内联 SVG
- 禁止使用 CleanShot 任何商标图形、口号、截图资产

### 3.3 背景预设方向板（≥8，原创名 + CSS 渐变）

| Key (EN) | 中文名 | CSS 方向（工程可实现为 Swift 渐变） |
|----------|--------|-------------------------------------|
| `paper-mist` | Paper Mist · 纸雾 | `linear-gradient(145deg, #F7F2EA 0%, #E8DFD4 48%, #D9CFC4 100%)` |
| `ink-wash` | Ink Wash · 墨洗 | `linear-gradient(160deg, #2A2E35 0%, #4A5560 45%, #8A9AA8 100%)` |
| `soft-bloom` | Soft Bloom · 柔瓣 | `linear-gradient(135deg, #F3D5D8 0%, #E8A0A8 40%, #C9B8D4 100%)` |
| `moss-quiet` | Moss Quiet · 苔静 | `linear-gradient(150deg, #1E2E28 0%, #3D5A4C 50%, #7EB8A8 100%)` |
| `dusk-lilac` | Dusk Lilac · 暮紫 | `linear-gradient(140deg, #2B2438 0%, #6B5B7A 50%, #C4B0D4 100%)` |
| `ceramic-white` | Ceramic White · 瓷白 | `linear-gradient(180deg, #FFFFFF 0%, #F5F2EC 60%, #E8E2D8 100%)` |
| `night-ink` | Night Ink · 夜墨 | `linear-gradient(160deg, #0E0F12 0%, #1C1C1E 55%, #3A3A3C 100%)` |
| `citrus-fog` | Citrus Fog · 柑雾 | `linear-gradient(145deg, #F6E7C8 0%, #E8C99A 45%, #D4B48A 100%)` |

背景抽屉内另含 **Padding / Radius / Shadow** 滑杆（原型为 mock；工程落真实渲染）。

---

## 4. 关键帧清单（原型可切换）

| ID | 帧名 | 设计要点 |
|----|------|----------|
| F1 | Menu Bar Popover（空闲） | Capture Region / Window / Full Screen + History + Settings；右侧快捷键 hint |
| F2 | Capture HUD | 全屏压暗 + 选区矩形 + 模式 chips（区域/窗口/全屏） |
| F3 | Quick Access Overlay | 缩略图；**Copy 主按钮**；Annotate / Save / Drag / Pin / Dismiss |
| F4 | Editor | 标注工具：箭头、矩形、椭圆、文字、计数、裁剪、马赛克、模糊；背景抽屉 ≥8；Export / Copy |
| F5 | History | 空态 + 有内容网格；重开 / 删除 / Pin |
| F6 | Pin Window | 浮窗裱框截图；透明度 + 尺寸控制 |
| F7 | Permission Denied | 可读文案 +「打开系统设置」；非黑屏 |

原型入口：`prototype.html`（左侧导航切换帧）。

---

## 5. 状态设计

### 5.1 空态（History）
插画式纸感空画框 + 「还没有截图」+ CTA「捕获区域 ⌥⌘1」（假设快捷键，见下）。

### 5.2 错误 / 一般失败
轻 toast：象牙底 + 炭色字；可关闭；不阻断 Overlay 主路径。

### 5.3 未授权（Permission Denied）— P3
- 标题：需要屏幕录制权限  
- 正文：说明为何需要、不会上传云端（本轮无 Cloud）  
- 主按钮：打开「系统设置 › 隐私与安全性 › 屏幕录制」  
- 次按钮：稍后再说  
- **禁止**无文案黑屏或假捕获成功

### 5.4 成功
Copy 成功：按钮短暂变 Soft Mint +「已复制」；可配轻 haptic（工程）。

---

## 6. 快捷键假设（设计假设，非系统事实）

> ⚠️ **以下为建议默认，冲突可改，用户可在 Settings 重映射。**  
> **禁止**在文案中声称占用系统截图键 `⌘⇧3` / `⌘⇧4` / `⌘⇧5`。

| 建议快捷键 | 动作 | 备注 |
|------------|------|------|
| `⌥⌘1` | 区域捕获 Region | 冲突感知；可改 |
| `⌥⌘2` | 窗口捕获 Window | 同上 |
| `⌥⌘3` | 全屏 Full Screen | 同上 |
| `⌥⌘H` | 打开 History | 同上 |
| `⌥⌘P` | Pin 最近一张 | 同上 |
| `Esc` | 取消捕获 / 关闭 Overlay | 标准 |

Settings 中展示「当前绑定」+「恢复默认」+ 冲突警告（若与已注册全局快捷键冲突）。

---

## 7. 组件备注（给工程，非实现）

| 组件 | 设计约束 |
|------|----------|
| Menu Popover | 宽约 280–300pt；行高舒适；快捷键右对齐次级色 |
| Overlay | 毛玻璃 `#1C1C1E@88%`、圆角 14、Bloom Rose 主 CTA；Copy 视觉权重最高 |
| 工具轨 | 浅 `#F7F4EE`；图标 20–22pt；选中态 bloom 底或描边 |
| 背景抽屉 | 从右侧或底部滑入；不遮挡工具轨整条；关闭后标注继续 |
| History 卡片 | 圆角 10；hover 显示 Pin / 删除；键盘可聚焦 |
| Pin 窗 | 可拖；阴影柔和；控制条 hover 才显（可选） |
| 权限屏 | 居中卡片；系统设置 deep link（工程实现） |

**交互优先级**：Copy > Annotate > Beautify（背景）> Pin / History。

---

## 8. 验收标准映射（Design AC）

| ID | 验收意图（设计侧可验证） | 原型/文档证据 |
|----|--------------------------|---------------|
| **AC-M1** | 三种捕获入口可见（区域/窗口/全屏） | F1 Popover + F2 HUD chips |
| **AC-M2** | Overlay 主路径 Copy ≤3 步可达 | F3 Copy 为主 CTA；DESIGN P1 |
| **AC-M3** | 标注工具齐全（≥ 箭头/矩形/椭圆/文字/计数/裁剪/像素/模糊） | F4 工具轨 |
| **AC-M4** | ≥8 原创背景 + padding/radius/shadow mock | F4 抽屉；§3.3 |
| **AC-M5** | History 空态 + 网格 + 重开/删/Pin | F5 |
| **AC-M6** | Pin 浮窗 + 透明度/尺寸 | F6 |
| **AC-M7** | 权限拒绝可读、非黑屏 | F7；P3 |
| **AC-Brand** | PrettyShot 字标 + Paper Bloom 色板；无 CleanShot 商标/口号/青绿仿制 | 全文 + prototype |

---

## 9. Out List（本轮明确不做）

- Recording / Studio 录屏产品线  
- Cloud 同步 / 账号 / 分享链接  
- iPhone / Continuity 捕获  
- CleanShot 商标、资产、口号、色板仿制  
- SoftShot 或其它混淆品牌名  
- 生产 Swift 代码、改 GitHub 仓库、克隆 `KinGao294/prettyshot`  
- 将设计稿中的快捷键宣称为「系统已注册事实」

---

## 10. 非工程实现声明

```
本目录 /workspace/prettyshot-design/ 内全部文件为设计交付：
DESIGN.md · prototype.html · README.md · NOTION-HANDOFF.md · frames/*
≠ PrettyShot 应用源码
≠ 可编译的 Mac 客户端
工程实现由独立工程里程碑负责；设计稿仅约束体验与视觉。
```

---

*PrettyShot · 纸感光晕 Paper Bloom · v0.1 Mac MVP Design · 设计师 · 2026-09-27 JST*
