# AI Usage — Development Guide

The product is named **AI Usage** (`AI Usage.app`); the Xcode project, targets,
bundle ids, and internal identifiers keep the original **ClaudeUsage** name so
existing keychain items, defaults, and widget registrations stay valid.

macOS menu bar app + desktop widget showing AI plan usage (Claude, Gemini/Antigravity)
for multiple accounts. This doc is the playbook for making changes **and making sure
they actually show up** — widgets on macOS are aggressively cached and will silently
show stale builds if you skip steps.

---

## Project layout

```
ClaudeUsageApp/
├── project.yml            # xcodegen spec — bundle ids, versions, entitlements. EDIT THIS, not the .xcodeproj
├── App/
│   ├── main.swift         # AppDelegate: status item, KeyablePanel (borderless popover), account actions, URL scheme handler
│   └── UsagePanel.swift   # SwiftUI menu-bar panel: rings grid, account detail, Add/Remove, VisualEffectView background
├── Widget/
│   └── ClaudeUsageWidget.swift  # @main widget: AppIntentConfiguration (kind "AIUsageRings"), timeline provider, account-picker intent, small/medium/large layouts
└── Shared/                # compiled into BOTH app and widget targets (see project.yml sources)
    ├── Models.swift       # StoredAccount, AccountUsage, Snapshot (the app↔widget data contract)
    ├── Providers.swift    # AIProvider protocol + ClaudeProvider + GeminiProvider (API calls, token refresh)
    ├── ProviderMarks.swift# Brand palette, ProviderMark glyphs, ProviderTile (circle), RingGauge, WidgetBackground
    ├── WidgetCards.swift  # HeroCard (small), MiniCard (medium), WideCard (large)
    ├── Keychain.swift     # account storage (service "ClaudeUsageWidget", account "provider:email")
    └── OAuthLoopback.swift# PKCE loopback flow for Gemini/Antigravity consent
```

**Which file for which change:**

| Change | File(s) |
|---|---|
| Menu-bar panel look/behaviour | `App/UsagePanel.swift` (+ `App/main.swift` for window/anchoring) |
| Widget layout/cards | `Shared/WidgetCards.swift`, `Widget/ClaudeUsageWidget.swift` |
| Colors, icons, rings | `Shared/ProviderMarks.swift` |
| Usage APIs / new provider | `Shared/Providers.swift` |
| Snapshot schema (app↔widget) | `Shared/Models.swift` — keep decoding backward-compatible |
| Bundle ids, versions, entitlements, plist | `project.yml`, then `xcodegen generate` |

---

## Build & install — the full ritual

Run from `ClaudeUsageApp/`. **Do all steps, every time.** Skipping any one of them
is the #1 cause of "my change isn't showing".

```bash
# 0. BUMP CFBundleVersion in project.yml (BOTH occurrences — app + widget).
#    chronod dedupes widget descriptors by version: same version ⇒ your new
#    widget config/UI is silently ignored. Bump on EVERY build you intend to install.

# 1. Regenerate the Xcode project if project.yml changed
xcodegen generate

# 2. Build
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage \
  -configuration Release -derivedDataPath build build

# 3. Install (kill first so the binary isn't busy)
killall "AI Usage" 2>/dev/null
rm -rf "/Applications/AI Usage.app"
cp -R "build/Build/Products/Release/AI Usage.app" /Applications/

# 4. Re-register with LaunchServices — xcodebuild registered the BUILD-DIR copy,
#    not /Applications, so without this the system may resolve the wrong path
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "/Applications/AI Usage.app"

# 5. Relaunch app + restart the widget daemon
open "/Applications/AI Usage.app"
killall chronod    # forces widget re-render; harmless, it respawns
```

**Verify it took:**

```bash
plutil -p "/Applications/AI Usage.app"/Contents/Extensions/ClaudeUsageWidget.appex/Contents/Info.plist | grep BundleVersion
pluginkit -mv | grep -i claude     # one row, pointing at /Applications, fresh timestamp
```

If widget visuals still look stale after this: **remove the widget from the desktop
and re-add it from the gallery** — chronod also caches rendered frames per placed
instance.

---

## The cache stack (why changes don't reflect)

Three layers cache the widget independently; a change must clear all three:

1. **LaunchServices** — maps bundle id → path. Fix: `lsregister -f` (step 4).
2. **chronod descriptor DB** — widget kind, families, configurability, intents.
   Keyed by *(bundle id, CFBundleVersion)*. Fix: **version bump** (step 0) + `killall chronod`.
   The DB itself (`~/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql`)
   is TCC-protected — you cannot delete it from a normal shell.
3. **Rendered frames per placed widget** — fix: remove + re-add the widget.

