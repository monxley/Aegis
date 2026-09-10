# Running an Aegis node

An Aegis **node** is a blind mailbox *and* a Sphinx mix + directory server, in one
process (`aegis-relay-server --mix`). Clients auto-discover the network from any
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
curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/install.sh \
  | sudo PUBLIC_HOST=your.host bash

# Any other node joins an existing one:
curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/install.sh \
  | sudo PUBLIC_HOST=node2.host BOOTSTRAP=seed.host:5078 bash
```

It installs Rust if needed, builds `aegis-relay-server`, creates a service user,
and installs + starts the systemd unit. Open ports 5077 and 5078, then
`journalctl -u aegis-node -f`.

## Updating a node

The same script. It is written to be re-run: it clones the repo **fresh** every
time (never a stale checkout lying around on the box), rebuilds the binary,
overwrites `/usr/local/bin/aegis-relay-server`, and `systemctl restart`s the
unit — a restart rather than `enable --now`, so a re-run actually picks up the
new binary instead of silently keeping the running one.

```sh
# Update a node in place. Pass the same PUBLIC_HOST/BOOTSTRAP you installed with;
# the unit file is rewritten from them, so anything you omit reverts to default.
curl -fsSL https://raw.githubusercontent.com/monxley/Aegis/main/deploy/install.sh \
  | sudo PUBLIC_HOST=your.host BOOTSTRAP=seed.host:5078 bash
```

Then confirm it came back on the new code:

```sh
systemctl status aegis-node --no-pager
journalctl -u aegis-node -n 50 --no-pager
```

Two things worth knowing:

- The script builds whatever is on **`main`**. A change that is still on a
  branch or in an open pull request will not be deployed until it is merged.
- Data in `/var/lib/aegis` is left alone, so the node keeps its identity and
  its queued envelopes across an update.

There is nothing to coordinate across nodes: they gossip the directory, so
updating them one at a time is fine and the network stays up throughout.

To update a **Docker** node instead:

```sh
git -C /path/to/Aegis pull
PUBLIC_HOST=your.host BOOTSTRAP=seed.host:5078 \
  docker compose -f deploy/docker-compose.yml up -d --build
```

## Quick start (Docker)

```sh
# The first seed node of a new network (no bootstrap yet):
PUBLIC_HOST=seed.example docker compose -f deploy/docker-compose.yml up -d

# Every other node points --bootstrap at an existing node's mix port:
PUBLIC_HOST=node2.example BOOTSTRAP=seed.example:5078 \
  docker compose -f deploy/docker-compose.yml up -d
```

## Quick start (systemd)

```sh
cargo build --release -p aegis-relay-server
sudo cp target/release/aegis-relay-server /usr/local/bin/
sudo useradd -r -s /usr/sbin/nologin aegis
sudo mkdir -p /var/lib/aegis && sudo chown aegis /var/lib/aegis
sudo cp deploy/aegis-node.service /etc/systemd/system/
sudoedit /etc/systemd/system/aegis-node.service   # set your host + bootstrap
sudo systemctl enable --now aegis-node
```

## Pointing the app at your network

Clients discover the network from any node's **mix** port. Put one or more of
your nodes' mix addresses in the app's bootstrap list (`app/lib/config.dart`,
`kBootstrapNodes`) and rebuild, or run against a private set. Only one bootstrap
entry needs to be reachable; the rest of the directory is learned by gossip.

State (`relay_key`, `mix_key`, and the sealed mailbox) persists under the data
dir, so a restart keeps the node's identity and stored mail.
