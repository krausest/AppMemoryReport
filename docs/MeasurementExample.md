# Measurement example: Brave

This page follows one measurement of Brave from the raw numbers to the row the app shows. Along the way it explains why the **Shared** column (memory removed by deduplication) is so small.

Sections 1–4 use a single `footprint` run on 2026-10-21 at 20:06 (Brave 155 with a few tabs open); section 5 uses a second snapshot of the main process at 20:32. MB means MiB (1,048,576 bytes), as in the app. The complete raw output (footprint's JSON and text report, `ps`, `vmmap`, and the app's own result) is in [raw_data.txt](raw_data.txt).

## 1. The group

Grouping assigns 22 processes to Brave: 12 of Brave's own processes, plus 10 macOS XPC services that Brave is *responsible* for (the open/save panel, Quick Look, video encoder/decoder, the 1Password browser helper, …).

| PID | Process | phys_footprint | private | shared regions |
|---:|---|---:|---:|---:|
| 48423 | Brave Browser Helper (Renderer) | 257.8 | 220.6 | 37.2 |
| 34575 | Brave Browser | 219.6 | 215.7 | 3.9 |
| 34581 | Brave Browser Helper (GPU) | 160.3 | 123.5 | 36.8 |
| 38146 | Brave Browser Helper (Renderer) | 72.8 | 70.4 | 2.4 |
| 34582 | Brave Browser Helper (Network) | 50.4 | 49.6 | 0.8 |
| 38158 | MTLCompilerService | 30.5 | 30.4 | 0.1 |
| 20791 | Brave Browser Helper (Renderer) | 28.2 | 27.0 | 1.2 |
| 34583 | Brave Browser Helper (Storage) | 27.8 | 27.2 | 0.5 |
| 13943 | com.apple.appkit.xpc.openAndSavePanelService | 26.4 | 26.1 | 0.3 |
| 38161 | Brave Browser Helper (Video Capture) | 26.0 | 25.4 | 0.6 |
| 38160 | Brave Browser Helper (Audio) | 23.2 | 23.0 | 0.3 |
| 34599 | com.apple.SafariPlatformSupport.Helper | 15.4 | 15.1 | 0.3 |
| 48426 | 1Password-BrowserSupport | 13.7 | 13.5 | 0.2 |
| 56476 | VTEncoderXPCService | 7.8 | 7.6 | 0.2 |
| 34600 | CredentialProviderExtensionHelper | 7.0 | 6.9 | 0.1 |
| 13944 | QuickLookUIService | 4.7 | 4.5 | 0.2 |
| 56475 | VTDecoderXPCService | 4.1 | 3.9 | 0.2 |
| 13945 | com.apple.CMExtensionBroker | 3.8 | 3.7 | 0.1 |
| 62959 | com.apple.audio.SandboxHelper | 3.2 | 3.2 | 0.0 |
| 34577 | chrome_crashpad_handler | 3.2 | 3.1 | 0.1 |
| 34585 | SetStoreUpdateService | 2.9 | 2.8 | 0.1 |
| 13946 | SetStoreUpdateService | 2.7 | 2.6 | 0.1 |
| | **Sum** | **991.3** | **905.6** | **85.7** |

- **phys_footprint** is the kernel's value per process (`ri_phys_footprint`, Activity Monitor's "Memory" column). Its sum, 991.3 MB, is the *plain sum* the app uses for ranking and the "≈" preliminary value.
- **private** and **shared regions** split that value according to `footprint`'s report (see below): dirty memory only this process maps, and dirty memory in regions that other processes of the group map too. The two add up exactly to phys_footprint for every process.
- The **85.7 MB** sum of the last column counts a shared region once *per process that maps it*. A region shared by two processes is in there twice. It is not the amount of shared memory. That amount is 41.2 MB (section 2).

## 2. What `footprint` reports, and where to find each number

The app runs `footprint` with all 22 PIDs at once:

```sh
footprint --noCategories -f bytes -j out.json -p 13943 -p 13944 … -p 62959
```

For this page it was run without `--noCategories`, so the report also contains the breakdown. Its text output is section 3 of [raw_data.txt](raw_data.txt), and the JSON from the same run is section 4.

### The text report

The report has one block per process, then a block for the dyld shared cache, then a summary. Here's the block of the renderer 48423, shortened, with line numbers from raw_data.txt:

```text
319  Brave Browser Helper (Renderer) [48423]: 64-bit    Footprint: 270338472 B     ← phys_footprint (257.8 MB)
     …  one line per category of private memory  …
351  231279016 B   102842368 B   178274304 B      16909    TOTAL                ← private dirty (220.6 MB)

353  Shared with Brave Browser Helper [34581], … (8 processes):
360      32768 B     3014656 B           0 B         18    TOTAL
     …
413  Shared with Brave Browser Helper [34581]:
418   37142528 B           0 B           0 B         13    TOTAL                ← 35.4 MB shared with the GPU process
     …  more "Shared with" sections, together 39059456 B (37.2 MB)  …
```

