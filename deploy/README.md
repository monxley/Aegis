# Running an Shoal node

An Shoal **node** is a blind mailbox *and* a Sphinx mix + directory server, in one
process (`shoal-relay-server --mix`). Clients auto-discover the network from any
node's mix port, so end users run nothing — the network is powered by whoever
runs nodes (the project + volunteers), on always-on, reachable hosts.

A node **cannot read messages or tell who they are between**: it stores sealed
envelopes it has no keys for, and forwards onion packets that reveal only the
previous and next hop.

## Ports

| Port | Role |
|------|------|
| 5077 | blind **mailbox** — clients poll it for their mail |
| 5078 | **mix** — onion traffic + the gossiped node directory (clients bootstrap here) |

Expose both on a public IP / forwarded port. `--advertise-mix` and
`--advertise-provider` are the **public** `host:port` other nodes and clients use
(not `0.0.0.0`).

## One-command install (plain VPS, console only)

No GUI, no Docker — just SSH into the box and run:

```sh
# First seed node of a new network:
curl -fsSL https://raw.githubusercontent.com/monxley/shoal/main/deploy/install.sh \
  | sudo PUBLIC_HOST=YOUR_HOST bash

# Any other node joins an existing one:
curl -fsSL https://raw.githubusercontent.com/monxley/shoal/main/deploy/install.sh \
  | sudo PUBLIC_HOST=YOUR_HOST BOOTSTRAP=SEED_HOST:5078 bash
```

It installs Rust if needed, builds `shoal-relay-server`, creates a service user,
and installs + starts the systemd unit. Open ports 5077 and 5078, then
`journalctl -u shoal-node -f`.

## Updating a node

The same script. It is written to be re-run: it clones the repo **fresh** every
time (never a stale checkout lying around on the box), rebuilds the binary,
overwrites `/usr/local/bin/shoal-relay-server`, and `systemctl restart`s the
unit — a restart rather than `enable --now`, so a re-run actually picks up the
new binary instead of silently keeping the running one.

```sh
# Update a node in place. Safe to paste as-is: with neither variable set the
# script detects the public address itself. Set them only to CHANGE them -- the
# unit file is rewritten from them, so anything you pass replaces what is there.
curl -fsSL https://raw.githubusercontent.com/monxley/shoal/main/deploy/install.sh | sudo bash
```

Then confirm it came back on the new code:

```sh
systemctl status shoal-node --no-pager
journalctl -u shoal-node -n 50 --no-pager
```

Two things worth knowing:

- The script builds whatever is on **`main`**. A change that is still on a
  branch or in an open pull request will not be deployed until it is merged.
- Data in `/var/lib/shoal` is left alone, so the node keeps its identity and
  its queued envelopes across an update.

There is nothing to coordinate across nodes: they gossip the directory, so
updating them one at a time is fine and the network stays up throughout.

To update a **Docker** node instead:

```sh
git -C /path/to/Shoal pull
PUBLIC_HOST=YOUR_HOST BOOTSTRAP=SEED_HOST:5078 \
  docker compose -f deploy/docker-compose.yml up -d --build
```

## Reclaiming the disk after an APK build on the same box

`build-apk.sh` leaves roughly **10 GB** of Android toolchain under `$HOME` — the
NDK (~2.6 GB), the Flutter SDK and its engine artifacts (~2.8 GB), Gradle
(~1.5 GB), the Rust Android targets (~0.6 GB), the Android SDK, the pub cache.
It keeps all of it so a second build is fast, which is the wrong trade on a VPS
whose job is running a node. Once the APK is copied off:

```sh
curl -fsSL https://raw.githubusercontent.com/monxley/shoal/main/deploy/clean-build-toolchain.sh | bash

# See what it would remove first, without removing anything:
curl -fsSL https://raw.githubusercontent.com/monxley/shoal/main/deploy/clean-build-toolchain.sh | DRY_RUN=1 bash
```

It removes only build toolchain. Before each delete it checks the path against
the node's binary, its unit file and its **data dir** — read from the installed
unit, so a node installed with a custom `DATA_DIR` is protected at the path it
actually uses — and skips anything that holds or is part of the node. The node
keeps its identity and its queued envelopes and does not restart.

