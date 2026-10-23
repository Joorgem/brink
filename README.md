# Brink

[![CI](https://github.com/semihtalii/brink/actions/workflows/ci.yml/badge.svg)](https://github.com/semihtalii/brink/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/semihtalii/brink?include_prereleases)](https://github.com/semihtalii/brink/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)](#requirements)
[![Windows 10/11](https://img.shields.io/badge/Windows-10%2F11-0078D4)](#windows)
[![Windows build](https://github.com/semihtalii/brink/actions/workflows/windows.yml/badge.svg)](https://github.com/semihtalii/brink/actions/workflows/windows.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**Know when you're on the brink.** A tiny menu bar app that shows your
**Claude Code**, **Codex** and **Cursor** usage limits at a glance, for every
account you use, and, on macOS, **which project spent them**. **For macOS and Windows.**

On macOS, Brink is an icon in the menu bar, with the usage of the account you pick next to it.
Click it and a popover lists each account's session and weekly limits with reset
times. Nothing else stays open: the popover is built when you click and released
when it closes.

## Multiple accounts (macOS)

Add up to **5 accounts per provider** with the **+** next to each provider in the popover. The
list updates as soon as you add, rename or remove one.

- **Claude Code / Codex:** each extra account uses its own login folder, so all of
  them stay signed in at once. Brink shows the command to sign in once, e.g.
  `CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude` or
  `CODEX_HOME="$HOME/.codex-work" codex login`. An alias makes it painless:
  `alias claude-work='CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude'`.
- **Cursor:** cursor-agent keeps one login, so extra accounts take the
  `WorkosCursorSessionToken` cookie from cursor.com, stored only on your Mac (0600).

Brink never refreshes tokens itself (that could sign you out of the CLI). Each
CLI keeps its own token fresh while you use it; an account left unused for a long
time shows a sign-in hint until you open its CLI again.

<p align="center">
  <img src="docs/demo.gif" width="720" alt="Brink in use — move to the right edge, the panel slides out, hover a ring for details">
</p>
<p align="center">
  <img src="docs/screenshot.png" width="560" alt="Brink — edge panel with Claude and Codex usage rings and the Claude detail card">
</p>

## Features

- **What used it** — break the limit down by project, over the current session, the
  week, this month or all time. Built from the transcripts Claude Code already
  writes; reads token counts only, never message content. macOS only for now.
- Three looks: **Black**, **Liquid Glass** and **System**. On macOS 26+ the glass is
  Apple's real, adaptive Liquid Glass (`.glassEffect`): it turns light or dark from
  what's behind it, so type stays legible over a white web page and a dark wallpaper
  alike. On macOS 13–15 it falls back to a frosted `NSVisualEffectView` blur.
- Notch-style tab that flares into the screen edge; rings scale on hover; the detail card glides between rings
- **Notifications** when a limit fills up — and again the moment it resets (scheduled for the reset time, so it arrives even if the app is idle)
- **10 languages** — follows your macOS language automatically (English, Türkçe, Deutsch, Français, Español, Português (Brasil), Italiano, 日本語, 简体中文, 한국어); override in the menu
- Rings for each provider, colored by usage (green → yellow → red; Claude ring in Claude orange)
- Detail card with **Current session**, **All models** and per-model weekly limits (e.g. Fable / Opus / Sonnet)
- Auto-refresh every 2 minutes, manual refresh from the context menu
- **Launch at login** toggle (System Settings → Login Items compatible)
- Works with whatever CLIs you already have installed — no API keys, no accounts

## Requirements

- **macOS** 13 Ventura or later, Apple Silicon or Intel (the DMG is a universal binary) — or **Windows** 10 (1809+) / 11 x64, see [Windows](#windows)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex CLI](https://github.com/openai/codex) and/or [Cursor CLI](https://cursor.com/cli) (`cursor-agent login`) — whichever you use, logged in
- To build from source: Xcode Command Line Tools (`xcode-select --install`)

## Install

### Download

Grab `Brink.dmg` from the [latest release](../../releases/latest), open it and
drag **Brink** to **Applications**.

Or with Homebrew (from [this tap](https://github.com/semihtalii/homebrew-brink); Brink isn't in `homebrew-cask` yet — that needs notarization first):

```bash
brew tap semihtalii/brink
brew trust semihtalii/brink     # Homebrew 6+ asks this once for third-party taps
brew install --cask brink
```

The cask strips the quarantine flag for you, so the Gatekeeper step below isn't needed.

The app is not yet notarized (no Apple Developer account yet), so macOS blocks
the first launch. On **macOS 15 Sequoia and later** the old right-click → Open
trick no longer works; do this instead:

1. Double-click Brink once — macOS says it can't be opened. Click **Done**.
2. Open *System Settings → Privacy & Security*, scroll down to **Security** and
   click **Open Anyway** next to Brink (the button only shows for about an hour
   after the blocked attempt; launch it again if it's gone).
3. Confirm with your password. You only do this once.

Or skip the dialogs entirely from a terminal:

```bash
xattr -d com.apple.quarantine /Applications/Brink.app
```

Every release ships a `SHA256SUMS` file and a GitHub build attestation, so you
can check the DMG came from this repo's CI:
`gh attestation verify Brink.dmg -R semihtalii/brink`.

### Build from source

```bash
git clone https://github.com/semihtalii/brink.git
cd Brink
./build.sh
open dist/Brink.app
```

`build.sh` produces both `dist/Brink.app` and `dist/Brink.dmg`.

## Windows

Brink for Windows is a native C# / WPF (.NET 8) port with the same behaviour:
edge strip, rings, detail card, notifications, 10 languages, launch at login.
Themes are **Black** and **System** (follows the Windows light/dark app theme;
there is no Liquid Glass on Windows).

**Install:** grab `Brink-Windows-x64.zip` from the
[latest release](../../releases/latest), unzip, run `Brink.exe`. It's a single
self-contained file — no .NET install needed (x64 only for now). The exe is not
code-signed yet, so SmartScreen may warn on first run: **More info → Run anyway**.

A `winget install SemihTali.Brink` manifest is prepared in
[`packaging/winget/`](packaging/winget/) and will work once it's merged into winget-pkgs.

**Uninstall:** quit Brink, delete `Brink.exe` and `%APPDATA%\Brink\`. If you
enabled *Launch at login*, turn it off first (it's a `HKCU\...\Run` entry).

**Credentials it reads** (never written, never sent anywhere but the vendor):

| Provider | Where |
|---|---|
| Claude Code | `%USERPROFILE%\.claude\.credentials.json`, else Credential Manager `Claude Code-credentials` |
| Codex CLI | `%CODEX_HOME%\auth.json` or `%USERPROFILE%\.codex\auth.json` |
| Cursor CLI | `%USERPROFILE%\.cursor\cli-config.json`, else Credential Manager `cursor-access-token` |

Settings and an error log live in `%APPDATA%\Brink\`. Source is in
[`windows/`](windows/); build with `dotnet build windows/Brink.csproj -c Release`.

## First launch

macOS will ask once:

> *Brink wants to use your confidential information stored in "Claude Code-credentials" in your keychain.*

Click **Always Allow**. This is Claude Code's own login token; Brink reads it
to ask Anthropic for your usage numbers. It is never sent anywhere else.

## Usage

| Action | Result |
|---|---|
| Move mouse to right edge | Panel slides out |
| Hover a ring | Detail card |
| Right-click panel or card | **Refresh now** · **Providers** · **Appearance** · **Language** · **Launch at login** · **Notifications** · **Test notification** · **Quit Brink** |
| Move the mouse far from the edge | Panel folds away by itself |

Providers you're not signed in to are hidden. If nothing is signed in, a single
**?** ring tells you what to install; turn a provider on under **Providers** to
see a DEMO ring anyway.

**Uninstall (macOS):** quit Brink, delete `/Applications/Brink.app` and
`~/Library/Application Support/Brink/`. Nothing else is written.

## How it works

- **Claude** — reads the OAuth access token Claude Code stores in the macOS
  Keychain (`Claude Code-credentials`) or in `~/.claude/.credentials.json`, then
  calls `api.anthropic.com/api/oauth/usage` — the same request Claude Code makes
  for its `/usage` command.
- **Codex** — reads the token in `~/.codex/auth.json` and calls
  `chatgpt.com/backend-api/wham/usage`.
- **Cursor** — reads the Cursor CLI session token (Keychain `cursor-access-token`)
  and the user id from `~/.cursor/cli-config.json`, then calls
  `cursor.com/api/usage-summary`.

## What used it

The limit tells you how much is gone. Brink also answers the follow-up: *which
project spent it?*

Under the Claude card there's one quiet line — `This session · brink · 4.1%` —
that expands into a per-project breakdown. It works by pairing each observed
rise in your limit with the turns that happened in the same interval, weighting
them by tokens, and splitting the rise between the projects involved. Nothing is
estimated from a price table; only what actually moved the number is assigned.

Four ranges. **Session** and **Week** are Anthropic's own limit windows, so their
percentages are percent *of the limit* and match the card. **Month** (calendar
month) and **All** have no limit behind them — Anthropic resets on five hours and
seven days, not monthly — so they show each project's share *of the work in that
range*. The list says so under the rows, and these two survive a limit reset,
reaching back as far as the transcripts do.

Consumption that no local session explains — claude.ai, another machine, a
background job — is shown as **Elsewhere** rather than hidden or spread around.

**What it reads.** Claude Code already writes a transcript per session under
`~/.claude/projects`. Brink opens those files and takes *only* these fields:

```
timestamp · cwd · gitBranch · sessionId · requestId · version
message.model · message.usage.{input,output,cache_read,cache_creation}_tokens
```

It never reads `message.content`, tool results, or attachments, and never
descends into the `tool-results/` and `subagents/` directories. Transcripts can
contain secrets an agent read from a project; none of that is touched, stored or
sent. The database (`~/Library/Application Support/Brink/agentcost.sqlite`) holds
token counts, model names, branch names and project paths — nothing else, and it
never leaves the machine.

Sessions started in subfolders of one repository are grouped by their git root,
so a project shows up once rather than as `Sources`, `docs` and `windows`.

### Security & privacy

- Tokens are only ever sent to Anthropic's / OpenAI's own API hosts over HTTPS.
  There is no telemetry, no third-party server.
- Brink caches only the **short-lived access token** and its expiry in
  `~/Library/Application Support/Brink/credentials.json` (mode `0600`) so the
  Keychain prompt appears once rather than every refresh. It never stores or
  uses refresh tokens, and it never refreshes tokens on your behalf — so it
  cannot log you out of Claude Code.
- When the cached token expires, Brink re-reads Claude Code's own store.
  Opening Claude Code once is enough to get a fresh token.

### Caveats

- These usage endpoints are **not official, documented APIs**. If Anthropic or
  OpenAI change the response shape, the parsers in `ClaudeProvider.swift` /
  `CodexProvider.swift` will need a small update. PRs welcome.
- The panel attaches to the main display only (v1).

## When not to use this

- You want numbers inside the terminal or a status line → look at CLI tools such as
  [llmquota](https://github.com/0xNyk/llmquota) or [ccusage](https://github.com/ryoppippi/ccusage).
- You need token-level cost accounting → this only shows the percentage windows
  the vendors expose.
- You're on Linux → Brink is macOS and Windows only.

## How Brink compares

| | Brink | [CodexBar](https://github.com/steipete/CodexBar) | [ClaudeBar](https://github.com/tddworks/ClaudeBar) | [ccusage](https://github.com/ryoppippi/ccusage) |
|---|---|---|---|---|
| Form | Edge panel, hidden until you need it | Menu bar item | Menu bar item | Terminal report |
| Platforms | **macOS + Windows** | macOS 14+ (community Windows port) | macOS | Anywhere with Node |
| Providers | Claude Code, Codex, Cursor | 60+ | Claude Code | Claude Code |
| Setup | Open the app | Open the app | Open the app | Node + npm |
| Needs API key | No | No | No | No |
| Size / scope | Small on purpose | Big, many options | Medium | CLI |

CodexBar is the most complete macOS monitor; pick it if you want dozens of
providers in the menu bar. Brink is for people who want nothing in the menu bar
at all, and the same app on their Windows machine.

## Project layout

```
windows/                      Brink for Windows (C# / WPF, .NET 8) — see windows/README.md
Package.swift                 Swift Package (macOS 13+)
build.sh                      build → .app + .dmg
Sources/Brink/
  main.swift                  entry point (accessory app, no Dock icon)
  PanelController.swift       edge panel + detail card windows (NSPanel)
  Views.swift                 SwiftUI: rings, strip, detail card
  Models.swift                data model, color scale, refresh store
  Theme.swift                 Black / Liquid Glass / System palettes + blur surface
  LaunchAtLogin.swift         SMAppService wrapper
  Notifier.swift              limit-reached / reset notifications (UserNotifications)
  L10n.swift                  localization lookup + language override
  Resources/                  provider logos, <lang>.lproj/Localizable.strings
  ClaudeProvider.swift        Claude usage source
  CodexProvider.swift         Codex usage source
  CursorProvider.swift        Cursor usage source
```

Adding a provider (Gemini CLI, Copilot, …) means implementing the
`UsageProvider` protocol and appending it to the list in `main.swift`.
Adding a language is one file: copy `Resources/en.lproj/Localizable.strings`
to `<code>.lproj/`, translate the right-hand side, and add the code to
`L10n.available` and `build.sh`'s `CFBundleLocalizations` (and mirror it in
`windows/Resources/Strings/` — same keys, same format).

For design work or screenshots, `BRINK_PREVIEW=1 dist/Brink.app/Contents/MacOS/Brink`
starts the app expanded with the first card open.

## Credits

The edge-panel design is based on a concept shared by
[@hivinz_](https://x.com/hivinz_) —
[original post](https://x.com/hivinz_/status/2092996055248126353).
Brink is an independent, open-source implementation of that idea; all code is
original. Claude and OpenAI logos belong to Anthropic and OpenAI respectively and
are used only to identify each provider.

## License

[MIT](LICENSE) © Semih Tali
