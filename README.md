# Docker on an External Drive

**One folder. One script. No WSL2. No Docker data on C:.**

`Install-DockerExternal.ps1` turns `F:\backup\windowsapps\installed\docker-engine`
(or the same folder on any other drive) into a complete, portable Docker engine.
It builds the Hyper-V VM, internal network, NAT, host forwarding, SMB share,
local guest account, global PATH entries and the `pristine` checkpoint used by
`dkill`. Every executable, image layer, VM disk and credential already lives in
the folder — the script only wires the machine to it.

---

## Highlights

| Feature | Result |
|---|---|
| Engine | Docker Engine 29.x inside Hyper-V VM `dockerce-hv` |
| Storage | Everything under the external `docker-engine` folder |
| WSL2 | Not used for Docker at all |
| C: drive | No Docker data, no Docker env vars, no profile hooks, no Prefetch leftovers |
| `dkill` | Restores the `pristine` checkpoint, frees all Docker data, reports GB freed and readiness in about 5–7 seconds |
| Portability | Root is derived from the script's own location; any drive letter works |
| Restore functions | `g<App>` pull payloads from Docker Hub, not from local manifests |
| Idempotent | Safe to run repeatedly; existing VM, switch, NAT and share are reused |

---

## Layout

```
docker-engine/
├─ installer/
│  ├─ Install-DockerExternal.ps1   ← this setup script (Windows PowerShell 5.1)
│  └─ README.md                    ← this document
├─ bin/                             ← dk.exe + aliases, docker.exe launcher, compose, buildx
├─ cli/                             ← Docker CLI plugins and config/context cand1
├─ hv/
│  ├─ backend.json                 ← VM / switch / snapshot / guest IP settings
│  ├─ disks/
│  │  ├─ dockerce-hv.vhdx          ← Linux VM with dockerd (3.4 GB)
│  │  └─ dockerce-hv-seed.vhdx     ← cloud-init seed for /f guest mount
│  ├─ seedfiles/                   ← user-data / meta-data / network-config templates
│  └─ vm/                           ← VM config and snapshot state
├─ shim/                            ← optional PowerShell helpers (not required for PATH use)
└─ bench/                           ← guard-docker.ps1 and c-write-audit.ps1
```

---

## Quick start

1. Copy the whole `docker-engine` folder to the external drive.
2. Open **Windows PowerShell 5.1** as Administrator.
3. Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Install-DockerExternal.ps1
```

The script self-elevates if it was not started elevated. A reboot is only needed
when Hyper-V features had to be enabled; run it once more after the reboot.

### Other modes

```powershell
# Read-only preview: print what would change, touch nothing
.\installer\Install-DockerExternal.ps1 -DryRun

# Verify an existing installation, change nothing
.\installer\Install-DockerExternal.ps1 -Check

# Explicit root (useful when launching from elsewhere)
.\installer\Install-DockerExternal.ps1 -Root 'E:\portable\docker-engine'
```

---

## What the script does

1. Validates that every required file exists inside the script's own folder tree.
2. Enables `Microsoft-Hyper-V-All`, `Microsoft-Hyper-V-Hypervisor` and the
   management tools; sets `vmms` to Automatic and starts it.
3. Points Hyper-V VM and disk storage at `<root>\hv\vm` and `<root>\hv\disks`.
4. Creates the internal switch `dockerce-hv-nat`, host IP `10.99.0.1/24`,
   NAT `10.99.0.0/24`, and `portproxy 127.0.0.1:2375 → 10.99.0.2:2375`.
5. Reads the guest share account and password from `hv\seedfiles\user-data`,
   creates the local account and SMB share, and grants it NTFS access to the
   external folder. The secret never leaves the external drive.
6. Creates the Gen2 VM from the external VHDX files, disables Secure Boot,
   attaches the seed disk, sets 2 CPUs / 2 GB RAM and enables VM auto-start.
7. Puts `<root>\bin` first in both User and Machine PATH, and removes legacy
   `DOCKER_CONFIG` / `DOCKER_HOST` user variables.
8. Starts the VM and waits for `docker version` to answer.
9. Creates the `pristine` checkpoint after pruning Docker data.
10. Verifies with `dk setup --check` and prints `Docker ready: YES (<version>)`.

---

## Daily use

```powershell
docker version            # launcher in bin/ sets DOCKER_CONFIG and context cand1
dkill                     # free all Docker data, engine ready again in <10 s
dk setup --check          # full read-only health check
menu -Path <folder>       # push a folder to Docker Hub
g<App> -NoLaunch          # restore that folder from Docker Hub only
```

Example `dkill` output:

```
[dkill] freed 13.34 GB of Docker data (13.34 GB before -> 0.00 GB after)
[dkill] Docker ready: YES (server 29.10.0)
[dkill] pristine snapshot restored; engine ready in 6.5s (restore 2.0s)
```

---

## Requirements

- Windows 10/11 Pro, Enterprise or Education (Hyper-V capable).
- Administrator rights (the script self-elevates).
- The complete `docker-engine` folder on an external NTFS drive.
- At least 8 GB free on that drive for the VM disk and saved state.

---

## Design notes

- **No WSL2.** The daemon runs in a real Hyper-V VM; the old WSL2 distro was
  removed. Only an unrelated Ubuntu WSL distro may remain.
- **No C: payload.** Registry PATH entries and Hyper-V service configuration are
  pointers only; Docker binaries, config, images, volumes, VM disks and
  credentials stay on the external drive.
- **Registry-only restore.** Generated `g<App>` functions query Docker Hub for
  tags, layers and labels. No local manifest, cache or previous backup is read.
- **Portable root.** Every path is derived from the script location, so the same
  folder works as `E:\docker-engine` or `F:\backup\windowsapps\installed\docker-engine`.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Hyper-V changes need a reboot` | Reboot, then run the script again. |
| `Docker did not answer within 240 seconds` | Check VM state with `Get-VM dockerce-hv`; inspect `hv\disks` and the NAT/portproxy rules. |
| `missing required file` | Re-copy the complete `docker-engine` folder; do not split it. |
| `dkill` reports `Docker ready: NO` | Run `.\installer\Install-DockerExternal.ps1 -Check`, then the full installer once. |
| Guest `/f` mount missing | Confirm the `hvdocker` account, SMB share `docker-engine-hv` and seedfiles still exist in the external folder. |

---

## Verification

```powershell
.\installer\Install-DockerExternal.ps1 -Check
F:\backup\windowsapps\installed\docker-engine\bench\guard-docker.ps1
```

`guard-docker.ps1` asserts that no Docker Desktop paths, user Docker env vars,
profile hooks, tasks, AppData folders or Prefetch traces exist on C:, and exits
with `GUARD failures=0`.

---

*Built for a single external folder. Nothing hidden, nothing on C:, nothing in WSL2.*
