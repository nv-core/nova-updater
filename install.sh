#!/usr/bin/env bash
# installer for nova-updater itself — follows its own convention:
#   ./install.sh install|update|uninstall [--purge] [--with-system]
#
# Default install is 100% user-level (~/.local) — NO root needed:
#   nova + nova-gui   -> ~/.local/bin
#   desktop entry     -> ~/.local/share/applications
#   user timer        -> ~/.config/systemd/user   (auto-updates user apps + nova)
#
# --with-system additionally sets up the OPTIONAL system scope (root once):
#   root-owned nova   -> /usr/local/bin/nova   (used by the root timer only —
#                        the root service never executes user-writable files)
#   system timer      -> /etc/systemd/system   (auto-updates system apps + itself)
#   config / repos    -> /etc/nova-updater, /var/lib/nova-updater
#
# When executed as root (e.g. by nova's system update service) only the
# system-level parts are (re)installed.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SRC/install.sh"

ACTION="${1:-install}"
PURGE=0
WITH_SYSTEM=0
CLI_ONLY=0
for arg in "${@:2}"; do
    case "$arg" in
        --purge)       PURGE=1 ;;
        --with-system) WITH_SYSTEM=1 ;;
        --cli-only)    CLI_ONLY=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

# the official catalog, preregistered on every install
DEFAULT_CATALOG="https://github.com/nv-core/nova-catalog.git"

# GUI parts are skipped on headless machines (no GTK4 stack), with
# --cli-only / NOVA_GUI=0 as explicit overrides. Not based on $DISPLAY —
# ssh sessions to desktop machines have none.
want_gui() {
    (( CLI_ONLY )) && return 1
    [[ ${NOVA_GUI:-} == 0 ]] && return 1
    [[ -n ${NOVA_GUI:-} ]] && return 0
    [[ -e /usr/lib64/girepository-1.0/Gtk-4.0.typelib ||
       -e /usr/lib/girepository-1.0/Gtk-4.0.typelib ]]
}

USER_BIN="$HOME/.local/bin"
USER_APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
USER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/nova-updater"
USER_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/nova-updater"

SYS_BIN="/usr/local/bin"
SYS_UNIT_DIR="/etc/systemd/system"
SYS_CONF="/etc/nova-updater"
SYS_DATA="/var/lib/nova-updater"

say() { printf ':: %s\n' "$*"; }

as_root() {
    if [[ $EUID -eq 0 ]]; then "$@"
    elif [[ -t 0 ]] && command -v sudo >/dev/null 2>&1; then sudo "$@"
    elif command -v pkexec >/dev/null 2>&1; then pkexec "$@"
    else echo "error: need sudo or pkexec" >&2; exit 1
    fi
}

origin_url() { git -C "$SRC" remote get-url origin 2>/dev/null || true; }

seed_list() { # file header-comment
    [[ -f $1 ]] || printf '# %s\n' "$2" > "$1"
}

register_self() { # list-file repos-dir
    local url; url="$(origin_url)"
    if [[ -z $url ]]; then
        say "note: no git origin found — self-update not registered"
        return 0
    fi
    grep -qF "$url" "$1" || echo "$url" >> "$1"
    local d="$2/nova-updater"
    if [[ "$(realpath "$SRC")" != "$(realpath -m "$d")" && ! -d "$d/.git" ]]; then
        git clone --quiet "$url" "$d"
    fi
    [[ -d "$d/.git" ]] && git -C "$d" rev-parse HEAD > "$d/.nova-installed"
    say "self-update registered ($url)"
}

system_present() {
    [[ -x "$SYS_BIN/nova" || -f "$SYS_UNIT_DIR/nova-updater-system.timer" ]]
}

# ---------------- user phase (default, no root) -------------------------------
user_install() {
    say "installing nova to $USER_BIN"
    install -Dm755 "$SRC/bin/nova" "$USER_BIN/nova"

    if want_gui; then
        say "installing nova-gui + desktop entry"
        install -Dm755 "$SRC/gui/nova-gui" "$USER_BIN/nova-gui"
        mkdir -p "$USER_APPS"
        # file name must match the GTK application id for GNOME Shell association
        sed "s|^Exec=.*|Exec=$USER_BIN/nova-gui|" "$SRC/data/nova-gui.desktop" \
            > "$USER_APPS/org.novanetwork.NovaUpdater.desktop"
        rm -f "$USER_APPS/nova-gui.desktop"   # pre-0.2 name
    else
        say "no GTK4 stack (or --cli-only) — skipping GUI"
    fi

    say "installing user update service"
    install -Dm644 "$SRC/data/systemd/nova-updater.service" "$USER_UNIT_DIR/nova-updater.service"
    install -Dm644 "$SRC/data/systemd/nova-updater.timer"   "$USER_UNIT_DIR/nova-updater.timer"
    systemctl --user daemon-reload
    systemctl --user enable --now nova-updater.timer

    mkdir -p "$USER_CONF" "$USER_DATA/repos"
    seed_list "$USER_CONF/apps.list"     "nova user apps — one git URL per line; options: branch=<b> ref=<tag>"
    seed_list "$USER_CONF/catalogs.list" "nova catalogs — git URLs of catalog repos (shared app lists)"
    grep -qF "$DEFAULT_CATALOG" "$USER_CONF/catalogs.list" || {
        echo "$DEFAULT_CATALOG" >> "$USER_CONF/catalogs.list"
        say "registered default catalog ($DEFAULT_CATALOG)"
    }
    register_self "$USER_CONF/apps.list" "$USER_DATA/repos"

    say "done — try: nova list  |  nova add <git-url>  |  nova-gui"
    (( WITH_SYSTEM )) || say "system scope (root apps) not set up — rerun with --with-system if needed"
}

