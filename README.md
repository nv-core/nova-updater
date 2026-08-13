# nova-updater

Git-based installer/updater for **Nova Network** tools on **Fedora
Silverblue / Bluefin(-dx)** and other ostree-based systems, maintained by the
Nova Core Team. Apps are plain GitHub repos that follow a tiny convention
(`nova.manifest` + `install.sh`); nova clones them, runs their installer, and
keeps them updated in the background — including itself.

- **`nova`** — lightweight bash CLI (needs only `git` + coreutils)
- **`nova-gui`** — GTK4/libadwaita GUI (Python, GNOME 40+), multi-select install/update/uninstall
- **releases follow git tags** — apps update to the latest version tag;
  untagged pushes don't trigger updates (repos without tags follow HEAD)
- **catalogs** — a shared git repo can provide the app list (+ version pins),
  managed through your normal git workflow (PRs, commits, rollbacks)
- **systemd timers** — background auto-updates for user apps and (optionally)
  system apps including nova itself

## Install / Uninstall

The default install is **100 % user-level (`~/.local`) — no root, no
password**. One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/nv-core/nova-updater/main/get-nova.sh | bash
```

…or with the optional system scope (root prompt via pkexec):

```bash
curl -fsSL https://raw.githubusercontent.com/nv-core/nova-updater/main/get-nova.sh | bash -s -- --with-system
```

Manually:

```bash
git clone https://github.com/nv-core/nova-updater.git
cd nova-updater
./install.sh                       # user-level: CLI, GUI, desktop entry, user timer
./install.sh install --with-system # + opt-in system scope (asks for root once)
# later:
./install.sh uninstall             # removes programs/services, keeps app lists + repos
./install.sh uninstall --purge     # removes everything
```

The desktop entry lands in `~/.local/share/applications`, so **Nova Updater**
shows up in the GNOME app grid. Requires `git` on the host (in the base image
on Silverblue/Bluefin).

**Headless machines**: GUI parts (nova-gui, desktop entries) are skipped
automatically when no GTK4 stack is present; force with `--cli-only` or
`NOVA_GUI=0`. nova exports `NOVA_GUI` to every app installer, so all Nova
Network tools make the same cli/gui decision with one installer.

### Why the split layout? (Silverblue-safe *and* secure)

| piece | location | why |
|---|---|---|
| nova, nova-gui, user apps | `~/.local` | no root needed, survives rebases, brew-style |
| root-owned nova copy (opt-in) | `/usr/local/bin` (= writable `/var/usrlocal`) | the **root** update timer must never execute a *user-writable* file — otherwise any process running as your user could edit it and become root on the next timer tick |
| system app repos / config | `/var/lib`, `/etc` | writable on ostree systems, root-owned |

The immutable `/usr` is never touched. If you never need system apps, nothing
outside your home is ever written.

## Usage

```bash
nova add https://github.com/nv-core/my-tool.git              # user app
nova add https://github.com/nv-core/my-sys-tool.git --system # system app (root)
nova catalog add https://github.com/nv-core/nova-catalog.git # shared app list
nova list --check         # list all apps + check remotes for new versions
nova install my-tool      # or: nova install --all
nova update               # update everything that has a new tag
nova uninstall my-tool [--purge]
nova self-update
nova-gui                  # the GTK frontend
```

App lists (one git URL per line, options after the URL):

| scope  | list                                | repos cached in                     | installed as |
|--------|-------------------------------------|-------------------------------------|--------------|
| user   | `~/.config/nova-updater/apps.list`  | `~/.local/share/nova-updater/repos` | your user    |
| system | `/etc/nova-updater/apps.list`       | `/var/lib/nova-updater/repos`       | root         |

Entry options: `branch=<name>` (track a branch), `ref=<tag>` (pin a version),
`scope=system` (catalog entries only — local lists get their scope from which
file they're in).

## Catalogs — the git-workflowed master list

A catalog is a plain git repo containing an `apps.list`. The **official
[nv-core/nova-catalog](https://github.com/nv-core/nova-catalog) is registered
automatically at install** — community or personal catalogs can be added with
`nova catalog add <url>` (and dropped with `catalog remove`). nova syncs all
of them before every check/update. Local `apps.list` entries always win over
catalog entries.

```
# nova-catalog/apps.list
https://github.com/nv-core/my-cli-tool.git
https://github.com/nv-core/my-gtk-app.git
https://github.com/nv-core/my-extension.git
https://github.com/nv-core/wg-config.git   scope=system
https://github.com/nv-core/risky-tool.git  ref=v1.2.0
```

Adding a tool, pinning a version, or rolling back is just a commit/PR to the
catalog repo — every machine picks it up on its next timer tick.

## Versioning

`nova` targets the **latest version-sorted git tag** of each repo
(`v1.2.10 > v1.2.9`). Your release flow per tool: commit freely, then
`git tag v1.3.0 && git push --tags` to release. Repos without any tags follow
HEAD (push = release). `ref=`/`branch=` entry options override per app.

## Background updates

| unit | scope | what it does |
|------|-------|--------------|
| `nova-updater.timer` (user) | user | `nova update --all --user` every 6 h + desktop notification |
| `nova-updater-system.timer` (opt-in) | root | `nova update --all --system` every 6 h — also self-updates the root copy |

```bash
systemctl --user list-timers nova-updater.timer
journalctl --user -u nova-updater.service
# with --with-system:
systemctl list-timers nova-updater-system.timer
journalctl -u nova-updater-system.service
```

## The app convention

Every tool repo contains a `nova.manifest` at its root
(see [templates/nova.manifest](templates/nova.manifest)):

```ini
NAME=my-tool
DESCRIPTION=Short description
VERSION=0.1.0
TYPE=cli            # cli | gui | gnome-extension | system  (informational)
SCOPE=user          # user | system (system = installed as root)
INSTALLER=install.sh
```

…and an installer script supporting `install`, `update`, `uninstall`
(see [templates/install.sh](templates/install.sh)). nova calls it from the
repo root with:

| env var | value |
|---------|-------|
| `NOVA_SCOPE`  | `user` or `system` |
| `NOVA_PREFIX` | `~/.local` (user) or `/usr/local` (system) |
| `NOVA_APP_DIR`| absolute path of the clone |
| `NOVA_ACTION` | the action being run |

Start a new tool by copying both templates into the new repo — that's all
nova needs.

## Notes

- `nova check` exits with code `10` when updates are available (script-friendly).
- Root escalation for system apps: `sudo` in a terminal, `pkexec` from the GUI —
  automatic, and it always executes the root-owned nova copy, never a file in
  your home.
- Concurrent runs are prevented with per-scope lock files.
- The GUI is a thin layer over `nova list --porcelain` — the CLI is the single
  source of truth.
