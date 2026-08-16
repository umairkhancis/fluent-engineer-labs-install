#!/usr/bin/env bash
# install.sh — put a fluent-engineer lab in front of someone in one command.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/umairkhancis/fluent-engineer-labs-install/main/install.sh) linux-basics
#
# Everything it installs is skipped when already present, so re-running it is
# just "launch the lab again". It needs no access to the labs repository: the
# lab images and the small payload labui reads (labctl, lab.yaml, catalog.json,
# the labui binary) all come from the public registry.
#
# Use `bash <(curl ...)` rather than `curl ... | bash`: the lab UI is a terminal
# app, and the process-substitution form leaves stdin attached to the terminal
# instead of to the pipe carrying this script. The pipe form is handled too (see
# the launch section) but the form above is the one to document.
set -euo pipefail

SELF_URL=https://raw.githubusercontent.com/umairkhancis/fluent-engineer-labs-install/main/install.sh

REGISTRY="${REGISTRY:-ghcr.io/umairkhancis}"
TAG="${TAG:-latest}"
PREFIX="${PREFIX:-$HOME/.fluent-engineer}"
ROOT="$PREFIX/labs"          # labctl + labs/*/lab.yaml + dist/catalog.json
LIBDIR="$PREFIX/bin"         # the real labui binary
BINDIR=/usr/local/bin        # the `labui` wrapper and yq, both on PATH

DEFAULT_LAB=linux-basics

die()  { echo "install: $*" >&2; exit 1; }
note() { echo "==> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: install.sh [lab-id]

Installs Docker, tmux, yq and jq if missing, fetches the lab payload and the
lab's image from $REGISTRY, and opens the lab. Default lab: $DEFAULT_LAB.

Env: REGISTRY, TAG, PREFIX (default $PREFIX)
EOF
  exit "${1:-0}"
}

case "${1:-}" in -h|--help) usage 0 ;; esac
LAB="${1:-$DEFAULT_LAB}"

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

[ "$(uname -s)" = Linux ] || die "this installs a Linux lab host; run it inside a VM (e.g. multipass) on macOS"

# The Docker convenience script, the yq release assets and the Sysbox .deb are
# all named by Docker's architecture words, not uname's.
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture $(uname -m) — labs are published for amd64 and arm64" ;;
esac

. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
case "${ID:-}${ID_LIKE:-}" in
  *debian*|*ubuntu*) ;;
  *) die "this installer is apt-based; ${PRETTY_NAME:-this distro} is not supported" ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif have sudo; then
  SUDO=sudo
else
  die "sudo is required (or run as root)"
fi

# multipass defaults to 1 CPU / 1 GB / 5 GB, which cannot run a lab that hosts
# its own Docker daemon. Warn rather than refuse: the plain labs are far lighter.
mem_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
disk_gb=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')
[ "$mem_mb" -ge 2000 ]        || note "WARNING: only ${mem_mb}MB RAM — 2GB+ recommended"
[ "${disk_gb:-99}" -ge 10 ]   || note "WARNING: only ${disk_gb}GB free — 10GB+ recommended"

# ---------------------------------------------------------------------------
# prerequisites
# ---------------------------------------------------------------------------

apt_get() { $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

apt_updated=false
apt_install() { # <pkg>...
  $apt_updated || { apt_get update -qq; apt_updated=true; }
  apt_get install -y -qq "$@"
}

have curl || apt_install curl ca-certificates

if have docker; then
  note "docker already installed"
else
  # Docker MUST come from apt, not snap: Sysbox does not support snap Docker,
  # and one of the labs needs Sysbox.
  note "installing docker"
  curl -fsSL https://get.docker.com | $SUDO sh >/dev/null
fi

for pkg in tmux jq; do
  have "$pkg" || { note "installing $pkg"; apt_install "$pkg"; }
done

# yq MUST be mikefarah v4. Ubuntu's `yq` package is an unrelated python wrapper
# around jq, and every yamlq call in labctl misbehaves under it — so check the
# flavour, not just the presence.
if have yq && yq --version 2>/dev/null | grep -q mikefarah; then
  note "yq (mikefarah) already installed"
else
  note "installing yq v4"
  $SUDO curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" -o "$BINDIR/yq"
  $SUDO chmod +x "$BINDIR/yq"
  hash -r   # a wrong yq earlier in this shell's command hash would win otherwise
  yq --version | grep -q mikefarah || die "installed yq is not mikefarah's — check PATH for another yq"
fi

# Group membership does not apply to a session that already exists, so the
# installer keeps using sudo and only the final launch drops into the new group.
if ! id -nG | tr ' ' '\n' | grep -qx docker; then
  note "adding $USER to the docker group"
  $SUDO usermod -aG docker "$USER"
fi

# docker, however this session is allowed to reach it.
dk() { if [ -w /var/run/docker.sock ]; then docker "$@"; else $SUDO docker "$@"; fi; }

dk info >/dev/null 2>&1 || die "docker is installed but not responding (try: $SUDO systemctl start docker)"

# ---------------------------------------------------------------------------
# payload — labctl, every lab.yaml, the catalog, and the labui binary
# ---------------------------------------------------------------------------

note "fetching the lab payload"
mkdir -p "$ROOT" "$LIBDIR"
dk pull -q "$REGISTRY/labkit:$TAG" >/dev/null
dk run --rm "$REGISTRY/labkit:$TAG" tar -c -C /opt/labkit . | tar -x -C "$ROOT"

[ -f "$ROOT/labctl" ] && [ -f "$ROOT/dist/catalog.json" ] || die "payload is missing labctl or the catalog"
chmod +x "$ROOT/labctl"

[ -f "$ROOT/bin/labui-linux-$ARCH" ] || die "the labkit has no labui for linux/$ARCH"
install -m 0755 "$ROOT/bin/labui-linux-$ARCH" "$LIBDIR/labui"
rm -rf "$ROOT/bin"   # the other architecture's copy is 14MB of dead weight

# labui finds its root by walking up from $PWD for a file named labctl, and the
# payload is not on that path from a student's home directory. The wrapper
# supplies --root, unless the caller already passed one.
$SUDO tee "$BINDIR/labui" >/dev/null <<EOF
#!/bin/sh
# Installed by fluent-engineer-labs install.sh.
case " \$* " in
  *" --root "*|*" -root "*) exec "$LIBDIR/labui" "\$@" ;;
