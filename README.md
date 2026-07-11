# Codex Usage Helper

A small macOS menu-bar app that shows remaining Codex usage for the 5-hour and weekly windows.

Version 1.0.1 supports the current ChatGPT desktop app. It does not modify ChatGPT, scrape the UI, or store account tokens. It starts ChatGPT's bundled Codex app-server on demand and sends `account/rateLimits/read`.

## Requirements

- Apple Silicon Mac running macOS 13 or later
- ChatGPT installed at `/Applications/ChatGPT.app`
- A signed-in ChatGPT account with Codex access

## Build

```bash
./Scripts/build.sh
```

The app is created at:

```text
build/Codex Usage Helper.app
```

The build script removes old build output first, so moving the source folder cannot leave stale Swift module caches behind.

## Run

```bash
./Scripts/run.sh
```

The menu-bar label refreshes automatically every 5 minutes. Clicking the menu-bar item opens the menu immediately; use the `Refresh` item or press `Control + Option + C` to refresh on demand.

## Package A Release

```bash
./Scripts/package.sh
```

The GitHub release ZIP is created in `dist/`. Build output and release archives are ignored by Git.

## Verify Without Opening The App

```bash
"build/Codex Usage Helper.app/Contents/MacOS/CodexUsageHelper" --print-usage
```

## Install A Downloaded Release

Unzip the release, move `Codex Usage Helper.app` to Applications, then open it. The app is ad-hoc signed rather than notarized, so macOS may require Control-clicking the app and choosing **Open** on first launch.
