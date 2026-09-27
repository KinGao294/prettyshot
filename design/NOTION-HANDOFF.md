# PrettyShot v0.1 Mac MVP — 设计交接（Notion 粘贴稿）

> 角色：设计师 · 品牌：**PrettyShot**（禁止 SoftShot / CleanShot 商标混用）  
> 视觉语言：**纸感光晕 · Paper Bloom**  
> 日期：2026-09-27 JST  
> 本地原型：`/workspace/prettyshot-design/prototype.html`  
> （粘贴到 Notion 后可将此路径改为附件或内网预览链接）

---

## 结论

PrettyShot v0.1 Mac MVP 的设计目标是：**截完就能美、标完就能抄**——主路径「捕获 → Quick Overlay → **Copy**」控制在 **≤3 步**；标注工具栏永远可达，背景美化只做次级抽屉；权限失败必须可读，禁止静默黑屏。  
本轮交付为 **设计稿 only**（`DESIGN.md` + 可交互 `prototype.html`），**不是** Swift 工程实现，也未改动任何代码仓库。

---

## 原则

1. **Capture → Copy ≤ 3 步** — Overlay 上 Copy 是主 CTA。  
2. **Beautify 永不挡住 Annotate** — 背景抽屉次级；工具轨始终在。  
3. **权限失败可读** — 文案 + 打开系统设置；禁止无说明黑屏。

---

## 主路径

```
菜单栏 PrettyShot
  → 捕获区域 / 窗口 / 全屏
    → Capture HUD（选区）
      → Quick Access Overlay
        → 【主】Copy（结束）
        → 【旁】Annotate → Editor（标注 + 背景）→ Export / Copy
        → Pin / Save / Dismiss
  → History（重开 / 删 / Pin）
  → 权限拒绝态（若未授权）
```

---

## 关键帧清单

| ID | 帧 | 要点 |
|----|-----|------|
| F1 | Menu Bar Popover | 区域 / 窗口 / 全屏 + History + Settings；快捷键 hint |
| F2 | Capture HUD | 压暗 + 选区 + 模式 chips |
| F3 | Quick Overlay | 缩略图；**Copy 主按钮**；Annotate / Save / Drag / Pin / Dismiss |
| F4 | Editor | 8 种标注工具 + ≥8 背景预设 + Padding/Radius/Shadow + Export/Copy |
| F5 | History | 空态 + 网格；重开 / 删除 / Pin |
| F6 | Pin Window | 浮窗裱框；透明度 + 尺寸 |
| F7 | Permission Denied | 可读说明 + 打开系统设置 |

交互原型：用浏览器打开  
`file:///workspace/prettyshot-design/prototype.html`  
或 `cd /workspace/prettyshot-design && python3 -m http.server 8765` → `http://127.0.0.1:8765/prototype.html`

---

## 快捷键假设（非系统事实）

> 建议默认，冲突可改，Settings 可重映射。  
> **不占用**系统截图键 `⌘⇧3` / `⌘⇧4` / `⌘⇧5`。

| 键 | 动作 |
|----|------|
| ⌥⌘1 | 区域 Region |
| ⌥⌘2 | 窗口 Window |
| ⌥⌘3 | 全屏 Full Screen |
| ⌥⌘H | History |
| ⌥⌘P | Pin 最近一张 |
| Esc | 取消 / 关闭 |

---

## 背景包方向（≥8 · 原创名 + CSS）

| Key | 中文感 | 渐变方向（摘要） |
|-----|--------|------------------|
| paper-mist | 纸雾 | `#F7F2EA → #E8DFD4 → #D9CFC4` |
| ink-wash | 墨洗 | `#2A2E35 → #4A5560 → #8A9AA8` |
| soft-bloom | 柔瓣 | `#F3D5D8 → #E8A0A8 → #C9B8D4` |
| moss-quiet | 苔静 | `#1E2E28 → #3D5A4C → #7EB8A8` |
| dusk-lilac | 暮紫 | `#2B2438 → #6B5B7A → #C4B0D4` |
| ceramic-white | 瓷白 | `#FFFFFF → #F5F2EC → #E8E2D8` |
| night-ink | 夜墨 | `#0E0F12 → #1C1C1E → #3A3A3C` |
| citrus-fog | 柑雾 | `#F6E7C8 → #E8C99A → #D4B48A` |

强调色 **Bloom Rose** `#E8A0A8` · 成功 **Soft Mint** `#7EB8A8` · Overlay 毛玻璃 `#1C1C1E@88%` · 画布 `#ECE8E1` · 工具轨 `#F7F4EE`。

字标：**PrettyShot**；标记 = 软圆角光圈 + bloom 花瓣暗示（原创 SVG，见原型）。

---

## 状态

- **空态（History）**：纸感空框 +「还没有截图」+ CTA 捕获区域  
- **错误**：轻 toast，不阻断主路径  
- **未授权**：居中卡片说明屏幕录制权限 + 打开系统设置（AC-M7 / P3）  
- **成功**：Copy 按钮短暂变 mint「已复制」

---

## 给工程的规则

1. Copy 视觉与交互权重最高（Overlay & Editor）。  
2. 背景抽屉不得盖住整条标注工具轨。  
3. 权限拒绝必须有 UI 文案，禁止假成功 / 黑屏。  
4. 快捷键以 Settings 可配置为准；勿写死声称已注册系统键。  
5. 品牌仅 **PrettyShot** + Paper Bloom 色板；禁止 CleanShot 商标/资产/口号/青绿深铬仿制。  
6. 本目录文件 **≠ 可编译客户端**；工程另开里程碑。

验收映射：AC-M1 三捕获入口 · AC-M2 Overlay Copy≤3 步 · AC-M3 标注工具齐全 · AC-M4 ≥8 背景 · AC-M5 History · AC-M6 Pin · AC-M7 权限可读 · AC-Brand PrettyShot / Paper Bloom。

---

## 明确不做

- Recording Studio / 录屏产品线  
- Cloud / 账号 / 分享链接  
- iPhone / Continuity  
- CleanShot 或 SoftShot 品牌混用  
- 生产 Swift 代码、克隆或修改 `https://github.com/KinGao294/prettyshot`  
- 将设计假设快捷键宣称为系统事实  

---

## 附件索引

| 文件 | 说明 |
|------|------|
| `/workspace/prettyshot-design/DESIGN.md` | 完整中文设计规范 |
| `/workspace/prettyshot-design/prototype.html` | 七帧交互原型 |
| `/workspace/prettyshot-design/README.md` | 如何打开 / 范围声明 |
| `/workspace/prettyshot-design/frames/` | 可选关键帧 PNG |

---

*PrettyShot · 纸感光晕 · v0.1 Mac MVP Design Handoff · 设计师*
