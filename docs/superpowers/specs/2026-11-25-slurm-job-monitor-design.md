# Slurm Job Monitor — Menu-bar Floating Panel (Design)

Date: 2026-11-25 · Status: draft for approval (verified & refined)

## 1. Intent

A macOS menu-bar app, styled like **Zest** (menu-bar summary → floating rounded panel with header, tabs, cards), that shows the user's Slurm jobs on all their clusters at a glance — essentially what `sq` shows on each Alliance (Compute Canada) cluster, merged into one view.

**Why:** the user wants to see "what's running / waiting" when they open the panel, without logging into each cluster. The hard part is SSH: Alliance clusters require MFA (Duo/YubiKey), and SSH sessions drop (sleep, network change), forcing repeated MFA logins.

**Primary goal: minimise reconnections (MFA logins).** Zero reconnections cannot be guaranteed on the shared-connection path (a dropped TCP connection always needs a new MFA login); the design makes reconnections rare, explicit, and cheap.

## 2. Goals / Non-goals / Anti-goals

Goals
- See all queued/running jobs across clusters in one floating panel, on demand.
- Show the **last 3 recently ended jobs** (across all clusters) with their final state.
- Reuse an authenticated SSH connection for as long as it lives, and keep it alive as long as possible; never ask for MFA unless the user clicks to log in.
- Work on a fresh Mac with **no** cluster config: one username + one MFA approval per cluster to get going.
- Universal: any Slurm cluster reachable over SSH; Alliance is a built-in preset. *(Builder's call: user asked for "more universal"; plain `squeue` makes this cheap.)*
- Leave a clean extension point for **robot (automation-node) connections**, to be added soon.

Non-goals (this version)
- Any job actions (cancel, hold, resubmit). **Panel is read-only** (user decision).
- Robot-node connections (deferred; interface reserved — §5.3).
- Push notifications on job state changes; always-on monitoring.
- A remote relay / always-on server (user ruled this out).
- Windows/Linux.

Anti-goals (failure even if it "works")
- The app firing MFA pushes / login prompts on its own (background refresh, wake, network change).
- A blank panel when a cluster is unreachable — last known data stays visible, marked stale with its age.
- Storing passwords or MFA codes; handling private-key contents outside `ssh-keygen`/ssh-agent.
- Editing the user's `~/.ssh/config`, or closing SSH connections the user is using.

## 3. Constraints and verified facts

Development machine
- macOS 27, Apple Silicon, Swift 6.3, **Command Line Tools only (no Xcode)**, OpenSSH 10.5. Project folder is empty (not yet a git repo).

Alliance / SciNet facts (checked against Alliance & SciNet docs, 2026-11-25)
- MFA is mandatory on login nodes; there is **no server-side MFA session caching**. Alliance's recommended way to reduce prompts is client-side `ControlMaster`/`ControlPersist`.
- nibi, fir, narval, rorqual, tamia, killarney accept **password or SSH key**, then MFA.
- **Trillium / trillium-gpu (SciNet) disable password login: SSH key only**, uploaded via CCDB, and Trillium access must be requested in CCDB first. New CCDB keys take a while to propagate.
- Robot/automation nodes: key must be uploaded via CCDB and carry `restrict`, `command="…"`, `from="…"` (wildcards allowed); dedicated key per use. (Deferred.)
- `sq` is an Alliance-only wrapper around `squeue`; the app uses plain `squeue`/`sacct`.

Example existing setup (the author's Mac — must keep working, but the design does not depend on it)
- `~/.ssh/config` has a top-of-file `Match final host *.alliancecan.ca,… exec "~/.ssh/cluster-mfa-macos.sh …"` block setting `ControlMaster auto`, `ControlPath ~/.ssh/cmfa-%C`, `ControlPersist yes`. The script fails the `Match` for `-G`/`-O` commands, treats `BatchMode=yes` calls as silent, and stops stale masters with `-O stop`.

## 4. Approaches considered

| | Approach | Trade-off | Outcome |
|---|---|---|---|
| A | **Per-cluster connection chain** on the Mac: (robot, later) → reuse live shared SSH connection → otherwise stale data + "Log in" | No extra infrastructure; after long sleep / network change, one MFA per cluster | **Chosen** |
| B | A + fixed-IP relay host polling with robot keys | Near-zero logins anywhere, but needs an always-on reachable host | Rejected — no suitable host |
| C | Cluster-side `scrontab` pushing `squeue` output to an external endpoint | Needs outbound endpoint and scrontab on every cluster; privacy | Dropped |
| — | mosh / Eternal Terminal to survive roaming | Needs server daemons on login nodes; built for interactive terminals | Dropped |

## 5. Design

### 5.1 Tech stack (builder's call, stated)
- Native **Swift + SwiftUI**, `MenuBarExtra` with `.window` style for the floating panel; agent app (`LSUIElement`, no Dock icon). Deployment target macOS 14+.
- **Swift Package Manager** + a small script that assembles the `.app` bundle (Info.plist, icon) — no Xcode needed.
- Distribution (this version): the user's own Macs, ad-hoc code-signed, Apple Silicon (universal if easy). Developer ID signing / notarization later.
- Uses the system `/usr/bin/ssh` and `ssh-keygen`; no SSH library.

### 5.2 Cluster configuration (app-owned)
- Stored in Application Support (JSON), **not** read live from `~/.ssh/config`.
- Per cluster: display name, host, username, optional SSH alias, optional identity file, enabled flag, ordered connection methods (today `[sharedSSH]`; later `[robot, sharedSSH]`), and per-preset hints (e.g. `requiresKey: true` for Trillium).
- Ways to add (see §6 for the first-run flow): **Alliance preset** (built-in, easily-updated list: nibi, fir, narval, rorqual, trillium, trillium-gpu, tamia, killarney, …; one username for all), **Import from `~/.ssh/config`** (parse `Host`/`HostName`/`User`; preselect Alliance/SciNet domains), **Custom host**.
- **trillium and trillium-gpu are separate clusters** (user decision; different login hosts `trillium.scinet.utoronto.ca` / `trillium-gpu.scinet.utoronto.ca`). Every configured cluster is queried and counted independently; no cross-cluster job de-duplication.

### 5.3 Connection layer and the robot extension point
- Protocol (names indicative): `ClusterTransport { kind; func probe() async -> TransportState; func run(_ script: String, timeout:) async throws -> Output }`.
- `ConnectionChain` tries each enabled method in order and uses the first usable *without user interaction*. Transports never prompt.
- **Implemented now:** `SharedSSHTransport`. **Reserved:** `RobotTransport` (dedicated restricted key, forced `command`, `from` IP rule). Settings model and UI already carry a per-cluster method list and a "via shared / via robot" label, so adding it is purely additive. No robot code or setup UI in this version.

### 5.4 Shared SSH connection: reuse, log in, never kill

*Principle: one connection per cluster, shared both ways between the app and the user's Terminal; a login in either place saves a login in the other.*

- **Per-cluster generated SSH config.** App ssh calls use `-F <app-generated file>`, so `Match exec` scripts in the user's config never run on app calls (no surprise popups). Each entry is derived from `ssh -G <alias-or-host>` (so the user's normal settings — HostName, User, Port, IdentityFile, IdentityAgent, ProxyJump, UseKeychain… — carry over), then app-controlled options are set on top (ControlPath, ControlMaster, keep-alives, BatchMode for queries). Regenerated when the cluster is edited or `~/.ssh/config` changes.
- **Shared socket path.** Per cluster:
  1. If the user's config sets a `ControlPath` for that host — including inside `Match` blocks — use **the same path**. Find the raw template by parsing the config text (because `Match exec` blocks may not evaluate under `ssh -G`, as in the example setup), then expand it with `ssh -G -o ControlPath=<template> <alias-or-host>` and read the `controlpath` line (verified: `~/.ssh/cmfa-%C` for nibi → `/Users/mac/.ssh/cmfa-a906e9a0…`).
  2. Otherwise use the app's own socket directory (short path; Unix socket paths are length-limited). Cluster settings offer a copyable `~/.ssh/config` snippet so Terminal can reuse it. The app never writes that file.
- **Reuse check:** `ssh -F <generated> -O check`. Live → use it, whoever created it.
- **App-started master** (only after the user clicks Log in): `ControlMaster yes`, `ControlPersist yes`, keep-alives per §5.4a, at the resolved shared path.
- **Queries:** always `BatchMode=yes`, `ControlMaster=no`, short connect timeout, overall timeout ≈15 s. Failure/timeout → cluster **stale**; never a login.
- **Login (only on user click):** an in-app login sheet runs the master `ssh` in a pseudo-terminal and shows its prompts: host-key confirmation (first contact), key passphrase or password if asked, and the MFA menu (Duo push / passcode / YubiKey). The user types or clicks; nothing typed is stored. Success → sheet closes, cluster refreshes.
- **Never kill connections.** If a stale master holds the socket, use `ssh -O stop` (frees the socket; existing Terminal sessions on it continue), never `-O exit`. Never close a live, working connection.
- **"Log in to stale clusters":** logs into stale clusters one after another (one MFA approval each).
- **Wake / network change** (`NWPathMonitor`, workspace wake notification): silent re-probe only; never log in.
- **Clear error states** (shown per cluster with a one-line hint): needs login · needs SSH key (`Permission denied (publickey)` on key-only hosts) · no access (account not enabled on this cluster in CCDB) · unreachable · MFA denied / timed out · Slurm command failed.

#### 5.4a Keeping connections alive (user decision)
Goal: keep each live connection open as long as physically possible.
1. **SSH keep-alive messages:** `ServerAliveInterval 30`, `ServerAliveCountMax ≈ 20` on the master. A tiny encrypted no-op every 30 s defeats the cluster's idle timeout and router/NAT idle drops (often 5–30 min); the high count lets the master ride out short silences (≈10 min) instead of giving up.
2. **Check-in command:** every ~5 min, a harmless `true` through each live connection, including clusters with no jobs, so sites that watch real session activity also see it. Merged with the background refresh (a refresh counts as a check-in): at most one round-trip per cluster per interval. Never opens a new connection or triggers a login.
3. **"Stay awake while plugged in" — off by default:** when on, holds a macOS power assertion preventing *idle* system sleep (`PreventUserIdleSystemSleep`), only on AC power and only while ≥1 connection is live. Released on battery, when disabled, or on quit. Cannot prevent lid-close sleep (unless an external display is attached); the display may still sleep.
4. **Known limits (in the UI help text):** long sleep, lid closed, or Wi-Fi/VPN/IP change still end connections; only the future robot path survives those.

| Situation | Connection survives? |
|---|---|
| Awake, same network, hours idle | ✅ keep-alives + check-ins |
| Short sleep, same network | 🟡 usually |
| Idle sleep while plugged in | ✅ with "Stay awake" |
| Lid closed / long sleep | ❌ |
| Wi-Fi / VPN / IP change | ❌ (robot path later) |

### 5.5 Data collected per refresh (one SSH round-trip per cluster)
One remote shell snippet returning delimited sections:
1. `squeue -u $USER -h` with a fixed, delimiter-separated format: job ID, name, state, partition, account, elapsed, time limit, nodes, CPUs, memory, GPUs/GRES (TRES), reason / node list, submit time, start time, work dir.
2. `squeue -u $USER --start -h` — estimated start for pending jobs (may be N/A).
3. `sacct -u $USER -X -n -P -S now-7days` — ended jobs: ID, name, state, exit code, end time, elapsed.
- Parsing tolerates missing fields / older Slurm (show "—"). Array and het-job IDs (`123_4`, `123+0`) kept as strings.
- Results + timestamp cached to disk per cluster, so stale data survives app restarts.

### 5.6 Refresh policy
- On panel open: refresh clusters whose data is older than ~60 s.
- Background: every ~5 min (doubles as the check-in, §5.4a), **only** via methods usable without interaction.
- Manual ⟳ in header. Clusters refresh in parallel and update independently. No refresh runs on a cluster while its login sheet is open.

### 5.7 UI (approved sketch)

Menu bar: `▶ 5  ⏸ 3` (running / pending across clusters); small orange dot if any cluster is stale.

```
┌──────────────────────────────────────────┐
│ Slurm Jobs · leihan        ● 6/8 live    │
│ Updated 2m ago                     ⟳     │
│ [ Overview ]   Jobs    Clusters          │
├──────────────────────────────────────────┤
│ ▶ 5 Running  ⏸ 3 Pending   GPUs in use 12│
├──────────────────────────────────────────┤
│ Ending soon                              │
│ nibi   train_llm   ████████░░ 21h/24h    │
├──────────────────────────────────────────┤
│ Waiting                                  │
│ narval  eval_big   Priority  ~starts 3h  │
├──────────────────────────────────────────┤
│ Recently ended (last 3)                  │
│ fir   sweep_06  ✓ Completed   12m ago    │
│ nibi  test_x    ✗ Failed (1)   2h ago    │
├───────────────────┬──────────────────────┤
│ ● nibi   3▶ 0⏸   │ ● fir     1▶ 2⏸      │
│ ◐ narval 1h old   │ ○ tamia   not set up │
└───────────────────┴──────────────────────┘
│                               ⚙    ⏻     │
```

- **Overview:** totals; "Ending soon" (running jobs by remaining time); "Waiting" (pending jobs, reason + est. start); **"Recently ended" — last 3 ended jobs across all clusters by end time**, final state (Completed / Failed + exit code / Timeout / Out of memory / Cancelled) and how long ago; cluster grid (● live, ◐ stale with age, ○ not configured / needs login / error).
- **Jobs:** queued/running jobs grouped by cluster; row = state pill, name, ID, elapsed/limit bar, resources (`4×GPU · 32 CPU · 128G`); pending rows show reason + est. start; click to expand partition, account, nodes, submit time, work dir.
- **Clusters:** per cluster: state / error hint, method in use (shared now; robot later), last success, **Log in**, edit/remove; "Add cluster", "Log in to stale clusters".
- **Settings (⚙):** refresh interval, "Stay awake while plugged in", launch at login.
- Footer: ⚙, quit ⏻. Style follows Zest: light rounded cards, coloured accents, compact type; dark mode supported.

## 6. First run on a fresh Mac

Assume nothing exists: no `~/.ssh/config`, possibly no SSH key, empty `known_hosts`. Target: type **one username**, approve MFA once per cluster.

1. **Welcome (empty panel):** "Add your clusters" — *Alliance clusters* (default), *Import from SSH config* (shown only if the file has hosts), *Custom host*.
2. **Alliance clusters:** one **Alliance username** field (the cluster login name, not email or CCRI) + checklist of preset clusters (all ticked). One username fills every cluster; per-cluster overrides in Clusters → edit.
3. **SSH key check:**
   - Use an existing key if found (`~/.ssh/id_ed25519`, `id_ecdsa`, `id_rsa`, or any key in ssh-agent).
   - Otherwise offer **"Create a key for me"**: `ssh-keygen -t ed25519` (optional passphrase, saved via macOS Keychain with `UseKeychain`/`AddKeysToAgent`), then show the public key with **Copy** and **Open CCDB SSH keys page**, noting keys take a while to reach clusters.
   - Skipping is allowed: password-capable clusters log in with password + MFA; key-only clusters (Trillium) show "needs SSH key" until a key works. Trillium also notes "request access in CCDB" if access is denied.
4. **First login:** "Log in to all" walks the selected clusters one by one in the login sheet: host-key fingerprint → trust (saved to `~/.ssh/known_hosts`) → password/passphrase if asked → MFA. Each success turns the cluster ● live and fetches jobs. The user can stop anytime; the rest stay "needs login".
5. **Sockets:** app's own socket directory; optional copyable snippet lets Terminal reuse the app's connections. The app never writes `~/.ssh/config`.
6. **Afterwards:** normal behaviour (§5.3–5.6) with keep-alive (§5.4a); only stale clusters ever need another login.

```
┌ Welcome ───────────────────────────────────────┐
│ Add your clusters                              │
│ (•) Alliance clusters   ( ) Import  ( ) Custom │
│ Alliance username: [ leihan        ]           │
│ [x] nibi [x] fir [x] narval [x] rorqual        │
│ [x] trillium [x] trillium-gpu [x] tamia        │
│ [x] killarney                                  │
│ SSH key: ✓ found ~/.ssh/id_ed25519             │
│                        [ Log in to all ]       │
└────────────────────────────────────────────────┘
```

## 7. Left to the builder
- Exact `squeue`/`sacct` format strings and delimiter; Slurm-version fallbacks.
- Exact keep-alive values and timeouts within the ranges above; refresh intervals.
- Login-sheet prompt detection details (PTY parsing, Duo/YubiKey menu buttons).
- Colours, icons, sort orders, empty/error copy, dark-mode details.
- File layout, module boundaries, tests (parsers, ControlPath resolution, and connection-chain logic unit-tested with fake transports).
- Packaging script details and launch-at-login mechanism.