The base Rust toolchain is kept by default, because `install.sh` needs `cargo`
to update the node; only the Android targets and the APK-only cargo tools go.
Pass `PURGE_RUST=1` to remove `~/.cargo` and `~/.rustup` too (`install.sh`
reinstalls rustup, ~400 MB, on the next update).

The better arrangement is not to build the APK on the node's VPS at all: CI
builds one on every push, and a tagged release publishes a signed APK.

## Building the APK on a phone (Termux) — don't

There is no command for this, and the reason is not effort or packaging. Three
separate parts of the Android toolchain are published for **x86-64 hosts only**,
so an arm64 phone has nothing to run:

1. **Flutter's Android AOT compiler.** `flutter build apk --release` runs
   `gen_snapshot` on the *host* to compile Dart ahead of time. Flutter publishes
   it per host architecture, and the list has no arm64 Linux entry —
   `packages/flutter_tools/lib/src/flutter_cache.dart`, `_linuxBinaryDirs`, is
   six lines and every one of them is `linux-x64`. `artifacts.dart` resolves the
   binary under `<engine>/<host>/gen_snapshot` and special-cases only Apple
   Silicon (down to `darwin-x64`), so an arm64 Linux host asks for
   `android-arm64-release/linux-arm64.zip`, which does not exist. **A release
   APK cannot be built on any arm64 host**, Termux, proot or Raspberry Pi alike.
2. **Google's build-tools.** `aapt2`, `zipalign` and `aidl` ship as x86-64 ELF
   binaries, including the `aapt2` that AGP pulls from Maven. They do not run on
   aarch64 at all. Rebuilt aarch64 versions exist outside Google (AndroidIDE
   ships some); nothing in this repo uses or vouches for them.
3. **The NDK**, which cross-compiles the Rust engine, is released for x86-64
   Linux, macOS and Windows. There is no arm64 Linux NDK, so `cargo ndk` has
   nothing to call. (Termux's own clang *is* an `aarch64-linux-android`
   toolchain, so the Rust half alone could be built there — arm64 only.)

Even ignoring all three, the build wants ~10 GB of free space and more RAM than
a phone will give Gradle, R8 and the Dart compiler at once.

**What to do from a phone instead** — drive CI from Termux and install what it
produces. This gives a properly signed release APK, which an on-device build
could never do anyway:

```sh
pkg install gh
gh auth login
gh workflow run release.yml -R monxley/shoal -f tag=v0.1.0   # or push a v* tag
gh run watch  -R monxley/shoal
gh release download v0.1.0 -R monxley/shoal -p '*.apk'
termux-open app-release.apk
```

Check what you are installing first — the release publishes a SHA-256 next to
the APK:

```sh
gh release download v0.1.0 -R monxley/shoal -p '*.sha256'
sha256sum -c app-release.apk.sha256
```

## Quick start (Docker)

```sh
# The first seed node of a new network (no bootstrap yet):
PUBLIC_HOST=YOUR_HOST docker compose -f deploy/docker-compose.yml up -d

# Every other node points --bootstrap at an existing node's mix port:
PUBLIC_HOST=YOUR_HOST BOOTSTRAP=SEED_HOST:5078 \
  docker compose -f deploy/docker-compose.yml up -d
```

## Quick start (systemd)

```sh
cargo build --release -p shoal-relay-server
sudo cp target/release/shoal-relay-server /usr/local/bin/
sudo useradd -r -s /usr/sbin/nologin shoal
sudo mkdir -p /var/lib/shoal && sudo chown shoal /var/lib/shoal
sudo cp deploy/shoal-node.service /etc/systemd/system/
sudoedit /etc/systemd/system/shoal-node.service   # set your host + bootstrap
sudo systemctl enable --now shoal-node
```

## Pointing the app at your network

Clients discover the network from any node's **mix** port. Put one or more of
your nodes' mix addresses in the app's bootstrap list (`app/lib/config.dart`,
`kBootstrapNodes`) and rebuild, or run against a private set. Only one bootstrap
entry needs to be reachable; the rest of the directory is learned by gossip.

State (`relay_key`, `mix_key`, and the sealed mailbox) persists under the data
dir, so a restart keeps the node's identity and stored mail.