Lines 351–418 are "Dirty / Clean / Reclaimable / Regions / Category" columns. Only the **Dirty** column counts toward the footprint. The block's header equals the private TOTAL plus the Dirty TOTALs of all its "Shared with" sections: 231,279,016 + 39,059,456 = 270,338,472 B.

The same 35.4 MB region shows up again in the GPU process's block. The process names in "Shared with" are always the *other* processes:

```text
782  Brave Browser Helper [34581]: 64-bit    Footprint: 168085544 B
817  129501224 B    17006592 B    23265280 B       3808    TOTAL                ← private dirty of 34581
     …
872  Shared with Brave Browser Helper (Renderer) [48423]:
877   37142528 B           0 B           0 B         13    TOTAL                ← the same 35.4 MB again
```

After all 22 blocks comes the summary. It counts every region once:

```text
3239  Summary Footprint: 992843616 B                                            ← 946.8 MB
3297  992843616 B   504152064 B   499384320 B     204570    TOTAL
```

### Where each number comes from

| MB | Bytes | How to get it from the text report | JSON (section 4) |
|---:|---:|---|---|
| **991.3** | 1,039,472,480 | Sum of the 22 `Footprint:` headers | Σ `processes[].footprint` |
| **905.6** | 949,606,240 | Sum of the first `TOTAL` line (private) of each of the 22 blocks | Σ `processes[].categories[*].dirty` |
| **85.7** | 89,866,240 | Sum of the Dirty `TOTAL` of every "Shared with" section in the 22 blocks, so each region once per process that maps it | Σ `shared[*].categories[*].dirty` |
| **946.8** | 992,843,616 | `Summary Footprint:` (line 3239) | `total footprint` |
| **41.2** | 43,237,376 | Not printed. It's `Summary Footprint` − private: 992,843,616 − 949,606,240 | `total footprint` − Σ private |
| **44.5** | 46,628,864 | Not printed. It's the sum of the headers − `Summary Footprint`: 1,039,472,480 − 992,843,616 | Σ `footprint` − `total footprint` |

So the numbers fit together like this:

```text
plain sum   991.3 = private 905.6 + shared, once per process that maps it   85.7
footprint   946.8 = private 905.6 + shared, each region once                41.2
                                                              difference    44.5 = 85.7 − 41.2
```

That 44.5 + 41.2 = 85.7 is no coincidence. The plain sum and the deduplicated total contain exactly the same private memory (905.6 MB), so their difference can only come from the shared part. It's the copies of shared regions beyond the first one. In the example region: it's 35.4 MB of memory, counted twice in the plain sum (lines 418 and 877) and once in the total, so it contributes 70.8 MB to the 85.7, 35.4 MB to the 41.2, and 35.4 MB to the 44.5.

You can roughly rebuild the 41.2 MB from the "Shared with" sections: group them by set of processes and take each group's value once. That gives 43,106,304 B, 128 KB less than the exact value. The small gap is there because footprint deduplicates per memory object, and a few regions look slightly different from each process that maps them. The exact value is only available as the difference above.

### The JSON

The app reads the JSON. It holds the same data, shortened:

```jsonc
{
  "processes": [
    {
      "name": "Brave Browser Helper (Renderer)", "pid": 48423,
      "footprint": 270338472,                     // 257.8 MB
      "auxiliary": { "phys_footprint": 270338472, "phys_footprint_peak": 499419536 },
      "categories": { "Malloc Small": { "dirty": …, "clean": …, "swapped": … }, … }  // private regions only
    },
    …
  ],
  "shared": [                                     // regions mapped by more than one of the processes
    { "pids": [34581, 48423], "specific_to_pid": 48423,
      "categories": { "Untagged": { "dirty": 37142528, … } } },   // 35.4 MB, as seen by the renderer
    { "pids": [34581, 48423], "specific_to_pid": 34581,
      "categories": { "Untagged": { "dirty": 37142528, … } } },   // the same memory, as seen by the GPU process
    …
  ],
  "summary": { "total": { "dirty": 992843616, "clean": 504152064, … } },
  "total footprint": 992843616                    // 946.8 MB
}
```

