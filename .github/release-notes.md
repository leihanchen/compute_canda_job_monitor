## Install (macOS 14+)

1. Download `SlurmMonitor-<version>-macOS.zip` below and unzip it.
2. Move `Slurm Monitor.app` to `/Applications`.
3. This build is ad-hoc signed (not notarized by Apple), so macOS blocks the first launch. Either right-click the app → **Open** → **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Slurm Monitor.app"
   ```

4. Open it. The app lives in the menu bar (no Dock icon). Look for `▶ 0  ⏸ 0` in the top-right.

`SHA256SUMS.txt` lists checksums for every asset. The `-source.zip` is the tagged source tree.
