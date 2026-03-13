#!/usr/bin/env bash
# Install authd inside the dev container for integration testing.
#
# This builds authd, PAM modules, and the NSS module, then installs them
# to system paths and configures PAM, NSS, and systemd — mirroring what
# the Debian package does (see debian/install, debian/postinst).
#
# Run from inside the container:
#   cd /workspace/authd && ./dev/install-authd.sh
#
# After installation, test SSH login from your host:
#   ssh user@example.com@authd-dev

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace/authd}"
cd "$WORKSPACE"

# Ensure Go and cargo paths are available
export PATH="/usr/local/go/bin:${HOME}/.cargo/bin:${PATH}"

# --- Output helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# --- Paths (matching debian/install) ---
MULTIARCH=$(gcc -dumpmachine)
PAM_MODULE_DIR="/usr/lib/${MULTIARCH}/security"
NSS_LIB_DIR="/usr/lib/${MULTIARCH}"
DAEMONS_PATH="/usr/libexec"
BUILD_DIR="/tmp/authd-build"

mkdir -p "$BUILD_DIR"

echo -e "\n${BOLD}Installing authd for integration testing${NC}"
echo "  Source:      ${WORKSPACE}"
echo "  Daemons:     ${DAEMONS_PATH}"
echo "  PAM modules: ${PAM_MODULE_DIR}"
echo "  NSS library: ${NSS_LIB_DIR}"
echo ""

# ============================================================
# Step 0: Initialize git submodules
# ============================================================

# Initialize git submodules (required for building oidc brokers later)
info "Ensuring git submodules are initialized..."
if [[ -f "${WORKSPACE}/.gitmodules" ]]; then
    # Configure git to trust the workspace (needed for bind mounts with UID mapping)
    git config --global --add safe.directory "${WORKSPACE}" 2>/dev/null || true
    (cd "${WORKSPACE}" && git submodule update --init --recursive) || \
        warn "Failed to update submodules (may not be a git repo or already initialized)"
fi

# ============================================================
# Step 1: Build all components
# ============================================================

# --- authd daemon ---
info "Building authd daemon..."
go build -o "${BUILD_DIR}/authd" ./cmd/authd
ok "authd daemon built"

# --- authctl CLI ---
info "Building authctl..."
go build -o "${BUILD_DIR}/authctl" ./cmd/authctl
ok "authctl built"

# --- PAM modules ---
# go generate builds both pam_authd.so (GDM) and pam_authd_exec.so (generic).
# The exec .so is a C library built by pam/generate.sh.
info "Generating PAM modules (go generate ./pam/)..."
go generate ./pam/
ok "PAM module generation complete"

# Build the authd-pam Go binary (companion to pam_authd_exec.so)
info "Building authd-pam exec binary..."
go build -tags pam_binary_exec -o "${BUILD_DIR}/authd-pam" ./pam
ok "authd-pam built"

# Verify the C shared libraries were generated
if [[ ! -f pam/go-exec/pam_authd_exec.so ]]; then
    die "pam_authd_exec.so not found after go generate. Check build output."
fi
ok "pam_authd_exec.so generated"

if [[ -f pam/pam_authd.so ]]; then
    ok "pam_authd.so generated (GDM module)"
else
    warn "pam_authd.so not generated — GDM module unavailable (fine for SSH testing)"
fi

# --- NSS module (Rust) ---
info "Building NSS module..."
cargo build --release -p nss
ok "NSS module built"

# ============================================================
# Step 2: Install to system paths
# ============================================================

info "Installing binaries..."
sudo install -m 755 "${BUILD_DIR}/authd" "${DAEMONS_PATH}/authd"
sudo install -m 755 "${BUILD_DIR}/authctl" /usr/bin/authctl
sudo install -m 755 "${BUILD_DIR}/authd-pam" "${DAEMONS_PATH}/authd-pam"
ok "Binaries installed to ${DAEMONS_PATH}"

