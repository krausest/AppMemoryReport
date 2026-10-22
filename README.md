# app-memory-report

How much memory does Firefox *really* use? Or VS Code, Mail, or Safari?

A macOS command-line tool and a small SwiftUI app that answer this per app. Each app's figure includes all its helper, renderer, GPU and XPC processes, and memory those processes share is counted only once.

Read the story behind it: [25 Tabs, Four Browsers, One Sofa](https://krausest.github.io/AppMemoryReport/BrowserMemory.html), a memory comparison of Chrome, Firefox, Brave and Safari.

<img src="docs/screenshot.png" width="672" alt="App Memory Report window listing apps with their process count and memory, sorted by memory">

## Motivation

Modern apps are not one process. A browser with a dozen tabs easily runs 20–50 processes: content/renderer processes, a GPU process, network and utility helpers, and XPC services launched on its behalf. Activity Monitor lists them as separate rows, often with names like "Isolated Web Content" or "Helper (Renderer)" that don't make it obvious which app they belong to.

That makes it hard to answer a simple question: *what does this app cost me in RAM?*

Summing up the rows by hand doesn't give the exact value either. The processes of one app share some memory, and a naive sum counts every shared page once per process. Summing Activity Monitor's "Memory" column overstates a browser by a few percent (Brave: 4.7 %). Summing "Real Memory" (resident size) is far worse: it also counts shared code and mapped files in every process, and comes out at 2.7 times the actual value for Brave. See [docs/MeasurementExample.md](docs/MeasurementExample.md) for a worked example.

app-memory-report does both steps for you:

1. **Attribution:** every process is assigned to the app it belongs to, using the same "responsible process" relation Activity Monitor uses internally.
2. **Deduplication:** each app's processes are measured *together* with Apple's `footprint` tool, which counts memory shared between them only once.

## Usage

Requires macOS 14 or later and a Swift 6 toolchain (Xcode 16+). The CLI and the app are available in English and German and follow the system language.

### Command line

```sh
swift run app-memory-report          # your own processes

# all users' processes, with a User column: build as yourself, run only the binary as root
swift build && sudo .build/debug/app-memory-report
```

Don't use `sudo swift run`: it builds as root and leaves root-owned files in `.build` that break later builds.

```
App                                      Processes      Memory
Code                                            34  3420.2 MB
Firefox                                         23  2263.0 MB
Hermes                                          11   796.0 MB
Mail                                            14   692.0 MB
Finder                                           8   359.0 MB
…
--------------------------------------------------------------
Total                                          951 19937.3 MB
```

"Total" measures all processes in one run, so memory shared *between* apps is counted once there. That's why the rows can add up to slightly more than the total. A `*` marks values that are a plain sum without deduplication: footprint failed, or it was skipped because the processes could share at most 1 MB or 1 %.

### GUI

```sh
swift build && swift run AppMemoryReport   # run directly (the lock button needs the CLI built too)
scripts/make-app.sh               # build AppMemoryReport.app (ad-hoc signed)
open AppMemoryReport.app
```

The app ("App Memory Report", in German "Speicherverbrauch") shows the same per-app values in a sortable table, initially sorted by memory. It has:

- **Automatic refresh:** every 30 s by default; 5, 10, 30 or 60 s or manual can be picked in the toolbar.
- **Top 30 only** ("Nur Top 30"): on by default. Only the 30 largest apps are measured and shown, which saves a lot of CPU.
- **Search:** a field to filter rows by name.

Rows appear right away with a preliminary value ("≈", the plain sum of the kernel values) and are replaced as soon as each app is measured. Apps whose processes didn't change since the last refresh reuse their measured shared memory instead of running footprint again. Measuring pauses while the window isn't visible. With "Advanced", a Shared column shows how much less the row is than the sum of its processes in Activity Monitor, i.e. how much memory the plain sum counts more than once. A region shared by three processes counts twice there. The GUI leaves out the total. It shows only your own processes until you click the lock and enter an administrator password: the app then starts its bundled CLI as a root helper (`app-memory-report --serve`, via the standard password dialog) that measures all users' processes for it, and adds a User column. The helper talks to the app over a Unix socket in the app's private temp folder, accepts only measurement requests, and exits when you click the lock again or quit the app.

## How it works

```
snapshot processes → attribute to apps → measure each group → table
   (libproc)          (responsible PID,     (/usr/bin/footprint,
                       outermost .app)       in parallel)
```

**Snapshot** (`ProcessTable.swift`): lists all PIDs via libproc (`proc_listallpids`, `proc_pidinfo`, `proc_pidpath`). Processes of other users that refuse the full info without root, like the `login` between a terminal and its shell, are read with the short info. For each process it also asks the private libSystem function `responsibility_get_pid_responsible_for_pid` which process macOS holds responsible for it. For example, Safari is responsible for its WebKit XPC services even though `launchd` is their parent.

**Grouping** (`Grouping.swift`): each process follows its parent while the responsible process is an ancestor (or the process is responsible for itself), otherwise it jumps to the responsible process, up to a *root*. A command started in a terminal (Terminal, iTerm2, VS Code's terminal, …) is a root of its own: the child of the topmost shell with a controlling terminal, so a dev server shows up as its own row (named after its command line, e.g. `npm run dev`) instead of inside the terminal app. Roots of the same user inside the same `.app` bundle are merged by the **outermost** bundle, so nested helper apps (`Firefox.app/Contents/MacOS/plugin-container.app`, Electron helpers, …) count toward their main app. Each group is named after the bundle's display name. Processes outside any bundle each form a row named after their executable. While Safari runs, its background agents (sync, notifications, Safe Browsing, history) are added to it, and iTerm2 gets its session servers, including one left over from before an update.

**Measuring** (`Footprint.swift`): each group's PIDs are passed to a single `/usr/bin/footprint` run. Its *total footprint* is the group's physical memory with shared pages counted once. Footprint is the same metric Activity Monitor calls "Memory": dirty memory, plus compressed and swapped memory. The kernel sometimes charges a process for memory that footprint's region analysis counts as clean, e.g. OrbStack's helper for gigabytes of its mapped VM disk image. That difference is added per process, so the figures agree with Activity Monitor's, except that shared memory is counted once. The result never exceeds the plain sum of the kernel values. Single-process groups skip footprint and read the kernel value (`ri_phys_footprint`) directly. So do groups where all but the largest process together use at most 1 MB or 1 % (marked `*`). If footprint fails, or a process exits in the meantime and footprint's report includes processes that weren't requested, the row falls back to the plain per-process sum and is marked `*`. The groups are measured in parallel.

**Cost:** footprint is not cheap. Measuring all processes together for the total takes ~8 s and ~50 CPU-seconds on a busy machine. That's why the GUI skips the total and, by default, measures only the top candidates. Groups are first ranked by the cheap per-process sum, then footprint runs for the top 40, and more in steps of 10 until no unmeasured group can make it into the top 30. A first measurement costs ~1.5 s and ~11 CPU-seconds. Later refreshes reuse the shared memory measured for groups whose processes are unchanged (plain sum within 2 %, at most 5 minutes old) and cost well under one CPU-second when little changes. In practice, deduplication corrects less than 1 % for most apps and a few percent for browsers (Brave: 4.5 %), and an app's shared amount barely changes while its processes stay the same.

### Code layout

| Target | Contents |
|---|---|
| `MemoryCore` | process snapshot, grouping, footprint measuring and cache, `MemoryReport.measure` pipeline |
| `app-memory-report` | CLI: prints the report as a text table |
| `AppMemoryReport` | SwiftUI app: `Table`, refresh loop, toolbar, English/German string catalog |
| `MemoryCoreTests` | Swift Testing: grouping, footprint report parsing, top-N cut-off, cache (`swift test`) |

## Limitations

- macOS only. It relies on a private (but long-standing) libSystem function and on `/usr/bin/footprint`.
- Without root, only your own processes can be measured. Run the CLI binary with `sudo`; in the GUI, click the lock.
- Memory shared between *different* apps counts fully in each app's row.
