# Codex Usage Helper

A tiny macOS menu-bar app that shows remaining Codex usage for the 5-hour and weekly windows.

It does not modify Codex, scrape the UI, or store account tokens. It starts Codex's local app-server on demand and sends `account/rateLimits/read`.

The app bundle includes a generated macOS icon at `Contents/Resources/AppIcon.icns`.

## Build

```bash
./Scripts/build.sh
```

The app is created at:

```text
build/Codex Usage Helper.app
```

## Run

```bash
./Scripts/run.sh
```

The menu-bar label refreshes automatically every 5 minutes. Clicking the menu-bar item opens the menu immediately; use the `Refresh` item or press `Control + Option + C` to refresh on demand.

## Verify Without Opening The App

```bash
"build/Codex Usage Helper.app/Contents/MacOS/CodexUsageHelper" --print-usage
```
