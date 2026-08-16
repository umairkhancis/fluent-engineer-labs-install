# fluent-engineer labs — installer

One command puts a [fluent-engineer.io](https://fluent-engineer.io) lab in front
of you on a fresh Linux machine:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/umairkhancis/fluent-engineer-labs-install/main/install.sh) linux-basics
```

Each lab is a sandboxed container with its own terminal. The app opens two
panes: the instructions and a **Check my work** key on the left, your own lab
shell on the right. Do the work, press `c`, and the step's checks decide whether
you move on.

| Lab | |
|---|---|
| `linux-basics` | navigate the filesystem, manage files and processes |
| `git-basics` | init, commit, branch, merge, `.gitignore` |
| `docker-basics` | run and build images inside your own Docker sandbox |

Pass the one you want as the argument; `linux-basics` is the default. Re-running
the command skips everything already installed and just reopens the lab.

## What you need

A Debian or Ubuntu machine on amd64 or arm64, with `sudo`. On macOS or Windows,
run it inside a VM — [multipass](https://multipass.run) is the easy one, and the
defaults are too small, so size it:

```bash
multipass launch 24.04 --name labs --cpus 4 --memory 8G --disk 40G
multipass shell labs
```

## What it installs

Docker (from `get.docker.com`, not snap), `tmux`, `jq`, and `yq` v4 — each
skipped if already present. It then fetches the lab payload and the lab's image
from `ghcr.io/umairkhancis`, and opens the lab.

`docker-basics` runs a Docker daemon of its own, which needs
[Sysbox](https://github.com/nestybox/sysbox) — a runtime that gives the container
its own user namespace, so container-root is unprivileged on the host and no
`--privileged` is involved. That is installed only when you ask for that lab.

Nothing is written outside `~/.fluent-engineer`, `/usr/local/bin/labui` and
`/usr/local/bin/yq`. To remove it all:

```bash
rm -rf ~/.fluent-engineer && sudo rm -f /usr/local/bin/labui
```

## Keys

| Key | |
|---|---|
| `c` | check the current step |
| `h` / `s` | show the hint / the written solution |
| `S` | do the step for me, then confirm with `y` |
| `r` | re-run the step's setup |
| `tab` | jump to the lab shell |
| `q` | remove the container and exit |

---

`install.sh` here is a published copy; it is maintained in the labs repository
alongside the labs themselves.