- `footprint` per process equals the kernel's `phys_footprint` and the text report's `Footprint:` header. It is that process's private dirty memory (compressed memory included) plus its view of every shared region.
- `categories` holds only the private regions (the first TOTAL of a text block).
- `shared` lists each shared region once per process that maps it (`specific_to_pid`), like the "Shared with" sections.
- `total footprint` is the `Summary Footprint`, which counts every region only once: **905.6 MB private + 41.2 MB shared = 946.8 MB.**

## 3. What the app computes

`Footprint.parseReport` reads these values from the JSON:

| | Value |
|---|---:|
| Σ `auxiliary.phys_footprint` (plain sum) | 991.3 MB |
| `total footprint` | 946.8 MB |
| Σ excess (`phys_footprint − footprint`, per process) | 0.0 MB |
| **Row = min(total + excess, plain sum)** | **946.8 MB** |
| **Shared column = plain sum − row** | **44.5 MB** |

All 22 processes have an excess of 0, because footprint sees everything the kernel charges. Excess only matters for cases like OrbStack's mapped disk image. The app's own measurement code and a CLI run, both a few seconds apart from this run, also gave `Brave Browser  22  946.8 MB`.

The Shared column is the 44.5 MB from section 2: the 85.7 MB of shared regions in the per-process values shrinks to 41.2 MB when each region is counted once. That difference, **44.5 MB (4.5 % of the plain sum)**, is what deduplication removes. Most of it comes from a single region: **35.4 MB shared by the renderer 48423 and the GPU process 34581**. That's Chromium shared memory used to hand rendered content to the GPU process. The rest is made up of small regions (≤ 1 MB each) that the browser process shares with its helpers.

## 4. Why "Shared" is so small

The expectation that helper processes share a lot of memory is correct. That memory just isn't in `phys_footprint` in the first place:

- **Clean, file-backed pages are not counted.** Code (`__TEXT`) and the dyld shared cache are shared by every process, and so are fonts and other mapped files. They're clean pages backed by files, and the kernel doesn't charge them to any process's footprint. In this run, footprint saw 480.8 MB of such clean memory across the group. It shows up in the "clean" column and is not part of anyone's footprint.
- **Owned memory is charged to its owner.** IOSurfaces, GPU buffers and similar memory have a single owning process. Mapping it into another process doesn't charge it again.
- **Only shared *dirty anonymous* memory is charged to every mapper.** This kind of memory comes from things like `mmap(MAP_SHARED|MAP_ANON)` or Mach memory entries, which is how Chromium's shared memory works. It's the only kind that footprint has to deduplicate. Here it's 44.5 MB.

