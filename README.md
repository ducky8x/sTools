<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="The sTools icon: a gold duck hanging from a stool, on black">
</p>

<h1 align="center">sTools</h1>

<p align="center">
  <strong>A Mac app for Minecraft: Java Edition speedrunners.</strong>
</p>

<p align="center">
  <a href="#requirements"><img src="https://img.shields.io/badge/macOS-15%2B-E4BC62?style=flat-square&labelColor=15120F" alt="macOS 15 or later"></a>
  <a href="#build-from-source"><img src="https://img.shields.io/badge/Swift-6-E4BC62?style=flat-square&labelColor=15120F" alt="Swift 6"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-E4BC62?style=flat-square&labelColor=15120F" alt="MIT license"></a>
</p>

<p align="center">
  <a href="#the-tools">Tools</a> ·
  <a href="#requirements">Requirements</a> ·
  <a href="#install">Install</a> ·
  <a href="#how-its-written">How it’s written</a> ·
  <a href="#speedrun-rules">Speedrun rules</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="#license">License</a>
</p>

sTools is one native app with six tools: a crosshair, a countdown timer, Ninjabrain Bot’s answer drawn over the game, a screen recorder, a backdrop behind the game and an editor for your Karabiner-Elements rebinds. Its overlays are click-through and never take focus from Minecraft. The app is always dark, in serif type with gold accents.

<p align="center">
  <img src="docs/images/key-rebinder.png" alt="The Key Rebinder page: the sidebar with the six tools, and a drawn keyboard and mouse with Caps Lock rebound to F3 in gold, Minecraft’s keybinds in small capitals under the keys, gold rings on the keys of sTools hotkeys and red dots where the checker found a problem">
</p>

## The tools

| | Tool | What it does | Needs |
|---|------|--------------|-------|
| 1 | Crosshair | Draws a crosshair at the exact center of Minecraft’s display. | Accessibility |
| 2 | Timer Overlay | Pops a countdown over the game on one key, rings and leaves. | Accessibility |
| 3 | NBB Overlay | Shows Ninjabrain Bot’s current result over the game. | Accessibility, Ninjabrain Bot |
| 4 | Screen Recording | Records Minecraft and your other sources on one canvas, a web page’s own sound included. | Accessibility, Screen & System Audio Recording |
| 5 | Window Backdrop | Hides everything behind the Minecraft window with a color, gradient, image, GIF or video. | Accessibility |
| 6 | Key Rebinder | Shows and edits your rebinds on a drawn keyboard and mouse. | Karabiner-Elements 16+, to edit |

Each tool has a page with its settings, the rarely needed ones under **Advanced**. Switch tools on and off from the sidebar or from their pages. Around them:

- **Hotkeys.** Your own keys, alone or with ⌃ ⌥ ⇧ ⌘, switch tools on and off, start the timer and start or stop a recording. A new install has ⌘1–⌘5, one per tool in sidebar order. They work only while sTools or Minecraft is in front, so a browser keeps its own ⌘1, and by default they still fire with Shift or Control held, as when you sneak or sprint.
- **The Prologue.** On first launch it walks you through each permission, Ninjabrain Bot and Karabiner-Elements, then has you try every tool. Help ▸ Replay Introduction runs it again.
- **Settings.** Open at login, sounds, Reduce animations, text size, accent color, update options, export and import of everything as one file, resetting, and Copy Diagnostics for bug reports.

Close the window and your tools keep running; click the Dock icon to bring it back. Quitting turns everything off.

## Requirements

