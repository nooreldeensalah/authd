# authd Development Environment Guide

A complete guide to setting up and using the LXD-based development environment
for building, testing, and integration-testing authd with cloud identity
providers.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Scripts Reference](#scripts-reference)
- [Development Workflows](#development-workflows)
- [Broker Configuration](#broker-configuration)
- [SSH Login Testing](#ssh-login-testing)
- [Snapshot Strategy](#snapshot-strategy)
- [VS Code Remote SSH](#vs-code-remote-ssh)
- [Troubleshooting](#troubleshooting)
- [Gotchas & Lessons Learned](#gotchas--lessons-learned)

---

## Overview

The dev environment uses an **LXD system container** running Ubuntu noble
(24.04) with full systemd, D-Bus, and SSH support. The host source tree is
bind-mounted into the container, so you edit files on the host and
build/test/run inside the container.

### Why LXD?

| Option | systemd | D-Bus | PAM/NSS | SSH | Verdict |
|--------|---------|-------|---------|-----|---------|
| DevContainers (Docker) | No | No | Limited | No | Not suitable — authd needs systemd socket activation, D-Bus for broker communication, and PAM integration for SSH testing |
| Multipass | Yes | Yes | Yes | Yes | Works but adds unnecessary VM overhead when LXD is available |
| **LXD** | **Yes** | **Yes** | **Yes** | **Yes** | **Best fit** — full systemd, near-native performance, snapshots, shared filesystem |

### What's Included

- **Go 1.25.7** — installed from go.dev (noble ships 1.22, authd requires 1.25+)
- **Rust stable** (latest) — installed via rustup (noble ships 1.75, NSS needs ≥1.82)
- **Protobuf compiler** (protoc) — from apt
- **All build dependencies** — extracted from `debian/control`
- **All test dependencies** — bubblewrap, cracklib, AppArmor profiles, etc.
- **SSH with PAM** — pre-configured for authd's `KbdInteractiveAuthentication`
- **Bind mount** — host source tree at `/workspace/authd` with UID mapping

---

## Architecture

```
┌─────────────────────────── Host (Ubuntu 24.04) ───────────────────────────┐
│                                                                           │
│  ~/Documents/Projects/authd/     ←── your editor (VS Code)               │
│        │                                                                  │
│        │ bind mount (LXD disk device + raw.idmap UID 1000↔1000)          │
│        ▼                                                                  │
│  ┌─────────────────────── LXD Container (authd-dev) ──────────────────┐  │
│  │                                                                     │  │
│  │  /workspace/authd/            ←── same files, writable both ways   │  │
│  │                                                                     │  │
│  │  systemd ─┬─ authd.socket → authd.service (gRPC on /run/authd.sock)│  │
│  │           ├─ authd-google.service (broker daemon, D-Bus)            │  │
│  │           └─ ssh.service (PAM → pam_authd_exec.so → authd)         │  │
│  │                                                                     │  │
│  │  PAM flow: ssh login → pam_authd_exec.so → authd-pam → gRPC       │  │
│  │            → authd → D-Bus → broker → Google/Entra/Keycloak        │  │
│  │                                                                     │  │
│  │  NSS flow: getpwnam() → libnss_authd.so.2 → /run/authd.sock       │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ssh user@gmail.com@10.49.92.24  ←── test PAM login from host            │
└───────────────────────────────────────────────────────────────────────────┘
```

### Component Communication

| From | To | Protocol | Socket/Path |
|------|----|----------|-------------|
| PAM module | authd | gRPC | `/run/authd.sock` (systemd socket activation) |
| NSS module | authd | Custom protocol | `/run/authd.sock` |
| authd | broker | D-Bus (system bus) | `com.ubuntu.authd.{Google,MSEntraID,Oidc}` |
| broker | IdP | HTTPS (OIDC) | Provider-specific URLs |

---

## Prerequisites

On your host machine:

```bash
# 1. Install LXD (if not already present)
sudo snap install lxd
lxd init --auto

# 2. Ensure SSH key exists
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519

# 3. Add your user to the lxd group (logout/login after)
sudo usermod -aG lxd "$USER"
```

---

## Quick Start

```bash
# 1. Create the development environment (~5 min first time)
./dev/dev-env.sh up

# 2. Enter the container
./dev/dev-env.sh shell

# 3. Build & test (inside container)
cd /workspace/authd
go build ./cmd/authd
go test ./internal/brokers/...

# 4. Install authd for integration testing (inside container)
./dev/install-authd.sh

# 5. Configure a broker (from host or inside container)
./dev/dev-env.sh broker google \
    --client-id YOUR_CLIENT_ID \
    --client-secret YOUR_CLIENT_SECRET \
    --ssh-suffixes '@gmail.com'

# 6. Test SSH login (from host)
ssh youremail@gmail.com@$(./dev/dev-env.sh ip)

# 7. Save a snapshot
./dev/dev-env.sh snapshot google-configured
```

---

## Scripts Reference

### `dev/dev-env.sh` — Environment Manager

The main script for managing the LXD container lifecycle. Run from the host.

| Command | Description |
|---------|-------------|
| `up [--release NAME] [--name NAME]` | Create and provision the container |
| `down [--force]` | Stop and delete the container + profile |
| `rebuild` | Destroy and recreate from scratch |
| `shell` | Open a shell via `lxc exec` (no SSH needed) |
| `ssh` | Connect via SSH |
| `status` | Show container status and snapshots |
| `snapshot <name>` | Create a named snapshot |
| `restore <name>` | Restore a named snapshot |
| `broker <variant> [opts]` | Build & install an OIDC broker (delegates to `install-broker.sh`) |
| `ssh-config` | Print SSH config block for VS Code Remote |
| `ip` | Print container IP |
| `help` | Full usage |

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTHD_DEV_NAME` | `authd-dev` | Container name |
| `AUTHD_DEV_RELEASE` | `noble` | Ubuntu release |

**What `up` does:**
1. Creates an LXD profile with disk device (bind mount) and UID mapping
2. Generates cloud-init config (injects your SSH public key)
3. Launches an Ubuntu container with both `default` and custom profiles
4. Waits for cloud-init provisioning (installs Go, Rust, all deps)
5. Verifies toolchain versions
6. Creates a `clean` snapshot
7. Waits for SSH readiness

### `dev/cloud-init.yaml` — Container Provisioning

Cloud-init user-data template used by `dev-env.sh up`. Contains:

- **Packages**: All build and test dependencies from `debian/control` and CI workflows
- **SSH config**: Enables `UsePAM yes` and `KbdInteractiveAuthentication yes` for `*@*` users
- **PATH setup**: Adds `/usr/local/go/bin` and `~/.cargo/bin` to PATH
- **Go installation**: Downloads Go from go.dev (not apt — noble's version is too old)
- **Rust installation**: Via rustup for the `ubuntu` user
- **Protobuf tools**: Installs `protoc-gen-go` and `protoc-gen-go-grpc` from `tools/`
- **AppArmor**: Loads the bubblewrap profile required by tests
- **LOGIN_TIMEOUT**: Increased to 360s for PAM testing comfort

### `dev/install-authd.sh` — Build & Install authd

Run **inside the container**. Builds all components and installs them to system
paths, mirroring what the Debian package does:

| Component | Build Command | Install Path |
|-----------|---------------|--------------|
| authd daemon | `go build ./cmd/authd` | `/usr/libexec/authd` |
| authctl CLI | `go build ./cmd/authctl` | `/usr/bin/authctl` |
| PAM exec module | `go generate ./pam/` + `go build -tags pam_binary_exec ./pam` | `/usr/lib/.../security/pam_authd_exec.so` + `/usr/libexec/authd-pam` |
| PAM GDM module | `go generate ./pam/` | `/usr/lib/.../security/pam_authd.so` |
| NSS module | `cargo build --release -p nss` | `/usr/lib/.../libnss_authd.so.2` |

Also configures:
- `/etc/nsswitch.conf` — adds `authd` to passwd/group/shadow
- PAM — via `pam-auth-update --package`
- systemd — installs `authd.socket` + `authd.service`, enables socket activation

### `dev/install-broker.sh` — Build & Install OIDC Broker

Run **inside the container** (or via `./dev/dev-env.sh broker` from the host).
Builds one of the three broker variants from `authd-oidc-brokers/` and sets up
everything needed for authd to discover and use it.

| Variant | Build Tag | D-Bus Name | Binary |
|---------|-----------|------------|--------|
| `google` | `withgoogle` | `com.ubuntu.authd.Google` | `authd-google` |
| `msentraid` | `withmsentraid` | `com.ubuntu.authd.MSEntraID` | `authd-msentraid` |
| `oidc` | *(none)* | `com.ubuntu.authd.Oidc` | `authd-oidc` |

What it installs:
1. **Broker binary** → `/usr/libexec/authd-{variant}`
2. **D-Bus policy** → `/usr/share/dbus-1/system.d/com.ubuntu.auth.{variant}.conf`
3. **authd discovery config** → `/etc/authd/brokers.d/{variant}.conf`
4. **Broker config** → `/etc/authd-{variant}/broker.conf`
5. **systemd service** → `/etc/systemd/system/authd-{variant}.service`

---

## Development Workflows

### Workflow: "I changed `pam/internal/adapter/nativemodel.go`"

`nativemodel.go` implements the text-based PAM authentication UI (the prompts
you see during SSH login — user selection, broker selection, device auth codes,
password entry, QR codes). Here's the rebuild-and-test cycle:

```bash
# Enter the container
./dev/dev-env.sh shell
cd /workspace/authd

# 1. Run unit tests for the changed package
go test ./pam/internal/adapter/...

# 2. Since nativemodel.go is part of the PAM module, rebuild it:
#    a) Regenerate the C shared libraries
go generate ./pam/
#    b) Rebuild the authd-pam binary
go build -tags pam_binary_exec -o /tmp/authd-pam ./pam

# 3. Install the updated PAM module
sudo install -m 755 /tmp/authd-pam /usr/libexec/authd-pam
sudo install -m 644 pam/go-exec/pam_authd_exec.so /usr/lib/$(gcc -dumpmachine)/security/

# 4. Test via SSH from the host
#    (open another terminal on the host)
ssh youremail@gmail.com@$(./dev/dev-env.sh ip)
```

> **Tip**: You do NOT need to restart authd or the broker — PAM modules are
> loaded fresh on each SSH login attempt.

### Workflow: "I changed `internal/services/pam/pam.go`" (gRPC service)

```bash
cd /workspace/authd

# 1. Unit tests
go test ./internal/services/pam/...

# 2. Rebuild the authd daemon
go build -o /tmp/authd ./cmd/authd

# 3. Install and restart
sudo install -m 755 /tmp/authd /usr/libexec/authd
sudo systemctl restart authd.service

# 4. Test via SSH from host
```

### Workflow: "I changed `internal/proto/authd/authd.proto`" (gRPC definitions)

```bash
cd /workspace/authd

# 1. Regenerate Go code from proto
go generate ./internal/proto/authd/

# 2. Run tests on affected packages
go test ./internal/services/...
go test ./pam/...

# 3. If PAM module is affected, rebuild it too
go generate ./pam/
go build -tags pam_binary_exec -o /tmp/authd-pam ./pam

# 4. Rebuild authd
go build -o /tmp/authd ./cmd/authd

# 5. Install both and restart authd
sudo install -m 755 /tmp/authd /usr/libexec/authd
sudo install -m 755 /tmp/authd-pam /usr/libexec/authd-pam
sudo systemctl restart authd.service
```

### Workflow: "I changed `nss/src/*.rs`" (NSS module)

```bash
cd /workspace/authd

# 1. Build
cargo build --release -p nss

# 2. Install (NSS libraries are loaded dynamically by glibc)
sudo install -m 644 target/release/libnss_authd.so /usr/lib/$(gcc -dumpmachine)/libnss_authd.so.2
sudo ldconfig

# 3. Test NSS resolution
getent passwd youremail@gmail.com
```

### Workflow: "I changed broker code in `authd-oidc-brokers/`"

```bash
cd /workspace/authd/authd-oidc-brokers

# 1. Rebuild with the appropriate build tag
go build -tags=withgoogle -o /tmp/authd-google ./cmd/authd-oidc

# 2. Install and restart the broker
sudo install -m 755 /tmp/authd-google /usr/libexec/authd-google
sudo systemctl restart authd-google.service

# 3. Test via SSH from host
```

### Workflow: "I changed `internal/brokers/` code" (broker manager)

```bash
cd /workspace/authd

# 1. Tests
go test ./internal/brokers/...

# 2. Rebuild authd (the broker manager runs inside authd)
go build -o /tmp/authd ./cmd/authd
sudo install -m 755 /tmp/authd /usr/libexec/authd
sudo systemctl restart authd.service
```

### Workflow: Running Golden File Tests

Many authd tests use golden files for snapshot-based testing:

```bash
# Run tests normally (compares against golden files)
go test ./internal/services/pam/...

# Update golden files after intentional changes
TESTS_UPDATE_GOLDEN=1 go test ./internal/services/pam/...

# Review what changed
git diff testdata/
```

### Workflow: Full Rebuild from Scratch

```bash
# Quick: reinstall everything
./dev/install-authd.sh

# Or: nuclear option — rebuild the entire container
./dev/dev-env.sh rebuild
```

---

## Broker Configuration

### Google IAM

**Prerequisites**: A Google Cloud project with OAuth 2.0 credentials configured
for TV & Limited Input devices.

```bash
# From the host:
./dev/dev-env.sh broker google \
    --client-id 843411749259-xxxxx.apps.googleusercontent.com \
    --client-secret GOCSPX-xxxxx \
    --ssh-suffixes '@gmail.com'

# Or from inside the container:
./dev/install-broker.sh google \
    --client-id 843411749259-xxxxx.apps.googleusercontent.com \
    --client-secret GOCSPX-xxxxx \
    --ssh-suffixes '@gmail.com'
```

**How to get credentials:**
1. Go to [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
2. Create OAuth 2.0 Client ID → Application type: **TVs and Limited Input devices**
3. Note the Client ID and Client Secret

### Microsoft Entra ID

**Prerequisites**: An Azure AD tenant with an app registration.

```bash
./dev/dev-env.sh broker msentraid \
    --issuer https://login.microsoftonline.com/YOUR_TENANT_ID/v2.0 \
    --client-id YOUR_CLIENT_ID \
    --ssh-suffixes '@yourdomain.com'
```

### Generic OIDC (Keycloak, etc.)

```bash
./dev/dev-env.sh broker oidc \
    --issuer https://keycloak.example.com/realms/myrealm \
    --client-id authd-client \
    --client-secret YOUR_SECRET \
    --ssh-suffixes '*'
```

### Manual Broker Configuration

If you need fine-grained control, run the steps manually inside the container:

```bash
# 1. Build the broker
cd /workspace/authd/authd-oidc-brokers
go build -tags=withgoogle -o /tmp/authd-google ./cmd/authd-oidc
sudo install -m 755 /tmp/authd-google /usr/libexec/authd-google

# 2. D-Bus policy
sudo tee /usr/share/dbus-1/system.d/com.ubuntu.auth.google.conf <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE busconfig PUBLIC
 "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="root">
    <allow own="com.ubuntu.authd.Google"/>
  </policy>
  <policy context="default">
    <allow send_destination="com.ubuntu.authd.Google"
           send_interface="com.ubuntu.authd.Broker"/>
    <allow send_destination="com.ubuntu.authd.Google"
           send_interface="org.freedesktop.DBus.Introspectable"/>
  </policy>
</busconfig>
EOF

# 3. authd discovery config (GOTCHA: brand_icon key MUST exist, even empty!)
sudo tee /etc/authd/brokers.d/google.conf <<'EOF'
[authd]
name = Google
brand_icon =
dbus_name = com.ubuntu.authd.Google
dbus_object = /com/ubuntu/authd/Google
EOF

# 4. Broker config with credentials
sudo mkdir -p /etc/authd-google
sudo tee /etc/authd-google/broker.conf <<'EOF'
[oidc]
issuer = https://accounts.google.com
client_id = YOUR_CLIENT_ID
client_secret = YOUR_CLIENT_SECRET

[users]
ssh_allowed_suffixes_first_auth = @gmail.com
allowed_users = ALL
EOF
sudo chmod 600 /etc/authd-google/broker.conf

# 5. systemd service
sudo tee /etc/systemd/system/authd-google.service <<'EOF'
[Unit]
Description=Google Broker for authd
After=network-online.target

[Service]
Type=notify
ExecStart=/usr/libexec/authd-google -config /etc/authd-google/broker.conf -verbosity 2
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now authd-google.service

# 6. Restart authd to discover the broker
sudo systemctl restart authd.service
```

---

## SSH Login Testing

Once authd and a broker are installed, test authentication via SSH from your
host machine:

```bash
# Connect using your identity provider username
ssh youremail@gmail.com@$(./dev/dev-env.sh ip)
```

You should see the authd PAM flow:

```
== Provider selection ==
  1. local
  2. Google
Choose your provider:
> 2
== Device Authentication ==
Access "https://www.google.com/device" and use the provided login code
        ABC-DEF-GHI
Press Enter once you have completed the authentication...
```

### First-Time Login Requirements

For the first SSH login of a new user to work, you MUST configure
`ssh_allowed_suffixes_first_auth` in the broker config. Without it, authd
rejects first-time SSH logins because the user doesn't exist in the system yet.

This is a security feature — set it to specific domain suffixes
(`@gmail.com,@company.com`) or `*` for all users.

### Testing Different Scenarios

```bash
# First login (triggers user creation)
ssh newuser@gmail.com@$(./dev/dev-env.sh ip)

# Subsequent logins (user exists, faster)
ssh existinguser@gmail.com@$(./dev/dev-env.sh ip)

# Test with local broker (no external IdP needed — password: "goodpass")
# Only works if ExampleBroker is configured
ssh user1@$(./dev/dev-env.sh ip)

# Debug authd during login (in another terminal inside the container)
sudo journalctl -u authd -f
sudo journalctl -u authd-google -f
```

---

## Snapshot Strategy

LXD snapshots are instant and free — use them liberally:

```bash
# After basic provisioning (auto-created by 'up')
# already exists as: clean

# After installing authd
./dev/dev-env.sh snapshot authd-installed

# After configuring a broker
./dev/dev-env.sh snapshot google-configured

# Before risky changes
./dev/dev-env.sh snapshot before-experiment

# Restore any snapshot
./dev/dev-env.sh restore clean                   # back to fresh
./dev/dev-env.sh restore google-configured       # back to working broker

# View all snapshots
./dev/dev-env.sh status
```

**Recommended snapshots:**

| Name | When to create | What it contains |
|------|---------------|------------------|
| `clean` | Auto-created by `up` | Cloud-init provisioned, all deps installed, no authd |
| `authd-installed` | After `install-authd.sh` | authd + PAM + NSS installed, no broker |
| `google-configured` | After broker setup | Full working stack with Google broker |

---

## VS Code Remote SSH

Connect VS Code to the container for full IDE support (gopls, rust-analyzer,
debugging):

```bash
# 1. Get the SSH config block
./dev/dev-env.sh ssh-config

# 2. Add it to ~/.ssh/config (or it may already be there)

# 3. In VS Code:
#    Ctrl+Shift+P → "Remote-SSH: Connect to Host" → authd-dev
#    Open folder: /workspace/authd
```

**Recommended remote extensions:**
- `golang.go` — Go + gopls
- `rust-lang.rust-analyzer` — Rust
- `zxh404.vscode-proto3` — Protobuf syntax

> **Note**: If the container IP changes after a restart (DHCP), update the
> `HostName` in `~/.ssh/config` or re-run `./dev/dev-env.sh ssh-config`.

---

## Troubleshooting

### Container won't start

```bash
# Check LXD status
lxc list
lxc info authd-dev

# Check cloud-init logs
lxc exec authd-dev -- cat /var/log/cloud-init-output.log
lxc exec authd-dev -- cloud-init status
```

### Go version is wrong

```bash
# Inside the container
go version
# Should be 1.25.7+ — if not, cloud-init may have failed.
# Check: ls -la /usr/local/go/bin/go
which go  # Should be /usr/local/go/bin/go, NOT /usr/bin/go
```

### authd won't start

```bash
# Check socket and service
sudo systemctl status authd.socket
sudo systemctl status authd.service
sudo journalctl -u authd -e

# Common: authd doesn't start until the socket receives a connection
# This is normal with socket activation
```

### Broker won't start

```bash
# Check the specific broker service
sudo systemctl status authd-google
sudo journalctl -u authd-google -e

# Common issues:
# - Invalid broker.conf (check issuer URL, client_id)
# - D-Bus policy not loaded (sudo systemctl reload dbus)
# - Missing authd discovery config in /etc/authd/brokers.d/
# - Missing submodules (msentraid needs libhimmelblau)
```

### MS Entra ID broker build fails (himmelblau.h not found)

The `msentraid` broker depends on `libhimmelblau` which is a git submodule:

```bash
# Initialize submodules
cd /workspace/authd
git submodule update --init --recursive

# Then rebuild the broker
./dev/install-broker.sh msentraid --client-id X --issuer Y
```

The installation scripts now handle this automatically, but if you cloned the repo
without `--recursive`, you may need to run the submodule command manually.

### SSH login doesn't show broker

```bash
# Verify authd sees the broker
authctl list brokers

# Verify broker is running and on D-Bus
busctl status com.ubuntu.authd.Google

# Restart both
sudo systemctl restart authd-google
sudo systemctl restart authd.service
```

### SSH login shows broker but rejects user

Most likely `ssh_allowed_suffixes_first_auth` is not set:

```bash
# Check broker config
sudo cat /etc/authd-google/broker.conf | grep ssh_allowed

# Fix: add the suffix
sudo sed -i '/\[users\]/a ssh_allowed_suffixes_first_auth = @gmail.com' \
    /etc/authd-google/broker.conf
sudo systemctl restart authd-google
```

### Bind mount permissions

```bash
# Inside the container, files should be owned by ubuntu (UID 1000)
ls -la /workspace/authd/

# If permissions are wrong, check the LXD profile:
lxc profile show authd-dev
# raw.idmap should be: "both <host-uid> 1000"
```

---

## Gotchas & Lessons Learned

1. **`brand_icon` must exist in authd discovery config** — even if empty.
   authd's config parser (`internal/brokers/dbusbroker.go`) requires all four
   keys (`name`, `brand_icon`, `dbus_name`, `dbus_object`) in the `[authd]`
   section. If you omit `brand_icon`, authd silently fails to load the broker.
   Use `brand_icon = ` (empty value).

2. **`ssh_allowed_suffixes_first_auth` is required for first-time SSH login** —
   the broker's `UserPreCheck` returns an empty result without it, and authd
   blocks the login. This is by design (security).

3. **Go version from apt is too old** — noble ships Go 1.22, but authd's
   `go.mod` requires 1.25+. Must install from go.dev.

4. **Rust version from apt is too old** — noble ships Rust 1.75, but the NSS
   crate needs ≥1.82. Must install via rustup.

5. **NSS crate name is `nss`, not `nss_authd`** — the Cargo.toml package name
   is `nss`; the library output is `libnss_authd.so`. So `cargo build -p nss`,
   not `cargo build -p nss_authd`.

6. **PAM modules are loaded per-session** — no need to restart anything after
   rebuilding PAM modules. Each new SSH connection loads them fresh.

7. **authd uses systemd socket activation** — `authd.service` doesn't start
   until something connects to `/run/authd.sock`. Don't be alarmed if
   `authd.service` shows "inactive" — `authd.socket` should be "active".

8. **The broker builds from `authd-oidc-brokers/`** — not from the root Go
   module. The build command is:
   `cd authd-oidc-brokers && go build -tags=withgoogle ./cmd/authd-oidc`

9. **`info()` in shell functions captured by `$(...)` goes to stdout** — when
   using command substitution like `result=$(some_function)`, any `echo`/`info`
   calls inside the function corrupt the captured output. Redirect info
   messages to stderr: `info "message" >&2`.

10. **Container IP may change after restart** — LXD uses DHCP from `lxdbr0`.
    If the IP changes, update `~/.ssh/config` or re-run
    `./dev/dev-env.sh ssh-config`.

11. **MS Entra ID broker requires git submodules** — the `msentraid` broker
    depends on `libhimmelblau` (a C library) which is included as a git
    submodule at `authd-oidc-brokers/third_party/libhimmelblau`. The
    installation scripts automatically run `git submodule update --init`, but
    if you encounter `himmelblau.h: No such file or directory` errors, run
    it manually: `git submodule update --init --recursive`

12. **Broker systemd service uses `-vv` not `--verbosity 2`** — the broker
    binary uses cobra's `CountP` flag for verbosity, which counts the number
    of `-v` flags passed. Use `-vv` for debug logging, not `--verbosity 2`.

---

## File Index

```
dev/
├── cloud-init.yaml      # Cloud-init template — container provisioning
├── dev-env.sh           # Main environment manager (run from host)
├── install-authd.sh     # Build & install authd (run inside container)
├── install-broker.sh    # Build & install OIDC broker (run inside container)
└── DEV-GUIDE.md         # This file
```
