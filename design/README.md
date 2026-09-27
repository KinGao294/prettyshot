# PrettyShot v0.1 — Design Deliverables Only

> **非工程实现** · Design handoff for Kin review · Mac MVP visual & interaction specs  
> Brand: PrettyShot · Visual language: **纸感光晕 · Paper Bloom**  
> Owner role: 设计师 (product designer)

## What's in this folder

| File | Purpose |
|------|---------|
| `DESIGN.md` | Full Chinese design spec: principles, IA, frames, states, shortcuts, backgrounds, AC, Out list |
| `prototype.html` | Single-file interactive multi-screen prototype (Mac chrome aesthetic) |
| `NOTION-HANDOFF.md` | Notion-ready Chinese paste body for handoff |
| `frames/` | Optional PNG captures F1–F7 (generated via headless Chromium) |

## How to open the prototype

```bash
cd /workspace/prettyshot-design
python3 -m http.server 8767
```

Then open in browser:

```
http://127.0.0.1:8767/prototype.html
```

Or simply double-click / open `prototype.html` directly in Chrome / Safari / Arc (file:// works; some fonts may differ).

## Design-only scope

- **Included:** visual language, IA, key-frame UI, interaction notes, shortcut *assumptions*, CSS gradient background presets, component notes for engineering.
- **Not included:** Swift / AppKit / SwiftUI code, production app binary, repo clones, CleanShot trademarks/assets/slogans, Recording Studio, Cloud, iPhone sync.
- **Do not** treat this folder as source of truth for implementation APIs — engineering owns that.

## Brand reminder

Never use CleanShot X branding, teal chrome clones, or their slogans. Learn interaction *ideas* from peers mentally; invent PrettyShot's own Paper Bloom language.

## Review checklist for 御前总管

1. Open `prototype.html` → walk all 7 frames via left nav  
2. Skim `DESIGN.md` AC-M1–M7 + Brand  
3. Paste `NOTION-HANDOFF.md` into Notion when ready  

---

*PrettyShot © design draft · v0.1 Mac MVP · 2026-09-27 JST*
