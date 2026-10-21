# sTools

A Mac app for Minecraft: Java Edition speedrunners — six tools in one elegant, always-dark app.

> **Status:** in development. Built so far: the app itself, Crosshair, Window Backdrop, NBB Overlay, hotkeys and settings, Key Rebinder, Screen Recording and the first-launch introduction. Still to come: hotkeys without a modifier and on the Key Rebinder's keys, Timer Overlay and the beta release. The first beta (0.1.0) goes to testers before any public release.

## Tools

| # | Tool | What it does |
|---|------|--------------|
| 1 | **NBB Overlay** | Shows Ninjabrain Bot's live result on screen, over the game. |
| 2 | **Window Backdrop** | Covers everything behind the Minecraft window — under the menu bar and Dock too, on any display — with a color, gradient, image or video. |
| 3 | **Crosshair** | Draws a customizable crosshair at the exact center of the screen, or your own image. |
| 4 | **Timer Overlay** | One key starts a countdown that pops up over the game, rings an alarm and leaves by itself (planned for 0.1.0). |
| 5 | **Screen Recording** | Records Minecraft and sTools' overlays, plus windows, displays, cameras, web pages, app audio and microphones arranged on one canvas. |
| 6 | **Key Rebinder** | Shows your Karabiner-Elements rebinds and Minecraft keybinds on a drawn keyboard and mouse; edit, check against speedrun rules, test keys, manage profiles, and put sTools hotkeys on keys. |

Also: global hotkeys (off by default; any key, with or without modifiers, set in Home or right on a key in the Key Rebinder), a first-launch introduction that sets up permissions and lets you try every tool, settings for everything, and automatic updates.

## Requirements (planned)

- macOS 15 Sequoia or newer — Apple silicon (Intel best-effort)
- [Ninjabrain Bot](https://github.com/Ninjabrain1/Ninjabrain-Bot) with its API enabled, for the NBB Overlay
- [Karabiner-Elements](https://karabiner-elements.pqrs.org) 16.0 or newer, for the Key Rebinder
- Minecraft 1.16.1 (official launcher or Prism Launcher)

## First open (planned)

sTools isn't notarized, so macOS blocks it the first time. Open it once, then go to **System Settings ▸ Privacy & Security** and click **Open Anyway**. After that it opens normally, and updates install themselves.

## Speedrun rules

- The NBB Overlay shows only what Ninjabrain Bot itself shows, as the rules require for tools using its API (rule A.11.7.a.i).
- The Key Rebinder's rule checker points out rebinds that may break the remap rules (A.10.1–A.10.4). It only advises; you decide.
- A countdown like Timer Overlay isn't on the rules' list of allowed tools, so ask the moderators before submitting runs that use it (A.11.9).

## Documentation


## License

All rights reserved. Third-party components keep their own licenses: DM Serif Display (SIL Open Font License), Sparkle (MIT).