### Nuclear option: poisoned descriptor

2026-07-04 incident: after a bad build, **every** render (desktop, gallery preview,
even a diagnostic `Color.red` view) was a solid black rectangle; the timeline provider
was never called; no crash logs. No amount of rebuilding/version-bumping fixed it
because chronod kept serving the poisoned cached descriptor.

**The only fix: change the widget extension's bundle id (and the widget `kind` string).**
That's why they are now `dev.manishkumar.claudeusage.usagewidget` / `"AIUsageRings"`
(originally `.widget` / `"AIUsageWidget"`). If black-everything ever returns, rename again.

---

## Widget rules (macOS 26 / Tahoe)

- **Pure SwiftUI colors only.** WidgetKit archives the view tree and renders it
  out-of-process. Custom closure-based `NSColor(name:) { … }` dynamic colors are a
  black-render risk. Theme-adaptive surfaces: `Color.primary.opacity(…)` or a small
  `@Environment(\.colorScheme)` view (`WidgetBackground` in ProviderMarks.swift).
- **Configurable widget** (`AppIntentConfiguration` + `SelectAccountIntent`): works,
  but any change to the intent/entities requires the version bump or the
  "Edit AI Usage" menu won't update. Static→AppIntent with the *same kind* keeps
  placed widgets alive.
- **Families/padding**: small 12pt uniform — this makes the 22pt circle icon
  *concentric* with the widget's corner radius (**measured 23pt** on Tahoe:
  capture the widget window and count pixels; don't estimate). Inset for a
  corner-hugging circle = cornerRadius − circleRadius = 23 − 11 = 12.
  Medium 13, large 13 horizontal / 10 vertical. `.contentMarginsDisabled()`
  is on, so these paddings are the real margins.
- **HeroCard layout is overlay-based, keep it that way**: if the small widget's
  content lives in a VStack that's taller than the widget, SwiftUI overflows the
  outer padding symmetrically — the header rendered at 3.5pt from the top while
  padding said 10. Header (topLeading) and caption (bottom) are `.overlay`s on a
  full-size ZStack, so they pin to the padded bounds and can never overflow.
- **Verify layout empirically, not by eyeball**: desktop widgets are real windows.
  Find them: CGWindowListCopyWindowInfo → owner "Notification Centre", name
  "AI Usage"; capture one with `screencapture -l<windowID> -x -o out.png`
  (works even on another Space), then measure pixels (@2x). Note: widgets on an
  inactive Space render desaturated/monochrome — that's normal, not a bug.
- **Data**: widget reads `~/Library/Application Support/ClaudeUsage/snapshot.json`
  (written by the app on every refresh). Sandboxed access via the
  `temporary-exception.files.home-relative-path.read-only` entitlement in project.yml
  + `getpwuid` real-home resolution in `Snapshot.fileURL`. If the widget shows the
  onboarding placeholder, the snapshot is missing/unreadable — run the app once.

## Panel rules

- The panel is a borderless `KeyablePanel`, **not** NSMenu/NSPopover. Background =
  `VisualEffectView(.menu)` + `Color(nsColor: .windowBackgroundColor).opacity(0.55)`
  scrim. The scrim is required: raw vibrancy samples whatever window is behind and
  washes out grey (the "Teams menu" comparison).
- Panel changes are app-side only: build + reinstall + relaunch is enough
  (no chronod/version dance) — but bump the version anyway out of habit.

---

## Testing without clicking around

```bash
# Open the panel programmatically (it auto-dismisses on focus loss — screenshot fast)
open "claudeusage://open"; sleep 1.5; screencapture -x /tmp/d1.png /tmp/d2.png  # one file per display

# Toggle dark/light to check both appearances
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'

# Render widget cards in isolation (no WidgetKit) — catches layout bugs instantly.
# Compile Shared/Models.swift + ProviderMarks.swift + WidgetCards.swift with a tiny
# @main that feeds Snapshot.load() into ImageRenderer and writes PNGs.
# Sizes: small 158×158, medium 338×158, large 338×354.

# Widget diagnostics
pluginkit -mv | grep -i claude                     # registration
log show --last 5m --predicate 'process == "ClaudeUsageWidget"'   # extension logs
```

## Versions & identity (current)

| | |
|---|---|
| App bundle id | `dev.manishkumar.claudeusage` |
| Widget bundle id | `dev.manishkumar.claudeusage.usagewidget` |
| Widget kind | `AIUsageRings` |
| CFBundleVersion | `7` (bump on every install!) |
| CFBundleShortVersionString | widget `1.1` |
| URL scheme | `claudeusage://open?account=<provider:email>` |
| Team | V4G7W2HGMF |