info "Installing PAM modules..."
sudo mkdir -p "$PAM_MODULE_DIR"
sudo install -m 644 pam/go-exec/pam_authd_exec.so "${PAM_MODULE_DIR}/"
if [[ -f pam/pam_authd.so ]]; then
    sudo install -m 644 pam/pam_authd.so "${PAM_MODULE_DIR}/"
fi
ok "PAM modules installed to ${PAM_MODULE_DIR}"

info "Installing NSS module..."
sudo install -m 644 target/release/libnss_authd.so "${NSS_LIB_DIR}/libnss_authd.so.2"
sudo ldconfig
ok "NSS module installed to ${NSS_LIB_DIR}"

# ============================================================
# Step 3: Configure the system
# ============================================================

# --- authd directories ---
info "Creating authd state/config directories..."
sudo mkdir -p /etc/authd/brokers.d
sudo chmod 700 /etc/authd
sudo mkdir -p /var/lib/authd
sudo chmod 700 /var/lib/authd

# --- Default config ---
if [[ ! -f /etc/authd/authd.yaml ]]; then
    sudo install -m 600 debian/authd-config/authd.yaml /etc/authd/authd.yaml
    ok "Default authd.yaml installed to /etc/authd/"
else
    info "/etc/authd/authd.yaml already exists, not overwriting"
fi

# --- NSSwitch (mirrors debian/postinst) ---
info "Configuring nsswitch.conf..."
for db in passwd group shadow; do
    if ! grep "^${db}:" /etc/nsswitch.conf | grep -q "authd" 2>/dev/null; then
        sudo sed -i "s/^\(${db}:.*\)/\1 authd/" /etc/nsswitch.conf
        ok "  Added 'authd' to ${db} in nsswitch.conf"
    else
        info "  ${db} already has 'authd' in nsswitch.conf"
    fi
done

# --- PAM (mirrors debian/postinst) ---
info "Configuring PAM..."
sudo mkdir -p /usr/share/pam-configs
sed "s|@AUTHD_DAEMONS_PATH@|${DAEMONS_PATH}|g" debian/pam-configs/authd.in | \
    sudo tee /usr/share/pam-configs/authd > /dev/null
sudo pam-auth-update --package
ok "PAM configured via pam-auth-update"

# --- Systemd units ---
info "Installing systemd units..."
sed "s|@AUTHD_DAEMONS_PATH@|${DAEMONS_PATH}|g" debian/authd.service.in | \
    sudo tee /etc/systemd/system/authd.service > /dev/null
sudo cp debian/authd.socket /etc/systemd/system/authd.socket
sudo systemctl daemon-reload
sudo systemctl enable authd.socket
sudo systemctl restart authd.socket
ok "authd.socket enabled and started"

# ============================================================
# Step 4: Verify
# ============================================================

echo ""
info "Verification:"

if sudo systemctl is-active --quiet authd.socket; then
    ok "authd.socket is active"
else
    warn "authd.socket is NOT active"
fi

if [[ -S /run/authd.sock ]]; then
    ok "Socket /run/authd.sock exists"
else
    info "Socket /run/authd.sock not yet created (created on first connection)"
fi

echo ""
echo -e "${GREEN}${BOLD}authd installed successfully!${NC}"
echo ""
echo -e "${BOLD}Next steps — configure a broker:${NC}"
echo ""
echo "  Option A: ExampleBroker (local testing, no external IdP needed):"
echo "    go build -o /tmp/ExampleBroker ./examplebroker/"
echo "    sudo cp examplebroker/com.ubuntu.auth.ExampleBroker.conf /etc/dbus-1/system.d/"
echo "    sudo /tmp/ExampleBroker &"
echo "    # Create /usr/share/authd/brokers/ExampleBroker.conf pointing to D-Bus name"
echo ""
echo "  Option B: MS Entra ID (snap-based):"
echo "    sudo snap install authd-msentraid"
echo "    # Configure issuer/client_id in /var/snap/authd-msentraid/current/broker.conf"
echo "    sudo systemctl restart authd"
echo ""
echo "  Then from your host, test SSH login:"
echo "    ssh user@domain.com@\$(./dev/dev-env.sh ip)"
echo ""

# Cleanup
rm -rf "$BUILD_DIR"