user_update() { user_install; }

user_uninstall() {
    say "removing user service, binaries, desktop entry"
    systemctl --user disable --now nova-updater.timer 2>/dev/null || true
    rm -f "$USER_UNIT_DIR/nova-updater.service" "$USER_UNIT_DIR/nova-updater.timer"
    systemctl --user daemon-reload
    rm -f "$USER_BIN/nova" "$USER_BIN/nova-gui" \
          "$USER_APPS/org.novanetwork.NovaUpdater.desktop" "$USER_APPS/nova-gui.desktop"
    if (( PURGE )); then
        say "purging $USER_CONF and $USER_DATA"
        rm -rf "$USER_CONF" "$USER_DATA"
    else
        say "kept: $USER_CONF and $USER_DATA — use 'install.sh uninstall --purge' to remove"
    fi
}

# ---------------- system phase (opt-in, runs as root) --------------------------
root_install() {
    say "installing root-owned nova to $SYS_BIN (used by the system timer)"
    install -Dm755 "$SRC/bin/nova" "$SYS_BIN/nova"

    say "installing system update service"
    install -Dm644 "$SRC/data/systemd/nova-updater-system.service" "$SYS_UNIT_DIR/nova-updater-system.service"
    install -Dm644 "$SRC/data/systemd/nova-updater-system.timer"   "$SYS_UNIT_DIR/nova-updater-system.timer"
    systemctl daemon-reload
    systemctl enable --now nova-updater-system.timer

    # wheel users may *start* the update service without a password
    # (/etc/polkit-1/rules.d is writable on ostree systems)
    install -Dm644 "$SRC/data/polkit/50-nova-updater.rules" \
        /etc/polkit-1/rules.d/50-nova-updater.rules

    mkdir -p "$SYS_CONF" "$SYS_DATA/repos"
    chmod 755 "$SYS_DATA" "$SYS_DATA/repos"
    seed_list "$SYS_CONF/apps.list"     "nova system apps — installed as root; options: branch=<b> ref=<tag>"
    seed_list "$SYS_CONF/catalogs.list" "nova system catalogs — git URLs of catalog repos"
    grep -qF "$DEFAULT_CATALOG" "$SYS_CONF/catalogs.list" || echo "$DEFAULT_CATALOG" >> "$SYS_CONF/catalogs.list"
    register_self "$SYS_CONF/apps.list" "$SYS_DATA/repos"
}

root_update() { root_install; }

root_uninstall() {
    say "removing system service and root-owned nova"
    systemctl disable --now nova-updater-system.timer 2>/dev/null || true
    rm -f "$SYS_UNIT_DIR/nova-updater-system.service" "$SYS_UNIT_DIR/nova-updater-system.timer" \
          /etc/polkit-1/rules.d/50-nova-updater.rules
    systemctl daemon-reload
    rm -f "$SYS_BIN/nova"

    if (( PURGE )); then
        local other=() d
        for d in "$SYS_DATA"/repos/*/; do
            [[ -f "$d/.nova-installed" && "$(basename "$d")" != "nova-updater" ]] && other+=("$(basename "$d")")
        done
        if [[ ${#other[@]} -gt 0 ]]; then
            say "WARNING: these system apps stay installed but lose their updater: ${other[*]}"
            say "         (uninstall them first with 'nova uninstall <name>' if you want them gone)"
        fi
        say "purging $SYS_CONF and $SYS_DATA"
        rm -rf "$SYS_CONF" "$SYS_DATA"
    else
        say "kept: $SYS_CONF and $SYS_DATA — use 'install.sh uninstall --purge' to remove"
    fi
}

# ---------------- dispatch ------------------------------------------------------
case "$ACTION" in install|update|uninstall) ;; *)
    echo "usage: $0 install|update|uninstall [--purge] [--with-system] [--cli-only]" >&2; exit 1 ;;
esac

if [[ $EUID -eq 0 ]]; then
    # invoked as root (system service self-update, or escalated below)
    "root_$ACTION"
else
    "user_$ACTION"
    # touch the system scope only when explicitly asked, or interactively when
    # it exists (a background self-update must never block on a password prompt;
    # the root copy updates itself via its own timer anyway)
    if (( WITH_SYSTEM )) || { [[ $ACTION != install && -t 0 ]] && system_present; }; then
        say "handling system scope (root)"
        as_root bash "$SELF" "$ACTION" ${PURGE:+--purge}
    fi
fi
