## Install (macOS 14+)

1. Download **`SlurmMonitor-<version>-macOS.dmg`** below and open it.
2. Drag **Slurm Monitor.app** onto the **Applications** shortcut in the window, then eject the disk image.
3. This build is ad-hoc signed (not notarized by Apple), so macOS blocks the first launch. Either right-click the app in Applications → **Open** → **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Slurm Monitor.app"
   ```

4. Open it. The app lives in the menu bar (look for `▶ 0  ⏸ 0` in the top-right) and also shows a Dock icon.

## Assets

| File | Contents |
|---|---|
| `SlurmMonitor-<version>-macOS.dmg` | The app (what most people want) |
| `compute_canada_job_monitor-<version>-source.zip` | Source code at this tag (no app inside) |
| `SHA256SUMS.txt` | Checksums for the files above |
