# DiskMap

A fast macOS disk space visualizer: a zoomable treemap with a synchronized, size-sorted list.

Requires macOS 14 or later and the Swift 6 toolchain (the Command Line Tools are enough).

```sh
scripts/bundle.sh                 # builds build/DiskMap.app
open build/DiskMap.app
scripts/test.sh                   # runs the tests
swift run -c release diskmap-cli /Applications --png map.png   # totals, timing, optional image
```

## How it's organized

- `Sources/DiskMapCore`: the scanner (`getattrlistbulk`, parallel), flat file tree, treemap layout and drawing.
- `Sources/DiskMap`: the SwiftUI and AppKit app.
- `Sources/diskmap-cli`: scans from the terminal, for checking accuracy and speed.

## What sizes mean

Sizes are allocated space on disk. Hard links count once, symlinks aren't followed, and scans stay on the
starting volume. Scanning `/` covers the system and data volumes without counting firmlinked data twice.
APFS clones and snapshots aren't accounted for, so clones can be overcounted.

To read protected folders, grant DiskMap Full Disk Access in System Settings.
