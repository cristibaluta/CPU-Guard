<p align="center">
  <img src="https://myimgs.org/storage/images/88983/readme-banner.png" alt="CPU Guard: the watchdog for your Mac's runaway processes" width="100%">
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-E8372C?style=flat-square"></a>
  <img alt="Platform: macOS" src="https://img.shields.io/badge/macOS-13%2B-2A1710?style=flat-square">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-FFB224?style=flat-square">
</p>

**CPU Guard** is a small menu bar app that watches your Mac's CPU and memory and speaks up the moment a process goes haywire. It shows you the culprit, and lets you pause, restart or kill it without opening Activity Monitor.

<p align="center">
  <img src="https://myimgs.org/storage/images/88981/alert-panel.png" alt="CPU Guard's Resource Hogs panel and a memory alert" width="760">
</p>

## Why

A runaway renderer, a stuck `ffmpeg`, a browser that quietly ate 6 GB: your fans tell you *something* is wrong, but not *what*. CPU Guard sits in the menu bar, notices, and puts the offender on screen with its recent CPU and memory history, so you can deal with it in one click.

It is deliberately **not** a full system dashboard. It does one job and stays out of the way (no Dock icon, no windows until you need them).

## Features

- **Resource Hog alerts.** When a process runs hot, a floating panel appears under the menu bar (over full-screen apps and on every Space) with CPU, memory and sparklines. It clears itself when things calm down.
- **Pause, don't panic.** Freeze a process with one click (`SIGSTOP`) and resume it later (`SIGCONT`). Handy for a build that's eating your video call.
- **Live process table.** Search by name, PID, parent or path. Sort by any column. Memory shows *start → now* with the delta, so leaks stand out.
- **Pin what matters.** Pinned processes stay on top.
- **Per-app memory alerts.** Set a limit for an app, counting its helper processes too (think browsers and Electron apps). Get a warning with **Quit** and **Restart** buttons when it crosses the line. It won't nag you while the app hovers around the limit.
- **Quit Together rules.** When the apps you choose quit, CPU Guard quits their companions after a delay (with an optional force-quit timeout). Ships with a rule that closes the Adobe Creative Cloud background apps after you close Photoshop, Illustrator and friends.
- **Restart App, Reveal in Finder, Kill and Force Kill** from a right-click on any process.
- **Privileged helper (optional).** Some processes, such as `WindowServer` and other root daemons, can't be read by a normal app. Register the helper to see their real numbers and to kill processes you don't own.
- **Launch at login**, from the menu bar icon's right-click menu.

## How it compares

CPU Guard complements the big monitors rather than replacing them.

| | **CPU Guard** | Activity Monitor | iStat Menus | Stats |
|---|:---:|:---:|:---:|:---:|
| Price / license | Free, MIT | Included with macOS | Paid | Free, MIT |
| Lives in the menu bar | ✅ | ❌ | ✅ | ✅ |
| Alert panel for the specific process that's running hot | ✅ | ❌ | Rule-based notifications | – |
| Pause / resume a process | ✅ | ❌ | – | – |
| Kill / force kill | ✅ | ✅ | – | ✅ |
| Per-app memory limit, helper processes included | ✅ | ❌ | – | – |
| Auto-quit companion apps | ✅ | ❌ | – | – |
| Full system dashboard (GPU, network, sensors…) | ❌ by design | Partial | ✅ | ✅ |

<sub>"–" means not a core feature or not verified. Comparison written from public information at the time of writing; corrections welcome via PR.</sub>
<!-- TODO before publishing: re-check iStat Menus / Stats / Activity Monitor columns. -->

## Install

> **Releases are coming soon.** Until then, build from source.

```bash
git clone https://github.com/<your-username>/CPU-Guard.git
cd CPU-Guard
open "CPU Guard.xcodeproj"
```

Build and run the **CPU Guard** scheme in Xcode. The icon appears in your menu bar.

### Enable the helper (optional)

1. Right-click the menu bar icon and choose **Helper Registered**, or press **Register Helper** in the popover.
2. If macOS asks, approve it in **System Settings → General → Login Items & Extensions**.

Without the helper, CPU Guard still works for every process your user can read. The helper adds root-owned processes and the ability to kill them.

## How it works

- Samples every running process every **10 seconds** using `proc_pidinfo` (CPU time deltas, resident memory).
- A process is flagged as a hog when it uses **more than 100% CPU** (a full core's worth) on a sample.
- Pause and resume use `SIGSTOP` / `SIGCONT`. Kill uses `SIGTERM`, Force Kill uses `SIGKILL`.
- The optional helper is a launch daemon registered through `SMAppService` and reached over XPC.
- No network code. CPU Guard doesn't phone home.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING](CONTRIBUTING.md) if you add one, and please read [SECURITY](SECURITY.md) before reporting anything about the helper.

## License

MIT. See [LICENSE](LICENSE).