For comparison, the sum of RSS (Activity Monitor's "Real Memory", `ps -o rss`) of the same 22 processes was **2572.3 MB**. RSS counts every resident page a process maps, including the clean shared pages above, once per process. That number really is badly inflated by double counting. A naive sum of phys_footprint (991.3 MB) is only 4.7 % above the deduplicated value.

## 5. Activity Monitor's inspector: 525 MB vs. 220 MB

Double-click Brave's main process (34575) in Activity Monitor and open the "Memory" tab, and you'll see very different numbers from the ones above:

| Inspector (English / German) | Value | What it is |
|---|---:|---|
| Real Memory Size / Physischer Speicher | 524.9 MB | RSS: every page currently in RAM and mapped by the process |
| Virtual Memory Size / Virtueller Speicher | 515.25 GB | Reserved address space. Mostly empty reservations, costs nothing |
| Shared Memory Size / Gemeinsamer Speicher | 379.6 MB | Resident pages in memory objects that more than one process maps |
| Private Memory Size / Privater Speicher | 243.8 MB | Resident pages in memory objects only this process maps |

None of these is `phys_footprint`. In the main window, the **"Memory" ("Speicher") column** shows phys_footprint, and that column shows about 220 MB for the same process. The inspector's "Real Memory Size" is the same value as `ps -o rss`. Activity Monitor doesn't document how it computes "Shared" and "Private". They are counted per memory object, not per page of this process, so they aren't a split of RSS: 243.8 + 379.6 = 623.4 MB, which is more than the RSS of 524.9 MB.

### Where the 525 MB come from

To see what RSS contains, I took a second snapshot of process 34575 with `vmmap` (per-region resident, dirty and swapped sizes) and `footprint` a few minutes later. RSS was 525.6 MB at that point. Grouped into page kinds:

| Pages | MB | in phys_footprint | in RSS |
|---|---:|:-:|:-:|
| PartitionAlloc heap (Chromium's allocator, vmmap "App-Specific Tag 14"), dirty | 183.3 | ✓ | ✓ |
| Other dirty memory: Brave's `__DATA` segments, malloc, stacks, shared memory | 26.1 | ✓ | ✓ |
| dyld shared cache, pages this process has written to (`__DATA`, `__AUTH`, …) | 6.2 | ✓ | ✓ |
| *Subtotal: resident dirty memory* | *215.7* | | |
| Compressed dirty memory (not resident) | 6.2 | ✓ | – |
| PartitionAlloc heap, freed but still resident ("reclaimable") | 56.0 | – | ✓ |
| Code of the Brave binaries (`__TEXT`, almost all of it the 241 MB Brave Browser Framework) | 121.2 | – | ✓ |
| Mapped files: `resources.pak`, `icudtl.dat`, the profile's SQLite databases (History, Favicons, …), GPU shader caches, Safe Browsing lists | 67.8 | – | ✓ |
| Other clean pages | 0.6 | – | ✓ |
| Clean pages of the dyld shared cache in this process's page tables (the remainder) | 64.3 | – | ✓ |
| **Total** | | **≈ 219.1** | **525.6** |

All rows except the last come straight from vmmap's region list. The last row is what's left of RSS after the other rows. vmmap reports the shared cache's resident size for the whole system (1148.6 MB, the same in every process), not for one process, so this can't be read off directly. It's the plausible explanation, though: for `/bin/sleep`, which touches almost nothing, RSS is 1.1 MB, while vmmap still shows 224.5 MB of the shared cache as resident. So RSS includes only the shared-cache pages the process itself has used.

The phys_footprint column adds up to 215.7 + 6.2 = 221.9 MB, while the kernel reports 219.1 MB. vmmap and the kernel's accounting disagree by those 2.8 MB, for example over shared memory that another process owns.

In short, the two values for Brave's main process differ by 306 MB, and none of that difference is memory Brave has written to:

- **≈ 253 MB is clean, file-backed pages.** That's code, mapped files and the shared cache. Every byte of it is an exact copy of a file on disk.
- **56 MB is memory Brave has already freed.**
- Going the other way, 6.2 MB of compressed memory counts in phys_footprint but not in RSS.

## 6. Why RSS is the wrong number for "how much memory does this app use?"

RSS answers a different question: *which pages happen to be in RAM and mapped by this process right now?* For judging what an app costs, that is misleading in five ways.

1. **Clean pages are a cache, not usage.** Code, mapped files and the shared cache are byte-for-byte copies of files on disk. When RAM gets tight, the kernel simply drops them, without writing anything, and reads them back from disk the next time they're needed. As long as nobody else needs the RAM, they stay and inflate RSS. As soon as someone does, they disappear. RSS therefore depends on the state of the whole system, not just on the app. In process 34575 that's about 253 MB, nearly half of its RSS.

2. **Shared pages count in every process.** The 241 MB Brave Browser Framework is a single file. Its code exists once in RAM, but every Brave process that has run a piece of it counts those pages in its own RSS. The same goes for `resources.pak`, the ICU data and the dyld shared cache, which every process on the Mac uses. That's why the RSS of Brave's 22 processes adds up to 2572.3 MB, while the deduplicated footprint is 946.8 MB. Many of these pages don't really belong to Brave at all: the shared cache's copy of AppKit or libSystem would be in RAM even if Brave weren't running.

3. **Freed memory still counts.** When PartitionAlloc frees pages, it tells the kernel that it may reclaim them (`madvise`). They stay mapped and resident until the kernel needs the RAM, but they don't count toward the footprint anymore. That's 56 MB in RSS that the app is no longer using.

4. **Compressed memory drops out.** Under memory pressure, macOS compresses dirty pages that haven't been used recently. They leave RSS, even though the app still needs them, the compressed data takes up RAM, and every access has to decompress them first. RSS goes down exactly when memory gets tight, without the app needing any less. phys_footprint counts compressed pages at their original size.

5. **macOS itself uses phys_footprint.** Activity Monitor's "Memory" column and Xcode's memory gauge show it, and the system enforces per-process memory limits against it. It's the number that shows which app causes memory pressure.

phys_footprint, in contrast, counts the memory that only exists because the process exists and can't simply be dropped: written (dirty) memory, plus compressed memory, plus memory the process owns such as graphics buffers. A group's sum still counts shared dirty memory once per process, and that's the part footprint deduplicates (section 3).

RSS isn't meaningless: clean pages do take up RAM, and an app that keeps a lot of code hot does add to the system's working set. But that memory can't be attributed to a single app, it's freed instantly under pressure, and it's counted many times over in any sum. It's not a useful answer to "which browser needs the least memory?".

## Reproducing it

```sh
# PIDs of the group: the app's grouping (or, roughly, pgrep -f "Brave Browser" plus its XPC services)
footprint -f bytes -j brave.json -p <pid> -p <pid> …
```

Then compare `total footprint` with the sum of `processes[].footprint`, and look at the `shared` array for the regions behind the difference.
