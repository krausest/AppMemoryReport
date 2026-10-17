# app-memory-report

How much memory does Firefox *really* use? Or VS Code, Mail, or Safari?

A macOS command-line tool and a small SwiftUI app that answer this per app. Each app's figure includes all its helper, renderer, GPU and XPC processes, and memory those processes share is counted only once.

## Motivation

Modern apps are not one process. A browser with a dozen tabs easily runs 20–50 processes: content/renderer processes, a GPU process, network and utility helpers, and XPC services launched on its behalf. Activity Monitor lists them as separate rows, often with names like "Isolated Web Content" or "Helper (Renderer)" that don't make it obvious which app they belong to.

That makes it hard to answer a simple question: *what does this app cost me in RAM?*

Summing up the rows by hand doesn't work either. The processes of one app share memory, and a naive sum counts every shared page once per process, so it overstates the total.

app-memory-report does both steps for you:

1. **Attribution:** every process is assigned to the app it belongs to, using the same "responsible process" relation Activity Monitor uses internally.
2. **Deduplication:** each app's processes are measured *together* with Apple's `footprint` tool, which counts memory shared between them only once.

## Usage

Requires macOS 14 or later and a Swift 6 toolchain (Xcode 16+). The CLI and the app are available in English and German and follow the system language.

### Command line

```sh
swift run app-memory-report          # your own processes
sudo swift run app-memory-report     # all users' processes
```

```
App                                      Processes      Memory
Code                                            34    3.34 GB
Firefox                                         23    2.21 GB
Hermes                                          11     796 MB
Mail                                            14     692 MB
Finder                                           8     359 MB
…
--------------------------------------------------------------
Total                                          951   19.47 GB
```

"Total" measures all processes in one run, so memory shared *between* apps is counted once there. That's why the rows can add up to slightly more than the total. A `*` marks values where deduplication wasn't possible and a plain sum was used instead.

### GUI

```sh
swift run AppMemoryReport         # run directly
scripts/make-app.sh               # build AppMemoryReport.app (ad-hoc signed)
open AppMemoryReport.app
```

The app ("App Memory Report", in German "Speicherverbrauch") shows the same per-app values in a sortable table, initially sorted by memory. It has:

- **Automatic refresh:** every 30 s by default; 5, 10, 30 or 60 s or manual can be picked in the toolbar.
- **Top 30 only** ("Nur Top 30"): on by default. Only the 30 largest apps are measured and shown, which saves a lot of CPU.
- **Search:** a field to filter rows by name.

Measuring pauses while the window isn't visible. The GUI shows only the current user's processes and leaves out the total.

## How it works

```
snapshot processes → attribute to apps → measure each group → table
   (libproc)          (responsible PID,     (/usr/bin/footprint,
                       outermost .app)       in parallel)
```

**Snapshot** (`ProcessTable.swift`): lists all PIDs via libproc (`proc_listallpids`, `proc_pidinfo`, `proc_pidpath`). For each process it also asks the private libSystem function `responsibility_get_pid_responsible_for_pid` which process macOS holds responsible for it. For example, Safari is responsible for its WebKit XPC services even though `launchd` is their parent.

**Grouping** (`Grouping.swift`): each process follows its responsible PID, or otherwise its parent, up to a *root*. Roots inside the same `.app` bundle are merged by the **outermost** bundle, so nested helper apps (`Firefox.app/Contents/MacOS/plugin-container.app`, Electron helpers, …) count toward their main app. Each group is named after the bundle's display name. Processes outside any bundle each form a row named after their executable. While Safari runs, its background agents (sync, Safe Browsing, history) are added to it.

**Measuring** (`Footprint.swift`): each group's PIDs are passed to a single `/usr/bin/footprint` run. Its *total footprint* is the group's physical memory with shared pages counted once. Footprint is the same metric Activity Monitor calls "Memory": dirty memory, plus compressed and swapped memory. Single-process groups skip footprint and read the kernel value (`ri_phys_footprint`) directly. If footprint fails, or a process exits in the meantime and footprint's report includes processes that weren't requested, the row falls back to the plain per-process sum and is marked `*`. The groups are measured in parallel.

**Cost:** footprint is not cheap. Measuring all processes together for the total takes ~8 s and ~50 CPU-seconds on a busy machine. That's why the GUI skips the total and, by default, measures only the top candidates. Groups are first ranked by the cheap per-process sum, then footprint runs for the top 40, and the 30 largest are shown. A refresh then costs ~2 s and ~14 CPU-seconds.

### Code layout

| Target | Contents |
|---|---|
| `MemoryCore` | process snapshot, grouping, footprint measuring, `MemoryReport.measure` pipeline |
| `app-memory-report` | CLI: prints the report as a text table |
| `AppMemoryReport` | SwiftUI app: `Table`, refresh loop, toolbar, English/German string catalog |

## Limitations

- macOS only. It relies on a private (but long-standing) libSystem function and on `/usr/bin/footprint`.
- Without root, only your own processes can be measured. The CLI accepts `sudo`; the GUI is limited to the current user.
- Memory shared between *different* apps (e.g. graphics buffers shared with another process) counts fully in each app's row.
