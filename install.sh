#!/usr/bin/env bash
# install.sh — put a fluent-engineer lab in front of someone in one command.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/umairkhancis/fluent-engineer-labs-install/main/install.sh) linux-basics
#
# The same command on Ubuntu/Debian and on macOS. Everything it installs is
# skipped when already present, so re-running it is just "launch the lab again".
# It needs no access to the labs repository: the lab images and the small payload
# labui reads (labctl, lab.yaml, catalog.json, the labui binary) all come from
# the public registry.
#
# The two hosts differ in exactly two ways, both forced on us:
#
#   * Docker. On Linux it is installed for you; on macOS it is a prerequisite.
#     Docker Desktop is a signed .dmg with a GUI first run and a licence to
#     accept — not something a shell script should install behind someone's back.
#   * Sysbox is a Linux kernel-level runtime with no equivalent inside Docker
#     Desktop's VM, so labs declaring `runtime: sysbox` are refused on macOS with
#     a pointer to running them in a Linux VM. Every other lab runs natively.
#
# macOS also gets no sudo: a Mac is usually someone's actual machine rather than
# a throwaway VM, so everything lands under $PREFIX, owned by the user.
#
# Use `bash <(curl ...)` rather than `curl ... | bash`: the lab UI is a terminal
# app, and the process-substitution form leaves stdin attached to the terminal
# instead of to the pipe carrying this script. The pipe form is handled too (see
# the launch section) but the form above is the one to document.
set -euo pipefail

SELF_URL=https://raw.githubusercontent.com/umairkhancis/fluent-engineer-labs-install/main/install.sh

# Telemetry. Empty key = off, which is the default in a checkout; the published
# copy carries the project key. PostHog project keys are write-only and meant to
# ship in client code, so this is not a secret.
#
# What it is for: knowing which stage of this script people fall out of. An
# install_started with no launched is a broken install, and the last event says
# where. Set NO_TELEMETRY=1 or DO_NOT_TRACK=1 to send nothing.
POSTHOG_KEY="${LAB_TELEMETRY_KEY:-phc_kY5GZSrMWWbB8rtLLKkyFcXyfYSCkakfXueWx7vi576p}"
POSTHOG_HOST="${LAB_TELEMETRY_HOST:-https://us.i.posthog.com}"

# One id for the whole journey. Exported, so labui reports the lab funnel under
# the same id and the two join into one funnel from curl to finished lab.
# /proc is Linux-only and uuidgen is what macOS has; the timestamp is the floor.
LAB_SESSION="${LAB_SESSION:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || date +%s-$$)}"
export LAB_SESSION

REGISTRY="${REGISTRY:-ghcr.io/umairkhancis}"
TAG="${TAG:-latest}"
PREFIX="${PREFIX:-$HOME/.fluent-engineer}"
ROOT="$PREFIX/labs"          # labctl + labs/*/lab.yaml + dist/catalog.json
LIBDIR="$PREFIX/bin"         # the real labui binary
BINDIR=                      # the `labui` wrapper, yq and jq; set per-OS below

DEFAULT_LAB=linux-basics

die()  { echo "install: $*" >&2; ping install_failed "$*"; exit 1; }
note() { echo "==> $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ping <event> [detail] — fire and forget. Every failure mode is swallowed and
# the timeout is short: telemetry must never stall or break someone's install,
# so a blocked network or a typo'd host costs at most two seconds.
ping() {
  [ -n "$POSTHOG_KEY" ] || return 0
  [ -z "${NO_TELEMETRY:-}" ] && [ -z "${DO_NOT_TRACK:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  # Stamped here, not at receipt: these run in the background and land out of
  # order, which would scramble a funnel ordered by arrival. Milliseconds
  # because consecutive stages routinely fall in the same second.
  # %3N is GNU-only and BSD date passes it through literally while still exiting
  # 0, so the output has to be inspected rather than the exit code trusted.
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || true)
  case "$ts" in ''|*N*) ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ;; esac
  ( curl -fsS -m 2 -o /dev/null -X POST "$POSTHOG_HOST/capture/" \
      -H 'content-type: application/json' \
      -d "{\"api_key\":\"$POSTHOG_KEY\",\"event\":\"$1\",\"distinct_id\":\"$LAB_SESSION\",\
\"timestamp\":\"$ts\",\
\"properties\":{\"lab\":\"${LAB:-}\",\"arch\":\"${ARCH:-}\",\"distro\":\"${ID:-}${VERSION_ID:+ $VERSION_ID}\",\
\"detail\":\"${2:-}\",\"\$lib\":\"labs-installer\"}}" >/dev/null 2>&1 || true ) &
}