- **macOS 15 Sequoia or later**, on an Apple silicon or Intel Mac. sTools is one universal app; Intel is best effort.
- **Minecraft: Java Edition.** sTools is made for 1.16.1 with the official launcher or Prism Launcher.
- **[Ninjabrain Bot](https://github.com/Ninjabrain1/Ninjabrain-Bot)** for the NBB Overlay, with its API turned on (Settings ▸ Advanced in Ninjabrain Bot).
- **[Karabiner-Elements](https://karabiner-elements.pqrs.org) 16.0 or later** to edit rebinds and profiles. The keyboard, your Minecraft keybinds, the key tester and hotkeys on keys work without it.
- **Five permissions**, which the Prologue walks you through: Accessibility, Screen & System Audio Recording, App audio, Microphone and Camera. A tool’s page offers **Allow…** when something it needs is missing. [Why each one](#permissions) is further down.

## Install

1. Download the latest DMG from the [releases page](https://github.com/ducky8x/sTools/releases).
2. Open it and drag **sTools** onto **Applications**.
3. The first time you open sTools, macOS blocks it, because it is signed with ducky’s own self-signed certificate and isn’t notarized by Apple. To let it through:
   1. Open sTools from Applications, then click **Done**.
   2. Go to **System Settings ▸ Privacy & Security**.
   3. Click **Open Anyway**, then confirm.

After that it opens normally.

**Updates.** sTools checks for a new version once a day and shows what’s new when it finds one. Settings ▸ Updates can also download and install updates when you quit; that switch starts off. Every release is signed with the same certificate, so macOS keeps the permissions you’ve granted. If someone sends you a newer DMG, choose **Settings ▸ Updates ▸ Install from DMG…** (or **sTools ▸ Install from DMG…**, or drop the DMG on that row). sTools installs it only if it’s a newer sTools signed with the same certificate, then opens again.

## How it’s written

This part is for someone about to read the code: the package first, then the tools one by one, then what they share, the build and the tests. Names in code font are types, files and scripts you can search for.

### The package

sTools is a Swift package (tools version 6.0, Swift 6 language mode, macOS 15) with one executable and a library per module:

| Module | What’s in it |
|--------|--------------|
| `sTools` | The app: window, sidebar, Home and its hotkeys section, Settings, menus, the Dock tile, the updater, and `AppModel`, which wires the rest together |
| `STDesign` | Colors, type (the bundled fonts), motion, sounds and the shared controls |
| `STPlatform` | What every tool shares: Minecraft detection, displays, `OverlayPanel`, permissions, settings storage, hotkeys, logging, diagnostics |
| `Crosshair` | Crosshair geometry, rendering and page |
| `TimerOverlay` | Countdown engine, press rules, overlay, alarm and placement |
| `NBBOverlay` | Ninjabrain Bot client, window reader and overlay |
| `ScreenRecording` | Capture, compositing, audio and the file writer |
| `Backdrop` | Window Backdrop |
| `KeyRebinder` | Karabiner configuration and command line, keyboard layouts, checker, key tester |
| `Prologue` | The first-launch introduction |

A tool module depends on `STDesign` and `STPlatform` and nothing else, so tools can’t import each other; only the `sTools` target sees them all. Sparkle is linked into `sTools` alone. Apart from it, everything is Apple frameworks. Each module has a test target. `Benchmarks/` holds four executables, `RecordingBench`, `NBBBench`, `BackdropBench` and `OverlayBench`, that are never shipped. `scripts/` and `packaging/` hold the build and release tooling, and `docs/` holds the spec and the plans.

Swift 6’s strict concurrency checking is on everywhere. The UI, the controllers and every AppKit window are on the main actor. The Karabiner config store is an `actor`, so each read-modify-write is serialized. A recording keeps its work off the main actor: capture callbacks run on their own queues, one serial queue ticks the frame clock, and only the recording’s state machine sits on the main actor.

### The app shell

`STApp` is a SwiftUI `App` with one `Window`: hidden title bar, 760 × 560 by default, never smaller than 680 × 500. The window’s content is SwiftUI. `AppDelegate`, attached with `@NSApplicationDelegateAdaptor`, covers what SwiftUI doesn’t: it keeps the app alive when the window closes, reopens the window from the Dock, builds the Dock menu, and holds off quitting (`applicationShouldTerminate` answers `.terminateLater`) until `AppModel.shutDown()` has finished any recording, switched every tool off and flushed settings.

`AppModel` (`@MainActor`, `@Observable`) is built once. It creates the shared services (`ToolServices`: the settings store, the display directory, the Minecraft locator and the permission center), the five switchable tool controllers and the Key Rebinder’s, the hotkey center, the updater and the Prologue, and keeps each tool’s on/off state and the navigation history. A controller adopts `ToolController` (`isEnabled` and `setEnabled`) and the shell needs nothing more from it, so the app’s tests swap in fakes. Every tool starts off; Settings ▸ General ▸ Advanced can bring back the ones that were on at quit. A tool that needs Accessibility can’t be switched on without it, and one that’s on switches off when the grant is revoked.

`ToolID.allCases` is the one place the sidebar order is written. The sidebar, its numbers, the Go menu, Home, the key sets and the Prologue’s lists all read it. While the main window is closed it holds no pages at all (the root view draws nothing), so their views, layers and caches are released while the tools keep running.

### Overlays

The overlays and the backdrop are `OverlayPanel`s, an `NSPanel` subclass with two roles.

- **Topmost** (Crosshair, Timer Overlay, NBB Overlay and the hotkey confirmation): borderless, transparent and click-through (`ignoresMouseEvents`), at window level `.screenSaver`, which is above the menu bar, the Dock and pop-up menus. Its collection behavior is `canJoinAllSpaces`, `fullScreenAuxiliary`, `stationary` and `ignoresCycle`. So it shows on every Space and over a native full-screen game, Mission Control leaves it alone, and the Cycle Through Windows command skips it. Placement mode turns mouse handling on so you can drag an overlay.
- **Backdrop** (Window Backdrop): the normal window level, ordered directly under Minecraft’s window. See [Window Backdrop](#window-backdrop).

Both roles are non-activating and can never become key or main, so showing, moving or clicking a panel never takes focus from Minecraft. AppKit never animates a panel in or out (`animationBehavior = .none`); a fade belongs to the overlay itself and stops under Reduce animations. `constrainFrameRect` returns the frame as given, so AppKit can’t nudge a panel below the menu bar. SwiftUI content goes in through `NSHostingView` with its sizing options cleared, so the content can’t resize the window.

Panels are capturable by default (`sharingType = .readOnly`), which is how overlays end up in sTools’ own recordings. A panel can also be created excluded from capture (`sharingType = .none`, fixed at creation). The hotkey confirmation, Timer Overlay’s placement guides and, with Show in recordings off, the timer itself are made that way. `OverlayPanel` posts a notification when a capturable panel is shown or hidden, and Screen Recording listens for it to update what it captures.

### Finding Minecraft

The tools all follow the Minecraft instance that `MinecraftLocator` publishes, and `AXMinecraftSource` feeds it:

1. Lists running apps whose executable is `java` or `javaw`. Ninjabrain Bot is Java too; its window title tells it apart.
2. Asks Accessibility for each one’s windows and keeps those titled `Minecraft`, an optional `*`, a space and a version that starts with a digit, such as `Minecraft* 1.16.1 - Singleplayer`. A launcher window or a browser tab titled `Minecraft…` has no version and doesn’t count.
3. Reads each match’s position, size and minimized and full-screen flags, and takes its window number from the window server’s list (`CGWindowListCopyWindowInfo`) by matching process and frame. That list is metadata only; sTools never asks for window images. The display is the one the window overlaps most.

It doesn’t poll. An `AXObserver` per Java process reports window, title, focus and minimize changes, and `NSWorkspace` notifications cover launches, quits, activation, hiding and Space changes. Accessibility lists only the current Space’s windows, so a full-screen game appears once its Space is active. A burst of events becomes one read 30 ms later. With more than one Minecraft open the locator follows the 1.16.1 one, then the one that started first, and Home says which. The game folder, for `options.txt`, comes from the `--gameDir` argument (read with `sysctl` and `KERN_PROCARGS2`; the official launcher passes it) or from the process’s working directory (`proc_pidinfo`; Prism Launcher starts the game inside the instance folder).

### Crosshair

The crosshair is drawn in true display pixels. Everything is measured on the display’s backing-pixel grid (its frame in points times the backing scale, 1x or 2x), and the finished bitmap goes onto whole backing pixels with interpolation off, so one sprite pixel covers exactly one display pixel. `CrosshairGeometry.placement` takes the display’s center pixel plus the offset and puts the sprite’s hot pixel on it. A shape with an even width has no center pixel, so it sits on the far edge of the pixel just left of (or above) the middle, which is the exact center. AppKit floors a window’s origin to whole points even at 2x, so the window starts on a whole point and the sprite is padded inside a slightly larger canvas.

Plus, dot, circle and X are masks computed at 4x supersampling. An outline is a dilation of the mask, and opacity is applied once to the finished composite so the outline and fill don’t stack their alpha. The default (a plus, 11 px, 3 px thick, offset −1, −1) covers Minecraft’s own crosshair exactly at GUI scale 3 on a 1920 × 1080 display, and on a 2x display that looks like one. On the page, the preview is the overlay’s own view, so the two can’t differ, and the overlay redraws only when something it draws has changed.

### Timer Overlay

`Countdown` is a plain struct state machine (idle, running, paused, finished) that is handed the time instead of reading it, so the app and its tests run the same code. `TimerEngine` supplies the time from `clock_gettime_nsec_np(CLOCK_MONOTONIC)`, which keeps counting while the Mac sleeps, and reads it again on `NSWorkspace.didWakeNotification`, so a run that passed zero in sleep finishes and rings on wake. At most one dispatch timer exists, set for the next change of what’s shown (every second, or every tenth in the last ten seconds with tenths on), so an idle or paused timer schedules nothing. While a run is live the engine holds `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`, which keeps App Nap from delaying the alarm without keeping the Mac awake.

`PressPolicy`, a small value the controller owns, turns presses and releases into actions. A second press within 0.4 s cancels and switches the tool off, and with the Advanced option a hold of a second does the same. It reads no clock. The hotkey layer passes along the time macOS stamped on each key event (`GetEventTime`, on the uptime clock) and the controller converts it to its own clock, so the double-press window is measured between the keys and not between when sTools got around to handling them.

The alarm plays through `AVAudioEngine`: one of macOS’s sounds, one of four alarms sTools generates (`scripts/generate-sounds.swift`, deterministic), or a file you add. With Alarm in sTools recordings on, it publishes each rendered buffer to a named in-process audio feed that Screen Recording carries as its own track. A process tap on sTools itself would catch its interface sounds too. The overlay is a topmost panel built for each pop-up, excluded from capture when Show in recordings is off, and `canHide = false` keeps it up through Hide sTools and Hide Others. The placement guides (zones the rules want visible, such as the hotbar, chat and toasts) are a second panel one window level below it, always excluded from capture.

### NBB Overlay

Ninjabrain Bot runs a small HTTP server on `localhost:52533` when its API is on. `NBBConnection` opens Server-Sent Events streams to it: `stronghold` first, then `blind`, `divine`, `boat`, `information-messages` and `all-advancements`, which start when the first one connects and stop if it disconnects. A one-off `/api/v1/version` request asks for the version, and the Prologue pings `/api/v1/ping`. While Ninjabrain Bot isn’t running that is one refused connection every few seconds, not seven.

The streams use a `URLSession` of their own (ephemeral, 16 connections per host, a 24-hour idle timeout because Ninjabrain Bot sends nothing between changes) and pass each line on whole. `NBBSubscription` reconnects with a backoff from 0.5 s to 5 s. A repeated value is dropped, so a reconnect never redraws, and a new value redraws the overlay in the same main-actor turn, within a few milliseconds of Ninjabrain Bot writing it. If the content is too big for its plate, the overlay scales it down uniformly, to 60% at most, before it clips anything.

Only one Ninjabrain Bot can hold the API’s port. `NBBCopiesMonitor` scans the process table (`libproc` and `sysctl`, no permission needed) on a background task, every 2 s while a copy is open and every 5 s while none is. A command line is read only for this user’s Java and Ninjabrain-named executables, and each copy’s sockets are checked to see which one listens on 52533. The overlay follows the copy you pick, the newest by default.

A copy without the API is read from its window. `AXNBBWindowReader` walks the window’s Accessibility tree on a queue of its own and keeps the static texts and buttons, and `NBBWindowParser` turns them into the same result type the API gives (predictions, throws and notes; no boat). Ninjabrain Bot’s Java UI doesn’t announce label changes to Accessibility, so the window is looked at ten times a second. Most looks ask only for the texts that change with a result, a full read comes at least every second, and a new walk every five.

### Screen Recording

The recorder is four stages: capture, a frame clock and compositor, an encoder, and a file writer.

**Capture.** A video source is a `VideoCapture`. Windows and displays are ScreenCaptureKit streams, cameras are `AVCaptureSession`s, and a web page is a `WKWebView` in a borderless window parked far off screen and captured like any window. The base layer is one stream over Minecraft’s display whose filter names Minecraft’s window and sTools’ visible overlay panels; the filter is updated about 50 ms after a panel shows or hides and checked every 2 s. A window source uses `SCContentFilter(desktopIndependentWindow:)`, so it can sit behind Minecraft or off screen and still be recorded. Each source’s frames go into `FrameHub`, which keeps only the latest one and remembers which were already used, because ScreenCaptureKit sends a frame only when something changes.

**Clock and compositor.** `FrameClock` ticks at 30 or 60 fps on one serial queue. Tick n is stamped n/fps after the start, worked out from the slot and not from accumulated sleeps, so it doesn’t drift, and after a stall it reports the skipped slots instead of filling them. On each tick `Compositor` draws the hub’s latest frames into a pooled pixel buffer with Core Image on Metal: crop, scale, opacity, rounded corners and borders. A tick whose sources brought nothing new writes the last picture again. When Minecraft alone fills the output at its own size, its frame goes to the encoder through a VideoToolbox pixel-transfer copy without touching Core Image.

**Encoder and writer.** `RecordingWriter` feeds an `AVAssetWriter`, which hands video to VideoToolbox (H.264 or HEVC, hardware encoding on). On Apple silicon the quality setting is a constant quality. Intel Macs’ encoders don’t take one, and `AVAssetWriterInput` throws an Objective-C exception if given the key, so there quality sets a bit rate. The file is a fragmented QuickTime movie with a fragment every second, so a crash loses at most the last second. A frame that finds the encoder busy is dropped and counted, never queued. Recordings are always `.mov` first, named by date and time. Save renames, and for .mp4 `Rewrapper` copies the samples without re-encoding and checks codec, sample counts and track names before the .mov is removed. A name is never overwritten: a taken one gets ` 2`, ` 3`, as Finder does.

**Sound.** An audio source is an `AudioCapture`: a Core Audio process tap per app (`CATapDescription` in a private aggregate device, unmuted), one more for the sound of web pages (below), microphones through `AVCaptureSession`, and sTools’ own in-process feeds. `AudioNormalizer` converts every chunk to 48 kHz stereo Float32. `AudioTimeline` places it on the host clock, which ScreenCaptureKit, AVFoundation and Core Audio all stamp with. Jitter under 10 ms is left alone, a larger gap is padded with silence and an overlap is trimmed. `AudioMixBus` hands the writer equal-length blocks a quarter second behind the picture, so a late source isn’t padded and then trimmed. The AAC tracks are the mix first, then one track per source, each named.

**Web page sound.** A web page’s sound isn’t in its captured picture. It plays from WebKit’s helper processes, which launchd starts, so their parent says nothing about whose they are. Core Audio lists each by a process ID and a bundle ID that starts with `com.apple.WebKit.`, the same for Safari’s tabs as for sTools’, and no public call says which app a helper works for. macOS does keep that for every process, and sTools reads it through a system call that has no public header, looked up by name when first needed and never linked. `ProcessTapCapture` in its `ownWebViews` mode taps the audio processes whose bundle ID starts that way and that work for sTools, or for the program that started it when sTools runs from a terminal or a debugger. Other apps’ helpers, sTools’ own process (its interface sounds and the Timer alarm) and any helper the call can’t answer for are left out: no sound rather than another app’s. On a Mac without the call, a note says the page’s sound couldn’t start, and the page is recorded without it. Helpers come and go as pages load and close, so once a second the capture compares the helpers that exist with the ones its tap listens to and rebuilds the tap when they differ. The first sound after a change can start up to a second late. WebKit plays all of an app’s pages from one helper, so the pages share one switch, one volume and one track, named for the page’s host (`twitch.tv`) or “Web pages” when there are several.

**Arming and stopping.** Switching the tool on arms its sources and the page shows the live composite; Record starts the writer. Stop switches the tool and every source off at once, camera light included, finishes the file, and then a non-activating panel of its own, one window level above the overlays, asks for a name and Save or Delete (Delete asks once more). Each arming owns its sources (`CaptureRig`), and a `CaptureStartGate` makes a stop that arrives mid-start win. A start that is canceled or fails says so over the game and switches the tool off.

### Window Backdrop

A backdrop is one `OverlayPanel` per covered display at the normal window level, the size of the display’s full frame, so it reaches under the menu bar and the Dock. Ordering uses `order(.below, relativeTo:)` with Minecraft’s window number, which puts the panel directly under the game and over every other window. The spec records a probe that confirmed this public call can order a window directly below another app’s.

`BackdropOrdering.plan` is a pure function from Minecraft’s window, its display, focus and the settings to what each panel should do. The controller applies it again whenever an app activates, the displays change or the locator’s instance changes. A backdrop hides while Minecraft is minimized and, depending on a setting, while it is full screen. The panel handles mouse events only to swallow them: `mouseDown` calls `NSApp.preventWindowOrdering()`, so clicking it raises nothing and activates nothing. A new fill crossfades from the old one, at once under Reduce animations. Images are decoded when first drawn and let go when the tool switches off, because a screen-sized image is tens of megabytes decoded, and switching off closes the panels instead of hiding them.

A fill is a color, a gradient, an image or an animation, and each display can have its own. An animation is a GIF or a video, looped and muted, fitted like an image: `BackdropMediaView` gives the player’s layer the rect `BackdropImageLayout` works out for an image of the same size, so Fill, Fit, Stretch and Center mean the same for both. Choosing a file copies it into `Images`, as for an image, after `BackdropAnimationFile` has checked it off the main actor. A GIF is told by its header, whatever the file is called, and anything else is left to AVFoundation, which plays it or says it can’t. A file over 200 MB is refused, because Export writes every file in `Images` into one settings file as text a third larger. A copy that no fill uses any more is deleted, since a video is far larger than an image.

A video plays in an `AVPlayerLayer` on an `AVQueuePlayer`, and `AVPlayerLooper` loops it. The player gets the video track alone, in an `AVMutableComposition`, so the file’s sound is never opened, and it is muted as well. sTools handles no frames and runs no timer for a video, and the player never asks to keep the display awake. A GIF is read with ImageIO, which gives each frame whole, with the frames before it already applied. `BackdropGIFPlayer` shows each for its own delay, and a frame that asks for a hundredth of a second or less gets a tenth. It decodes off the main actor, one frame at a time and a few ahead of the one on screen, into a cache of at most 128 MB. A loop that fits is decoded once and then only shown; a longer one decodes the rest again on every loop, which is why a big GIF costs more than a video. Between two frames the only thing that runs is one timer. A GIF with more than 4096 × 4096 pixels a frame is refused, because a decoded frame is four bytes a pixel and a few are held at once.

An animation plays only while it can be seen. `BackdropController.updatePlayback()` plays it when the tool is on, the panel is ordered in (a hidden backdrop plays nothing), the window server hasn’t called the panel wholly covered (`NSWindow.didChangeOcclusionStateNotification`) and the screens are awake (`NSWorkspace.screensDidSleepNotification` and `screensDidWakeNotification`). A paused animation keeps its last picture, decodes nothing and sets no timer. Each of these changes arrives as a notification; no timer looks for them. While motion is reduced, whether by Reduce animations or by macOS’s Reduce motion, a fill that can be seen holds still on its first frame instead; the controller watches `STTheme.reduceMotion` with `withObservationTracking` to play or hold again when it changes. A fill that is replaced stops at its last picture at once, stays up while it fades out and is let go when the fade is over. Switching the tool off stops every player and frees the decoded frames.

### Key Rebinder

The Key Rebinder reads and writes Karabiner-Elements’ own file, `~/.config/karabiner/karabiner.json`. Its own JSON parser and writer (`JSONValue`) stand in for `JSONSerialization`: objects keep their key order, numbers keep the form they were written in, and the output follows Karabiner’s own layout. An edit changes what it means to and leaves everything sTools doesn’t understand where it was.

`KarabinerConfigStore` is an actor, so edits are serialized, and every write takes the same steps:

1. Refuse a symbolic link.
2. Read the file again and run the edit on that fresh parse.
3. If the file changed since sTools loaded it (compared by SHA-256), write nothing and show a preview first.
4. Copy the current bytes to `~/Library/Application Support/sTools/Karabiner Backups`, with a UTC timestamp in the name. The newest 20 are kept by default.
5. Write a temporary file next to the original and rename it over the original, keeping its permissions.
6. Read it back and compare. If it differs, restore the backup.

A `DirectoryWatcher` on Karabiner’s folder notices edits made elsewhere. `karabiner_cli`, in `/Library/Application Support/org.pqrs/Karabiner-Elements/bin`, reports the version, the profiles, the current profile and the connected keyboards and mice, selects a profile, and lints complex modifications. A `KarabinerStatus` check says whether Karabiner-Elements is installed, answering and at least version 16.0. sTools isn’t sandboxed, which is what lets it write into `~/.config`.

The key list (`Resources/KeyTable.json`) is generated by `scripts/generate-key-table.swift` from a checkout of Karabiner-Elements’ own key data, so keys have Karabiner’s names. Minecraft’s keybinds come from the game’s `options.txt`, read only. The live key tester sees events after Karabiner has rebound them, so it works backward through your current rebinds to the physical key. A local `NSEvent` monitor does the listening, so only keys that reach sTools’ own window count and no Input Monitoring permission is needed. The checker advises on duplicates, shadowed rules, chained rebinds and the remap rules (A.10.1–A.10.4); it never blocks a save.

### Hotkeys

`HotkeyCenter` registers keys with Carbon’s `RegisterEventHotKey` through a `HotkeyRegistering` protocol; tests use a fake that registers nothing. Registered this way a hotkey needs no permission of its own, and its key goes to sTools alone, so Minecraft never sees it. One application-wide handler receives presses and releases, each with the time macOS stamped on it.

By default hotkeys work only while sTools or Minecraft is in front. Rather than listen everywhere and ignore presses, `HotkeyFrontAppWatcher` takes the registrations away when another app comes to the front, so that app gets its keys untouched (a browser’s ⌘1 still switches tabs), and puts them back when sTools or Minecraft returns. `NSWorkspace` activation notifications and the locator’s instances drive it, never a timer. Recognizing Minecraft needs Accessibility, so without it hotkeys work only in sTools unless Where hotkeys work is set to Everywhere. Hotkeys also pause while sTools listens for raw keys: a field recording a key, text being typed, the Key Rebinder’s tester.

macOS matches a hotkey’s modifiers exactly, so a bare ⌘1 stops working while you hold Shift to sneak or Control to sprint. Home ▸ Hotkeys ▸ Advanced ▸ Also fire while holding Shift or Control, on by default, makes `HotkeyCenter` register each hotkey’s key again with ⇧, ⌃ or both added to the modifiers it holds. A variant’s press is its hotkey’s own press, and a hotkey and its variants count as one key: while one is held, a press of another is a repeat. A variant is left out when the combination is taken (by another hotkey, or by an earlier hotkey’s variant) and when macOS keeps it (the screenshot shortcuts, ⌘Tab and the rest of `HotkeyCombo.reservedCombos`, plus ⌃⇧⌘3 and ⌃⇧⌘4) or refuses it. While sTools is in front, it is also left out when it is one of sTools’ own menu shortcuts: the Go menu’s ⌃⌘0–⌃⌘6 for Home and the tools, ⌘, for Settings, ⌘[ for Back and ⌘] for Forward. So a hotkey on ⌘1 also fires with Control held in the game, but not in sTools, where ⌃⌘1 opens a page. Variants exist only in what is registered: `hotkeys.json` never changes, and the option is a document of its own, `hotkeyHeldModifiers.json`, which isn’t written until you change it.

The list lives in `hotkeys.json` and decodes leniently, so one bad entry never costs the rest. Its migrations never move a saved list; only an empty one gets ⌘1–⌘5.

### Settings storage

Modules save through `SettingsStore`: one JSON file per document in `~/Library/Application Support/sTools`, shaped `{"version": N, "value": {…}}` and written pretty-printed with sorted keys. A document is a `Codable` type that adopts `SettingsDocument`: a name, a version, a default, and optionally a migration. Saves are debounced by half a second and written atomically, and `flush()` runs at quit.

Loading never throws. A missing file gives the default. An unreadable file, or one written by a newer version, is renamed aside and never deleted, which is why going back to an older build starts from that build’s own defaults. A migration upgrades the raw dictionary one version at a time. Examples are `hotkeys.json` from version 1 to 3, the NBB Overlay’s correction display from 1 to 2, and the recording layout’s move from canvas pixels to fractions of the canvas. Additive changes need none, though a version bump can still protect them from an older build. `backdrop.json` went to version 2 for the Animated fill, so a build that knows only version 1 sets the file aside instead of reading `animated` as a color and saving over the animation.

Next to the JSON files are `Images` (what you pick for the crosshair or the backdrop, a GIF or video included, is copied in), `Sounds` (your own alarm files), `Backups` (copies made before an import or a reset) and `Karabiner Backups`. Export writes everything into one `.stools-settings` file: a single JSON envelope holding the documents, with the images and sounds as base64. Import backs up first, never deletes anything, and restores from the backup if a write fails. Recordings go to `~/Movies/sTools` unless you pick another folder.

sTools’ own code never touches `UserDefaults` or `@AppStorage`. Sparkle keeps its bookkeeping, such as the time of the last check, in the app’s defaults. Logging goes through `os.Logger` with subsystem `com.ducky8x.sTools`. Copy Diagnostics puts a report on the clipboard: versions, displays, permissions, what’s running, settings file names and sizes (no values), and the last 15 minutes of sTools’ own log, with home paths shortened to `~`.

### Motion

Animations go through `STMotion`: `stAnimation(_:value:)` in place of `.animation(_:value:)`, and `STMotion.animate` in place of `withAnimation`. Each window, sheet and panel root also gets `stMotionRoot(theme)`, which strips any animation still asked for. `STTheme.reduceMotion` is true when Settings ▸ Appearance ▸ Reduce animations is on or macOS’s Reduce motion is (`SystemMotionWatcher` follows its change notification), and then every change happens at once. Code that waits for an animation to finish has to use `STMotion.animate`’s completion, because SwiftUI never calls the completion of an animation that was taken away. An animated Window Backdrop fill is a player, not a SwiftUI animation, so the Backdrop controller reads `reduceMotion` itself and holds the fill on its first frame.

### Permissions

| Permission | Read with | Used for |
|------------|-----------|----------|
| Accessibility | `AXIsProcessTrusted` | Finding Minecraft’s window and following it, reading a Ninjabrain Bot window, and recognizing Minecraft in front for hotkeys |
| Screen & System Audio Recording | `CGPreflightScreenCaptureAccess`, which never prompts | ScreenCaptureKit capture of Minecraft, windows and displays. macOS may ask to reopen sTools after you allow it |
| App audio | A probe that makes and removes a Core Audio process tap, because there is no public preflight | The sound of Minecraft, other apps and the web pages you add. Same Settings pane as screen recording; needs `NSAudioCaptureUsageDescription` |
| Microphone | `AVCaptureDevice.authorizationStatus(for: .audio)` | Microphone sources. Needs a usage description and the audio-input entitlement |
| Camera | `AVCaptureDevice.authorizationStatus(for: .video)` | Camera sources. Needs a usage description and the camera entitlement |

`PermissionCenter` reads statuses with calls that never prompt, and asks only when you press **Allow…**, which opens the right System Settings pane. Polling happens only while a page that shows a permission is on screen (every second). While a tool that needs Accessibility runs, it rereads Accessibility alone when macOS posts its change notification, when sTools becomes active and every 15 s as a backstop. Without Accessibility the tools that need it stay off and hotkeys work only in sTools, unless Where hotkeys work is Everywhere; the Key Rebinder works without it.

sTools never asks for Input Monitoring. Hotkeys go through Carbon, and the key tester watches only sTools’ own window.

### Updates

Updates use [Sparkle](https://sparkle-project.org) 2, the one outside dependency (`Package.resolved` pins 2.10.0; `Package.swift` allows any 2.x from 2.6.0). `AppUpdater` sits behind an `AppUpdating` protocol, so tests use a fake and nothing in the suite starts Sparkle. The real one builds an `SPUUpdater` with Sparkle’s standard windows directly, not `SPUStandardUpdaterController`, so a Sparkle that can’t start is logged and not shown as an alert. Sparkle runs only in a packaged app whose Info.plist has a feed URL and a public key; `swift run`, tests, the dev build and a debug build without the key say so in Settings instead.

`SUFeedURL` is `https://github.com/ducky8x/sTools/releases/latest/download/appcast.xml`. GitHub sends that address to the `appcast.xml` attached to the release marked Latest. Each version is one release, tagged `v<version>`, with two files: the DMG and an `appcast.xml` that lists every version so far, newest first. Each item points at the DMG on its own release. Sparkle compares an item’s build number with the running `CFBundleVersion`; the build number is the commit count, so it only goes up. The feed itself isn’t signed (Sparkle’s `SURequireSignedFeed` is optional and off); the signature on each download is what protects you. The address answers once the repository is public.

Each DMG is signed with an EdDSA key whose private half lives in the keychain of the Mac that publishes and never in the repository. The public half is `packaging/sparkle-public-key.txt`, which the build writes into Info.plist as `SUPublicEDKey`. Sparkle accepts an update only if the download validates against the key in the running copy or the new app’s code signature matches the old one’s (`SUUpdateValidator` in Sparkle’s source). sTools keeps both the same from release to release.

Info.plist sets `SUEnableAutomaticChecks` and a `SUScheduledCheckInterval` of a day, so Sparkle checks daily and never stops to ask first; its default is to ask on the second launch. Settings ▸ Updates has two switches, handed to Sparkle at launch and on every change: check automatically (on by default) and download and install automatically (off by default, so a found update is shown and you decide). **Check Now** and sTools ▸ Check for Updates… call `checkForUpdateInformation()`, which asks the feed without opening a window. sTools words the answer itself (up to date, a version is available, the server can’t be reached) and opens Sparkle’s window only when there is an update to install. A scheduled check that fails says nothing.

Sparkle’s window shows the release notes with Install Update, Skip This Version and Remind Me Later. Sparkle downloads the DMG, checks it, takes the app out, and hands over to `Autoupdate`, a helper inside the framework that clears the download quarantine from the new copy, waits for sTools to quit, replaces the app and starts it again.

`scripts/publish-update.sh --version <x.y.z>` makes a release. It builds the release app and its DMG, signs the DMG with Sparkle’s `sign_update`, adds the version to the previous feed (`scripts/appcast-add-item.sh`) and reads the result back with Sparkle’s own parser (`scripts/check-appcast.sh`). Then the GitHub release is created, marked Latest, with the DMG and the feed attached. A pre-release or a draft would hide the feed from its address, so the script makes neither, and it refuses to run unless the commit is already on `origin/main`. It never pushes. `--dry-run` stops before anything reaches GitHub.

#### Why permissions survive an update

macOS decides whether a new build is the same app by its designated requirement, and the grants for Accessibility, Screen Recording, Microphone and Camera belong to that app. sTools’ is `identifier "com.ducky8x.sTools" and certificate leaf = H"…"`, a hash of the signing certificate. Notarizing needs a paid Apple developer account, so sTools is signed with a self-signed certificate named `ducky8x`, made once by `scripts/make-signing-identity.sh`. Every release uses that same certificate, so the requirement never changes. An ad hoc build changes it on every build, and a new certificate would change it for good. That is why the build scripts sign with that identity only and refuse every other.

#### Why the library-validation entitlement

The app is signed with the hardened runtime, which turns on library validation: a process may load only frameworks signed by Apple or by its own Team ID. A self-signed certificate has no Team ID (`TeamIdentifier=not set`), so without help the app can’t load `Sparkle.framework`, though the framework is signed with the very same certificate, and it quits at launch. `com.apple.security.cs.disable-library-validation` in `packaging/sTools.entitlements` turns the check off. The cost is that the app no longer refuses libraries signed by someone else, and Apple notes that Gatekeeper runs extra checks on programs that have the entitlement.

The same file lists the camera and microphone entitlements, which the hardened runtime needs for those devices, and `com.apple.security.network.client`, which Apple documents for sandboxed apps. sTools isn’t sandboxed: it writes into `~/.config/karabiner`, runs `karabiner_cli`, reads other apps’ windows through Accessibility and reads process command lines. Sparkle bundles two XPC services for sandboxed apps. They ride along, signed, and go unused, because sTools’ Info.plist doesn’t switch them on.

#### Install from DMG…

This is the way in for a DMG someone sent you, and the fallback whenever Sparkle can’t be used. `DMGInstaller`:

1. Mounts the DMG read-only and hidden from Finder (`hdiutil attach -nobrowse -readonly`, then `diskutil image attach` if that fails).
2. Finds a top-level app with bundle ID `com.ducky8x.sTools` that is the same build variant as the running copy.
3. Compares build numbers: the same build is refused, an older one asks first, a newer one goes on.
4. Checks that the app satisfies the running copy’s own designated requirement, with strict, all-architecture validation of nested code. That is, it was signed with the same certificate.
5. Refuses if sTools can’t replace itself, because it runs from the DMG or from a temporary copy macOS made for an app opened straight out of Downloads (App Translocation).
6. Copies the app into a hidden staging folder beside the installed one, clears the quarantine flag, checks the copy’s signature again, and swaps it in with one `FileManager.replaceItemAt`. Nothing on disk changes until every check has passed.
7. Ejects the DMG and relaunches through `AppRelauncher`, a short shell loop that waits for this process to exit and then runs `open`.

There is no EdDSA check, because the code signature is the whole test, and no network is needed.

### The dev build

`scripts/build-app.sh <debug|release> --dev` builds `build/sTools Dev.app` beside `build/sTools.app` without touching it. The Info.plist marker `STVariant` = `dev` is what `AppVariant` reads. The dev build has the same bundle ID, the same `ducky8x` signature, the same settings folder and the same defaults domain, so its settings, saved data and macOS permissions carry over. That is also why only one of the two should be installed at a time. In the menu bar and Finder it is named sTools Dev, and its icon is the same mark in blue (`scripts/generate-icon.swift --tint blue packaging/dev`). With no feed or key it never updates itself; Settings ▸ Updates says so, and Install from DMG… takes only a dev DMG, as the normal build takes only a normal one. `scripts/build-dmg.sh --dev` makes `sTools-<version>-dev-macOS.dmg` with the volume name “sTools Dev”.

### Build, signing and the DMG

`swift build` makes a bare executable, not an app. `scripts/build-app.sh` assembles the app from it in a staging folder, `build/.staging`. The script embeds `Sparkle.framework` without its headers, removes the rpaths that point into this Mac’s build folders, fills `Info.plist` from `packaging/Info.plist` (version, build number, update key), and copies SwiftPM’s resource bundles (fonts, sounds, the key table) with fixed bundle identifiers. Then it compiles the icon with `actool` and signs everything inside out with the hardened runtime. `debug` builds for this Mac. `release` builds one universal binary (arm64 and x86_64, with Swift Build), saves the debug symbols into `build/dSYMs` and strips them from the app. `VERSION` and `BUILD_NUMBER` set the two numbers; the build number defaults to the number of commits on HEAD.

The app moves to `build/sTools.app` only once it is signed and every check has passed. A failed build never leaves a half-made or unsigned app under that name, and the app from the last good build stays where it was and keeps working. The script ends a failed build by saying that `build/sTools.app` was not replaced and which version and build it still is, so it can’t be taken for this run’s. The dev build stages in `build/.staging-dev`, so a normal build and a dev build running together can’t clear each other’s.

Signing looks for the code-signing identity named exactly `ducky8x` and signs with its hash, so no other identity on the Mac can be picked up. Without it the script stops. `--adhoc` is allowed for a debug build only, and macOS forgets that build’s permissions at every rebuild.

`scripts/build-dmg.sh` makes the styled disk image. `scripts/dmg-window.swift` draws the background (the wordmark, an arrow from the app to Applications, and the one-time Open Anyway steps) and writes the Finder window layout straight into the volume’s `.DS_Store`, so there is no Finder scripting and no Automation permission. The script verifies the image, mounts the result again to check the app’s signature and the layout, and moves the DMG into place only when every check passed. Each of its `hdiutil create` and `hdiutil convert` steps is stopped if it runs past ten minutes (`STOOLS_HDIUTIL_LIMIT` seconds, 600 by default). `hdiutil` waits for good when the disk image helper behind it is stuck, and macOS has no `timeout` command, so `run_with_limit` in `scripts/lib/run-with-limit.sh` does the stopping: `SIGTERM`, then `SIGKILL` five seconds later. The build then fails and says what to quit in Activity Monitor. The DMG itself isn’t signed: macOS checks the app’s signature, not the image’s.

#### The home-path guard

A macOS account name is often a real name, and compilers write absolute paths that start with it into debug info, resource-bundle accessors and build metadata. So release builds avoid those paths where they can and check for them everywhere else. Release builds use Swift Build, because the other build system’s `Bundle.module` accessor embeds the build folder’s path as a string that `strip` can’t remove. Debug info goes to a dSYM and is stripped, and resource-bundle identifiers are fixed.

What gets past that is caught by `scripts/check-no-home-paths.sh`, which compiles `scripts/check-no-home-paths.swift` once and scans everything that ships: file contents, names, symlink targets and extended attributes. The scan looks for home-folder paths, the account name, the full name and each part of it, and this Mac’s identifiers, after decoding UTF-16, percent escapes, base64 and hex and unpacking compressed streams. A finding names the file and a count, never the value. A hit fails the build before the app leaves the staging folder, so the last good app stays in place. The build scripts also filter their own output: `scripts/lib/mask-home.sh` passes everything they print, and everything the tools they run print, through a filter that shows the home folder as `~` and the names as placeholders. It hides the full name (in either order, run together or joined with a dot, underscore or hyphen), the account name, the home folder’s name, and each part of the full name of three letters or more on its own, so a surname alone is hidden too.

### Tests

The tests use Swift Testing (`import Testing`): more than 3,000 of them, in a test target per module. Things with side effects sit behind protocols with fakes: permission probing, ScreenCaptureKit, AVFoundation and Core Audio listings and captures, the hotkey registrar, Karabiner’s file system and command runner, the updater, disk-image mounting and signature checks, the Ninjabrain Bot copies scanner, the alarm player. So a test never triggers a macOS permission prompt, never registers a real hotkey, and never touches the real `~/.config/karabiner`, your settings, your recordings or a Ninjabrain Bot you have open. Each settings store points at a temporary folder, and an in-process `LocalSSEServer` on a free loopback port stands in for Ninjabrain Bot.

A test that orders a panel in does it on a synthetic display far off screen, at (−9000, −9000) in most suites, so no overlay reaches a real screen. The one test that has to order a panel over the real main display runs only with `STOOLS_TESTS_ON_SCREEN=1`. Rendering tests host views in an `NSWindow` that is never shown and draw them to bitmaps. The crosshair default is checked pixel by pixel on even and odd displays at 1x and 2x, and animations are checked with Reduce animations on and off. The recorder is tested with synthetic frames and audio written and read back through `AVAsset`. `MovieInfo`, which reads a movie back for those tests and for `Rewrapper`’s check, does its reads on a serial queue of its own and never on Swift’s concurrency pool. With every pool thread waiting in a read, CoreMedia’s own queues got no thread and no read ended; a Screen Recording test run once hung for twenty minutes that way. Test waits have a time bound that counts only awake time (`SuspendingClock`), and no test blocks the main actor.

The spec’s QA matrix (§9.2) lists what to check at each milestone and release, and its cells that need no hardware run as app-level tests. They put the app model over every real controller, on displays far outside the real screens and with a made-up Minecraft and Ninjabrain Bot. They check each tool alone and all together, one display and two, Minecraft windowed and full screen, Reduce animations and macOS’s Reduce motion each on its own, a Timer Overlay countdown that sleeps through zero, and hotkeys through a registrar that matches modifiers exactly, as Carbon does. One suite starts stand-in processes the way the official launcher and Prism Launcher start the game and lets the real kernel calls read them back. The build scripts have tests of this kind too: `StageAppTests`, `MaskHomeTests` and `RunWithLimitTests` run the real shell code in throwaway folders, with made-up names and `sleep` in place of `hdiutil`.

Four executables measure cost and aren’t tests. `RecordingBench` runs a recording from fake sources into a temporary folder (`swift run -c release RecordingBench`), and `NBBBench` times the Ninjabrain Bot scan and window reads on your own process table. `BackdropBench` makes videos and GIFs of its own, plays them with the backdrop’s own player and view in a window that is never ordered onto a screen, and prints the CPU the process spends, how busy the GPU is and the memory the animation holds. `OverlayBench` puts Crosshair, Timer Overlay (counting down), NBB Overlay (showing a result) and a still Window Backdrop up on a display outside every real screen, with a made-up Minecraft window and Ninjabrain Bot and a silent alarm. It prints sTools’ own CPU for each, alone and all together, against runs with every tool off. Neither sees the window server’s share or the game’s frame rate, so tools off against on in Minecraft stays a hand check. `scripts/smoke-update.sh` runs the updater end to end offline: two copies of a release build under a separate bundle ID, a local feed and a throwaway key. The run checks that a signed update installs and that a one-byte change or a missing signature is refused.

## Speedrun rules

Three tools touch the [Minecraft: Java Edition speedrunning rules](https://www.minecraftspeedrunning.com/public-resources/rules):

- The NBB Overlay shows only what Ninjabrain Bot itself shows, as rule A.11.7.a.i requires of tools that use its API. Its settings can hide or reformat information, never add to it.
- The Key Rebinder’s checker cites the remap rules (A.10.1–A.10.4) when a rebind may break them. The checker only advises; you decide.
- Timer Overlay has been checked against the rules and is legal. It never reads or acts on the game, and its placement guides help keep the hotbar, chat, toasts and your in-game timer visible.

## Privacy

sTools has no accounts, analytics or telemetry. It works with what is already on your Mac:

- **Minecraft’s window**, through Accessibility: where it is and whether it has focus, so the overlays and the backdrop can follow it.
- **Minecraft’s `options.txt`**, read only, to label keys with their game actions.
- **Karabiner-Elements’ `karabiner.json`**, to draw your rebinds. sTools writes to it only when you change something, after saving a backup in `~/Library/Application Support/sTools/Karabiner Backups` (the newest 20 are kept).
- **Ninjabrain Bot’s local API** at `localhost:52533`, read only.

Settings live in `~/Library/Application Support/sTools`, and recordings go to `~/Movies/sTools` unless you choose another folder. sTools goes online only to check GitHub for updates and to load a web page you add to a recording yourself. Copy Diagnostics puts a report on your clipboard and sends nothing.

## Build from source

You need Xcode’s toolchain; the Command Line Tools alone lack Swift Testing’s macros. Run these from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer   # or your Xcode

swift build                          # compile every module
swift test                           # run the tests
scripts/build-app.sh debug           # build/sTools.app for this Mac: the app you run
scripts/build-app.sh release         # the same as a universal (Apple silicon and Intel) release build
scripts/build-dmg.sh                 # wrap build/sTools.app in the styled DMG
scripts/build-app.sh release --dev   # build/sTools Dev.app, next to build/sTools.app (debug works too)
scripts/build-dmg.sh --dev           # its own DMG: sTools-<version>-dev-macOS.dmg
swift run -c release RecordingBench  # what a recording costs in CPU, with fake sources
swift run -c release NBBBench scan   # what the NBB Overlay’s Ninjabrain Bot scan costs
swift run -c release BackdropBench   # what an animated backdrop fill costs while it plays
swift run -c release OverlayBench    # what the overlays cost in CPU, with fakes, off screen
```

- To run the tests as Intel under Rosetta, use `xcodebuild test -scheme sTools-Package -destination 'platform=macOS,arch=x86_64' -derivedDataPath <a folder of your own>` and not `swift test`. The toolchain’s `swiftpm-testing-helper` is arm64-only, so `swift test` can’t open x86_64 test bundles, and `arch -x86_64 swift build` still builds for arm64; `swift build --arch x86_64` is the one that builds for Intel.
- `scripts/build-app.sh` signs only with a code-signing identity named `ducky8x` and refuses any other. On a Mac without it, run `scripts/make-signing-identity.sh` once to create a self-signed one, or pass `--adhoc` for a throwaway debug build. Release builds always need the identity.
- A build made from this repository carries the update feed and the public update key from `packaging/Info.plist` and `packaging/sparkle-public-key.txt`. If you fork it, change both and make your own key with `scripts/make-update-key.sh`, or your copies will offer this project’s releases as updates.
- Each change gets its own branch (`feat/`, `fix/`, `docs/`, `chore/`…), uses [Conventional Commits](https://www.conventionalcommits.org) and is merged into `main` with `git merge --no-ff`.

## License

sTools is released under the [MIT License](LICENSE).

It bundles a few things under their own licenses:

- The fonts Bodoni Moda, Source Serif 4 and DM Serif Display, under the SIL Open Font License 1.1 ([`OFL.txt`](Sources/STDesign/Resources/Fonts/OFL.txt)).
- [Sparkle](https://sparkle-project.org), the update framework, under the MIT License.

sTools is not an official Minecraft product and isn’t affiliated with Mojang, Microsoft, Ninjabrain Bot or Karabiner-Elements.