esac
exec "$LIBDIR/labui" "\$@" --root "$ROOT"
EOF
$SUDO chmod +x "$BINDIR/labui"

# ---------------------------------------------------------------------------
# the lab itself
# ---------------------------------------------------------------------------

catalog="$ROOT/dist/catalog.json"
lab_json=$(jq -c --arg id "$LAB" '.labs[] | select(.id == $id)' "$catalog")
if [ -z "$lab_json" ]; then
  echo "install: no lab '$LAB'. Available:" >&2
  jq -r '.labs[] | "  \(.id)  — \(.title)"' "$catalog" >&2
  exit 1
fi

image=$(jq -r '.image' <<<"$lab_json")
runtime=$(jq -r '.run.runtime // ""' <<<"$lab_json")

# Only some labs are VM-like. Sysbox is a kernel-level install, so it goes in
# when the chosen lab actually asks for it rather than on every machine.
if [ "$runtime" = sysbox-runc ]; then
  if dk info --format '{{range $k,$v := .Runtimes}}{{$k}}{{"\n"}}{{end}}' | grep -qx sysbox-runc; then
    note "sysbox already registered"
  else
    note "'$LAB' runs its own Docker daemon and needs Sysbox — installing"
    deb_url=$(curl -fsSL https://api.github.com/repos/nestybox/sysbox/releases/latest \
      | jq -r --arg a "$ARCH" '.assets[].browser_download_url | select(endswith("linux_" + $a + ".deb"))' \
      | head -1)
    [ -n "$deb_url" ] || die "no sysbox .deb published for $ARCH"
    deb="$(mktemp -d)/$(basename "$deb_url")"
    curl -fsSL "$deb_url" -o "$deb"
    # Sysbox's postinst stops running containers to reconfigure the daemon.
    apt_get install -y "$deb"
    dk info --format '{{range $k,$v := .Runtimes}}{{$k}}{{"\n"}}{{end}}' | grep -qx sysbox-runc \
      || die "sysbox installed but docker does not list sysbox-runc — check: systemctl status sysbox"
  fi
fi

note "pulling $image"
dk pull -q "$image" >/dev/null

# ---------------------------------------------------------------------------
# launch
# ---------------------------------------------------------------------------

note "starting $LAB — press q to quit, and re-run this command any time"

# --prebuilt tells labui there is no source tree here: do not try to build the
# image or rebuild the catalog. LABCTL_PULL makes labctl run the published image
# rather than the local :dev tag `labctl build` would have produced.
launch="LABCTL_PULL=1 REGISTRY=$(printf %q "$REGISTRY") TAG=$(printf %q "$TAG") $BINDIR/labui $(printf %q "$LAB") --prebuilt"

# Do NOT redirect from /dev/tty here. tmux calls ttyname() on its stdin and
# refuses outright when the answer is the literal string "/dev/tty" rather than
# the real /dev/pts/N behind it — "open terminal failed: can't use /dev/tty".
#
# With the documented `bash <(curl ...)` form stdin is already that pts, so
# there is nothing to fix. Under `curl | bash` stdin is the pipe feeding this
# script; borrow stdout's terminal instead, which does name a real pts.
if [ ! -t 0 ]; then
  if [ -t 1 ]; then
    exec 0<&1
  else
    die "no terminal to draw the lab on — run: bash <(curl -fsSL $SELF_URL) $LAB"
  fi
fi

if id -nG | tr ' ' '\n' | grep -qx docker; then
  exec /bin/sh -c "$launch"
else
  # First run: the docker group exists but this session predates it. sg starts a
  # shell that has it, so the student does not have to log out and back in.
  exec sg docker -c "$launch"
fi