usage() {
  cat <<EOF
Usage: install.sh [lab-id]

Fetches the lab payload and the lab's image from $REGISTRY, and opens the lab.
On Linux it also installs Docker, tmux, yq and jq if missing; on macOS Docker
must already be running and the rest installs without sudo.
Default lab: $DEFAULT_LAB.

Env: REGISTRY, TAG, PREFIX (default $PREFIX)
EOF
  exit "${1:-0}"
}

case "${1:-}" in -h|--help) usage 0 ;; esac
LAB="${1:-$DEFAULT_LAB}"

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *) die "unsupported OS $(uname -s) — labs run on Linux and macOS" ;;
esac

# The Docker convenience script, the yq/jq release assets and the Sysbox .deb are
# all named by Docker's architecture words, not uname's.
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported architecture $(uname -m) — labs are published for amd64 and arm64" ;;
esac

preflight_linux() {
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

  BINDIR=/usr/local/bin

  # multipass defaults to 1 CPU / 1 GB / 5 GB, which cannot run a lab that hosts
  # its own Docker daemon. Warn rather than refuse: the plain labs are far lighter.
  local mem_mb disk_gb
  mem_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
  disk_gb=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')
  [ "$mem_mb" -ge 2000 ]        || note "WARNING: only ${mem_mb}MB RAM — 2GB+ recommended"
  [ "${disk_gb:-99}" -ge 10 ]   || note "WARNING: only ${disk_gb}GB free — 10GB+ recommended"
}

preflight_darwin() {
  # Nothing here needs root, so nothing is written outside $PREFIX and $BINDIR is
  # inside it. That leaves the wrapper off PATH; the launch section says so.
  SUDO=""
  BINDIR="$LIBDIR"
  mkdir -p "$BINDIR"

  # /etc/os-release has no macOS counterpart, and `ping` reports these two as the
  # `distro` property.
  ID=macos
  VERSION_ID=$(sw_vers -productVersion 2>/dev/null || echo unknown)

  # The lab does not run on this Mac's RAM but in Docker's VM, so the number that
  # matters comes from `docker info` — checked once docker is known to respond.
  :
}

"preflight_$OS"

# Funnel stage 1. Emitted after the preflight so that arch and distro are known
# and every later event can be grouped by them.
ping install_started

# ---------------------------------------------------------------------------
# prerequisites
# ---------------------------------------------------------------------------

apt_get() { $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

apt_updated=false
apt_install() { # <pkg>...
  $apt_updated || { apt_get update -qq; apt_updated=true; }
  apt_get install -y -qq "$@"
}

# yq MUST be mikefarah v4. Ubuntu's `yq` package is an unrelated python wrapper
# around jq, and every yamlq call in labctl misbehaves under it — so check the
# flavour, not just the presence. Release assets are named yq_<os>_<arch>.
install_yq() {
  if have yq && yq --version 2>/dev/null | grep -q mikefarah; then
    note "yq (mikefarah) already installed"
    return
  fi
  note "installing yq v4"
  $SUDO curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_${OS}_${ARCH}" -o "$BINDIR/yq"
  $SUDO chmod +x "$BINDIR/yq"
  PATH="$BINDIR:$PATH"
  hash -r   # a wrong yq earlier in this shell's command hash would win otherwise
  yq --version | grep -q mikefarah || die "installed yq is not mikefarah's — check PATH for another yq"
}

prereqs_linux() {
  have curl || apt_install curl ca-certificates

  if have docker; then
    note "docker already installed"
  else
    # Docker MUST come from apt, not snap: Sysbox does not support snap Docker,
    # and one of the labs needs Sysbox.
    note "installing docker"
    curl -fsSL https://get.docker.com | $SUDO sh >/dev/null
  fi

  local pkg
  for pkg in tmux jq; do
    have "$pkg" || { note "installing $pkg"; apt_install "$pkg"; }
  done

  install_yq

  # Group membership does not apply to a session that already exists, so the
  # installer keeps using sudo and only the final launch drops into the new group.
  if ! id -nG | tr ' ' '\n' | grep -qx docker; then
    note "adding $USER to the docker group"
    $SUDO usermod -aG docker "$USER"
  fi
}

prereqs_darwin() {
  have curl || die "curl is required"

  have docker || die "docker is required, and installing it is a GUI step. Either:
  Docker Desktop  https://docs.docker.com/desktop/install/mac-install/
  colima          brew install colima docker && colima start
  OrbStack        brew install --cask orbstack
Then re-run this command."

  # tmux is the one prerequisite with no vendor-published macOS binary, so it is
  # the one that needs a package manager.
  if have tmux; then
    note "tmux already installed"
  else
    have brew || die "tmux is required and has no standalone macOS build — install
  Homebrew (https://brew.sh) and re-run, or install tmux some other way"
    note "installing tmux"
    brew install tmux
  fi

  # jq and yq both publish darwin binaries, so they go straight into $BINDIR: no
  # brew, no sudo, nothing outside $PREFIX.
  if have jq; then
    note "jq already installed"
  else
    note "installing jq"
    curl -fsSL "https://github.com/jqlang/jq/releases/latest/download/jq-macos-${ARCH}" -o "$BINDIR/jq"
    chmod +x "$BINDIR/jq"
    PATH="$BINDIR:$PATH"
    hash -r
  fi

  install_yq
}

"prereqs_$OS"

# docker, however this session is allowed to reach it. Docker Desktop's socket is
# not /var/run/docker.sock and never wants sudo, so macOS just calls it.
if [ "$OS" = darwin ]; then
  dk() { docker "$@"; }
else
  dk() { if [ -w /var/run/docker.sock ]; then docker "$@"; else $SUDO docker "$@"; fi; }
fi

if ! dk info >/dev/null 2>&1; then
  if [ "$OS" = darwin ]; then
    die "docker is installed but not responding — start Docker Desktop (or: colima start)"
  fi
  die "docker is installed but not responding (try: $SUDO systemctl start docker)"
fi

# The Linux preflight read /proc/meminfo; on macOS the containers run inside
# Docker's VM, so its allocation is the number that matters, not the Mac's.
if [ "$OS" = darwin ]; then
  vm_mb=$(( $(dk info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1048576 ))
  [ "$vm_mb" -ge 2000 ] || note "WARNING: Docker has only ${vm_mb}MB RAM — raise it under Settings > Resources"
fi

ping deps_ready

# ---------------------------------------------------------------------------
# payload — labctl, every lab.yaml, the catalog, and the labui binary
# ---------------------------------------------------------------------------

note "fetching the lab payload"
mkdir -p "$ROOT" "$LIBDIR"
dk pull -q "$REGISTRY/labkit:$TAG" >/dev/null
dk run --rm "$REGISTRY/labkit:$TAG" tar -c -C /opt/labkit . | tar -x -C "$ROOT"

[ -f "$ROOT/labctl" ] && [ -f "$ROOT/dist/catalog.json" ] || die "payload is missing labctl or the catalog"
chmod +x "$ROOT/labctl"

[ -f "$ROOT/bin/labui-$OS-$ARCH" ] || die "the labkit has no labui for $OS/$ARCH"
# labui-bin, not labui: on macOS $BINDIR is $LIBDIR and the wrapper below owns
# that name. Older Linux installs put the real binary at $LIBDIR/labui.
install -m 0755 "$ROOT/bin/labui-$OS-$ARCH" "$LIBDIR/labui-bin"
[ "$BINDIR" = "$LIBDIR" ] || rm -f "$LIBDIR/labui"
rm -rf "$ROOT/bin"   # the other platforms' copies are ~14MB each of dead weight

# labui finds its root by walking up from $PWD for a file named labctl, and the
# payload is not on that path from a student's home directory. The wrapper
# supplies --root, unless the caller already passed one. It also puts $BINDIR on
# PATH, since that is where yq lives (and, on macOS, jq) and labctl needs both.
$SUDO tee "$BINDIR/labui" >/dev/null <<EOF
#!/bin/sh
# Installed by fluent-engineer-labs install.sh.
PATH="$BINDIR:\$PATH"; export PATH
case " \$* " in
  *" --root "*|*" -root "*) exec "$LIBDIR/labui-bin" "\$@" ;;
esac
exec "$LIBDIR/labui-bin" "\$@" --root "$ROOT"
EOF
$SUDO chmod +x "$BINDIR/labui"

ping payload_ready

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
# when the chosen lab actually asks for it rather than on every machine — and it
# is Linux-only, with nothing equivalent inside Docker Desktop's VM.
if [ "$runtime" = sysbox-runc ]; then
  if [ "$OS" != linux ]; then
    others=$(jq -r --arg id "$LAB" \
      '[.labs[] | select(.id != $id and (.run.runtime // "") != "sysbox-runc") | .id] | join(", ")' \
      "$catalog")
    die "'$LAB' runs its own Docker daemon, which needs Sysbox — a Linux
kernel-level runtime with no macOS equivalent. Take that one in a Linux VM
(multipass, UTM, or any Ubuntu box) and run this same command inside it.

Every other lab runs natively on this Mac${others:+: $others}"
  fi

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
  ping sysbox_ready
fi

note "pulling $image"
dk pull -q "$image" >/dev/null
ping image_ready

# ---------------------------------------------------------------------------
# launch
# ---------------------------------------------------------------------------

note "starting $LAB — press q to quit, and re-run this command any time"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) note "(add $BINDIR to PATH to reopen it later with: labui $LAB)" ;;
esac

# --prebuilt tells labui there is no source tree here: do not try to build the
# image or rebuild the catalog. LABCTL_PULL makes labctl run the published image
# rather than the local :dev tag `labctl build` would have produced.
ping launched

# LAB_SESSION is already exported; passing the key and host through means labui
# reports the lab funnel to the same project under the same session id.
launch="LABCTL_PULL=1 REGISTRY=$(printf %q "$REGISTRY") TAG=$(printf %q "$TAG")"
launch="$launch LAB_SESSION=$(printf %q "$LAB_SESSION")"
if [ -n "$POSTHOG_KEY" ] && [ -z "${NO_TELEMETRY:-}" ] && [ -z "${DO_NOT_TRACK:-}" ]; then
  launch="$launch LAB_TELEMETRY_KEY=$(printf %q "$POSTHOG_KEY")"
  launch="$launch LAB_TELEMETRY_HOST=$(printf %q "$POSTHOG_HOST")"
fi
launch="$launch $BINDIR/labui $(printf %q "$LAB") --prebuilt"

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

# The docker group is a Linux concept; on macOS the daemon is reached over a
# socket the user already owns.
if [ "$OS" = darwin ] || id -nG | tr ' ' '\n' | grep -qx docker; then
  exec /bin/sh -c "$launch"
else
  # First run: the docker group exists but this session predates it. sg starts a
  # shell that has it, so the student does not have to log out and back in.
  exec sg docker -c "$launch"
fi
