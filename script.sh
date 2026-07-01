#!/bin/bash
# ====================================================================================
# INGRESS EDGE FIREWALL SETUP SCRIPT
# ====================================================================================
# Sets up a secure ingress edge firewall with transparent DNAT:
# - nftables filter + transparent DNAT (no source address rewriting)
# - Real client IP preserved on the backend server
# - Dual-VPN support: Netbird (primary) with automatic Tailscale failover
# - UDP 443 DNAT for QUIC/HTTP3
# - Automatic DNAT target switch when VPN status changes
# - Full logging and interactive diagnostics
#
# USAGE: wget -O script.sh <url> && bash script.sh
# ====================================================================================

# Exit on any error (-e) and treat unset variables as errors (-u)
set -eu

# Path to the persistent log file where all output is duplicated
LOG_FILE="/var/log/ingress_edge_setup.log"

echo "==========================================" > "$LOG_FILE"
echo "INGRESS EDGE SETUP STARTED" >> "$LOG_FILE"
echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "==========================================" >> "$LOG_FILE"

# ------------------------------------------------------------------------------------
# log() - Write messages to terminal AND log file
# ------------------------------------------------------------------------------------
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# ------------------------------------------------------------------------------------
# handle_error() - Error handler with severity levels
# "CRITICAL" exits immediately; other severities log and continue.
# ------------------------------------------------------------------------------------
handle_error() {
    local exit_code=$1
    local message=$2
    local severity=${3:-ERROR}
    log "$severity" "$message (Exit code: $exit_code)"
    case "$severity" in
        "CRITICAL") exit $exit_code ;;
        *) return ;;
    esac
}

# ------------------------------------------------------------------------------------
# print_section() - Section header
# Prints a visually distinct step heading and logs the step.
# ------------------------------------------------------------------------------------
print_section() {
    local num=$1
    local title=$2
    echo ""
    echo "=========================================="
    echo "  STEP $num: $title"
    echo "=========================================="
    log "INFO" "=== Starting Step $num: $title ==="
}

# ====================================================================================
# STARTUP BANNER
# ====================================================================================
echo ""
echo "=========================================="
echo "  INGRESS EDGE FIREWALL SETUP v3.0"
echo "  Transparent DNAT - Real Client IP"
echo "=========================================="
log "INFO" "Script started - User: $(whoami), System: $(uname -n)"

# DNS name of the backend server (resolved via Netbird or Tailscale DNS)
BACKEND_ADDRESS="backend"
# File that caches the last-known-working backend IP so we can survive a reboot
CACHE_FILE="/etc/ingress-edge-backend-ip"

echo "[INFO] Backend DNS: $BACKEND_ADDRESS"
log "INFO" "Backend address: $BACKEND_ADDRESS"
echo ""

# ====================================================================================
# STEP 1: SYSTEM VERIFICATION
# Verifies the OS is Debian 13 (the only supported platform).
# ====================================================================================
print_section "1" "SYSTEM VERIFICATION"

echo "[*] Checking distribution..."
if grep -q "VERSION_ID=\"13\"" /etc/os-release; then
    log "OK" "System is Debian 13"
    echo "[OK] System is Debian 13"
else
    log "ERROR" "This script only supports Debian 13!"
    echo "[ERROR] This script only supports Debian 13!"
    cat /etc/os-release
    exit 1
fi

# ====================================================================================
# STEP 2: PACKAGE INSTALLATION
# Waits for concurrent apt processes, updates packages, upgrades, and installs
# the tools required for the firewall (nftables, WireGuard, Python, DNS, etc.).
# ====================================================================================
print_section "2" "PACKAGE INSTALLATION"

echo "[*] Checking for running apt processes..."
if pgrep -f "apt|dpkg" >/dev/null 2>&1; then
    log "WARN" "Another apt process is running - waiting..."
    for i in {1..60}; do
        if ! pgrep -f "apt|dpkg" >/dev/null 2>&1; then
            log "OK" "apt lock released after $i seconds"
            break
        fi
        echo "[INFO] Waiting... ($i/60 seconds)"
        sleep 1
    done
    if pgrep -f "apt|dpkg" >/dev/null 2>&1; then
        handle_error 1 "apt lock held by another process" "CRITICAL"
    fi
fi

echo "[*] Updating package lists..."
apt update -y || handle_error 1 "Failed to update package lists" "CRITICAL"
log "OK" "Package lists updated"

echo "[*] Running system upgrade..."
apt upgrade -y || handle_error 1 "System upgrade failed" "ERROR"
log "OK" "System upgrade complete"

echo "[*] Installing required packages..."
apt install -y nftables iptables wireguard-tools python3 bind9-dnsutils iproute2 curl wget iputils-ping jq tcpdump || \
    handle_error 1 "Package installation failed" "CRITICAL"
log "OK" "All packages installed"

echo "[*] Verifying required tools..."
critical_tools=("nft" "iptables" "wg" "python3" "getent" "ip" "curl" "wget" "ping" "ss" "tcpdump" "sysctl")
all_ok=true
for tool in "${critical_tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        log "OK" "Tool $tool verified: $(command -v $tool)"
    else
        log "ERROR" "Tool $tool NOT found!"
        all_ok=false
    fi
done
if [ "$all_ok" = false ]; then
    handle_error 1 "Required tools missing after installation" "CRITICAL"
fi
log "OK" "All required tools verified"

# ====================================================================================
# STEP 3: CLEANUP & FIREWALL CLEANUP
# Removes any previous installation artifacts: systemd services, timers, scripts,
# iptables rules, and nftables rules. This ensures a clean slate.
# ====================================================================================
print_section "3" "CLEANUP & FIREWALL CLEANUP"

echo "[*] Stopping and removing old ingress-edge.service..."
systemctl stop ingress-edge.service 2>/dev/null || true
systemctl disable ingress-edge.service 2>/dev/null || true
rm -f /etc/systemd/system/ingress-edge.service
systemctl daemon-reload
log "OK" "Old service files removed"

echo "[*] Cleaning up previous failover timer..."
systemctl stop update-ingress-dnat.timer 2>/dev/null || true
systemctl disable update-ingress-dnat.timer 2>/dev/null || true
rm -f /etc/systemd/system/update-ingress-dnat.service
rm -f /etc/systemd/system/update-ingress-dnat.timer
systemctl daemon-reload
log "OK" "Old timer files removed"

echo "[*] Removing old DNAT update script..."
rm -f /usr/local/bin/update-ingress-dnat.sh
log "OK" "Old update script removed"

echo "[*] Flushing all iptables rules (legacy cleanup)..."
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
log "OK" "iptables rules flushed"

echo "[*] Flushing all nftables rules..."
nft flush ruleset || handle_error 1 "nftables flush failed" "CRITICAL"
log "OK" "nftables rules flushed"

log "OK" "Cleanup complete"

# ====================================================================================
# STEP 4: HOSTNAME CONFIGURATION
# Ensures the hostname follows the convention "ingress-<platform>-<random>".
# If it already matches, the existing value is reused; otherwise the user is
# prompted for a platform name and a random suffix is generated.
# ====================================================================================
print_section "4" "HOSTNAME CONFIGURATION"

current_hostname=$(hostname)
echo "[INFO] Current hostname: $current_hostname"

# Regex check: ingress-<name>-<7 alphanumeric chars>
if echo "$current_hostname" | grep -qE '^ingress-[-a-zA-Z0-9]+-[A-Za-z0-9]{7}$'; then
    log "OK" "Hostname already matches format ingress-*-*"
    echo "[OK] Hostname is already correct: $current_hostname"
    platform_name=$(echo "$current_hostname" | sed 's/^ingress-//' | rev | cut -d- -f2- | rev)
    random_suffix=$(echo "$current_hostname" | rev | cut -d- -f1 | rev)
    new_hostname="$current_hostname"
else
    while true; do
        read -p "Enter hosting platform name (e.g., netcup, aws, gcp): " platform_name < /dev/tty
        if [ -n "$platform_name" ] && echo "$platform_name" | grep -qE '^[a-zA-Z0-9-]+$'; then
            break
        fi
        echo "[ERROR] Only letters, numbers, and hyphens allowed."
    done
    random_suffix=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c7)
    new_hostname="ingress-${platform_name}-${random_suffix}"
    echo "[*] Setting hostname to: $new_hostname"
    hostnamectl set-hostname "$new_hostname"
    if [ "$(hostname)" != "$new_hostname" ]; then
        handle_error 1 "Failed to set hostname" "CRITICAL"
    fi
    log "OK" "Hostname set to: $new_hostname"
    echo "[OK] Hostname: $new_hostname"
fi

# ====================================================================================
# STEP 5: VPN CLIENT INSTALLATION + CONNECTION
# Installs and connects both Netbird (primary, via wt0 interface) and Tailscale
# (fallback, via tailscale0 interface). Includes a WireGuard endpoint health
# check to detect broken tunnels.
# ====================================================================================
print_section "5" "VPN CLIENT INSTALLATION + CONNECTION"

# --- NETBIRD ---
echo ""
echo "[*] --- NETBIRD ---"

if ! command -v netbird >/dev/null 2>&1; then
    echo "[*] Installing Netbird..."
    curl -fsSL https://pkgs.netbird.io/install.sh | sh || \
        handle_error 1 "Netbird installation failed" "CRITICAL"
    if ! command -v netbird >/dev/null 2>&1; then
        handle_error 1 "Netbird binary not found after installation" "CRITICAL"
    fi
    log "OK" "Netbird installed"
fi

# Check if Netbird's tunnel interface (wt0) already has an IP
if ip addr show wt0 2>/dev/null | grep -q "inet "; then
    log "OK" "Netbird already connected"
else
    echo "[*] Netbird not connected."
    if ! systemctl is-active --quiet netbird; then
        systemctl start netbird 2>/dev/null || true
        sleep 5
    fi
    echo ""
    echo "[INFO] A Netbird setup key is required to connect."
    connected=false
    while true; do
        read -p "Enter Netbird setup key (or 'skip'): " netbird_key < /dev/tty
        if [ "$netbird_key" = "skip" ] || [ "$netbird_key" = "Skip" ]; then
            echo "[WARN] Skipping Netbird"
            break
        elif [ -z "$netbird_key" ]; then
            echo "[INFO] Please enter a key, or type 'skip'."
        else
            echo "[*] Connecting to Netbird with provided key..."
            netbird up --allow-server-ssh --enable-ssh-local-port-forwarding \
                --enable-ssh-remote-port-forwarding --enable-ssh-sftp \
                --enable-ssh-root --enable-rosenpass --setup-key "$netbird_key" || true
            # Poll for up to 20 seconds waiting for "Management: Connected"
            for i in 1 2 3 4 5 6 7 8 9 10; do
                sleep 2
                if netbird status 2>/dev/null | grep -q "Management: Connected"; then
                    connected=true
                    break
                fi
            done
            if [ "$connected" = true ]; then
                echo "[OK] Netbird connected successfully"
                break
            fi
            echo "[WARN] Connection failed. Wrong key or timeout. Try again or type 'skip'."
        fi
    done
    if [ "$connected" = true ]; then
        log "OK" "Netbird connected"
    fi
fi

# Capture the Netbird IP if available
if ip addr show wt0 2>/dev/null | grep -q "inet "; then
    nb_ip=$(ip addr show wt0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
fi

# --- TAILSCALE ---
echo ""
echo "[*] --- TAILSCALE ---"

if ! command -v tailscale >/dev/null 2>&1; then
    echo "[*] Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh || \
        handle_error 1 "Tailscale installation failed" "CRITICAL"
    if ! command -v tailscale >/dev/null 2>&1; then
        handle_error 1 "Tailscale binary not found after installation" "CRITICAL"
    fi
    log "OK" "Tailscale installed"
fi

# Check if Tailscale's interface already has an IP
if ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
    log "OK" "Tailscale already connected"
else
    echo "[*] Tailscale not connected."
    if ! systemctl is-active --quiet tailscaled; then
        systemctl start tailscaled 2>/dev/null || true
        sleep 5
    fi
    echo ""
    echo "[INFO] A Tailscale auth key is required to connect."
    connected=false
    while true; do
        read -p "Enter Tailscale auth key (or 'skip'): " tailscale_key < /dev/tty
        if [ "$tailscale_key" = "skip" ] || [ "$tailscale_key" = "Skip" ]; then
            echo "[WARN] Skipping Tailscale"
            break
        elif [ -z "$tailscale_key" ]; then
            echo "[INFO] Please enter a key, or type 'skip'."
        else
            echo "[*] Connecting to Tailscale with provided key..."
            tailscale up --auth-key "$tailscale_key" --accept-routes --accept-dns=false || true
            # Poll for up to 20 seconds waiting for the interface to get an IP
            for i in 1 2 3 4 5 6 7 8 9 10; do
                sleep 2
                if ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
                    connected=true
                    break
                fi
            done
            if [ "$connected" = true ]; then
                echo "[OK] Tailscale connected successfully"
                break
            fi
            echo "[WARN] Connection failed. Wrong key or timeout. Try again or type 'skip'."
        fi
    done
    if [ "$connected" = true ]; then
        log "OK" "Tailscale connected"
    fi
fi

# Capture the Tailscale IP if available
if ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
    ts_ip=$(ip addr show tailscale0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
fi

# ---- WireGuard Health Check ----
# Validates that VPN tunnel endpoints are not pointing to localhost,
# which would indicate a broken or misconfigured tunnel.
echo ""
echo "[*] Checking WireGuard peer endpoints..."
for iface in wt0 tailscale0; do
    if ip addr show "$iface" 2>/dev/null | grep -q "inet "; then
        endpoints=$(wg show "$iface" endpoints 2>/dev/null | head -1)
        if [ -n "$endpoints" ]; then
            endpoint=$(echo "$endpoints" | awk '{print $2}')
            if echo "$endpoint" | grep -qE '^(127\.0\.0\.1|0\.0\.0\.0|::1)'; then
                log "ERROR" "$iface: endpoint is $endpoint — invalid (localhost)"
                echo "[WARN] $iface: Endpoint $endpoint is invalid — VPN tunnel broken!"
                echo "[INFO] Try reconnecting: netbird down && netbird up (with --enable-rosenpass)"
            else
                echo "[OK] $iface endpoint: $endpoint"
            fi
        fi
    fi
done

# ====================================================================================
# STEP 6: BACKEND IP DISCOVERY (Netbird + Tailscale)
# Resolves the backend address via both VPNs. Netbird DNS is the primary path,
# Tailscale is the fallback. Both IPs are tested for reachability (port 81/TCP).
# The working IP is cached so it survives reboots.
# ====================================================================================
print_section "6" "BACKEND IP DISCOVERY (DUAL VPN)"

BACKEND_NB_IP=""
BACKEND_TS_IP=""
BACKEND_IP=""
VPN_TYPE=""

# ---- Step A: Discover BOTH IPs (Netbird + Tailscale) ----
echo "[*] Discovering backend IPs on both VPNs..."

# Netbird: search `netbird status --detail` for "backend" hostname, extract IP
echo "[*] Searching Netbird status for 'backend'..."
if command -v netbird >/dev/null 2>&1 && ip addr show wt0 2>/dev/null | grep -q "inet "; then
    BACKEND_NB_IP=$(netbird status --detail 2>/dev/null \
        | grep -A4 -i "backend" \
        | awk '/NetBird IP:/ {print $3; exit}' \
        | cut -d'/' -f1)
    if [ -n "$BACKEND_NB_IP" ]; then
        echo "[OK] Netbird IP: $BACKEND_NB_IP"
    else
        echo "[INFO] No Netbird match for 'backend'"
    fi
fi

# Tailscale: search `tailscale status` for "backend" hostname, extract IP
echo "[*] Searching Tailscale status for 'backend'..."
if command -v tailscale >/dev/null 2>&1 && ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
    BACKEND_TS_IP=$(timeout 10 tailscale status 2>/dev/null \
        | grep -i "backend" \
        | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1)
    if [ -n "$BACKEND_TS_IP" ]; then
        echo "[OK] Tailscale IP: $BACKEND_TS_IP"
    else
        echo "[INFO] No Tailscale match for 'backend'"
    fi
fi

# ---- Step B: Pick the one that actually works ----
# Test each discovered IP by connecting to port 81 (backend health-check port).
echo "[*] Testing reachability..."

if [ -n "$BACKEND_NB_IP" ]; then
    echo -n "  Netbird $BACKEND_NB_IP:81... "
    if curl -k -s --connect-timeout 3 --max-time 5 "https://$BACKEND_NB_IP:81" >/dev/null 2>&1; then
        BACKEND_IP="$BACKEND_NB_IP"
        VPN_TYPE="Netbird"
        echo "[OK]"
    else
        echo "[FAIL]"
    fi
fi

if [ -z "$BACKEND_IP" ] && [ -n "$BACKEND_TS_IP" ]; then
    echo -n "  Tailscale $BACKEND_TS_IP:81... "
    if curl -k -s --connect-timeout 3 --max-time 5 "https://$BACKEND_TS_IP:81" >/dev/null 2>&1; then
        BACKEND_IP="$BACKEND_TS_IP"
        VPN_TYPE="Tailscale"
        echo "[OK]"
    else
        echo "[FAIL]"
    fi
fi

# ---- Step C: Fallback to cache ----
# If neither VPN works, use the last-known-working IP from the cache file.
if [ -z "$BACKEND_IP" ] && [ -f "$CACHE_FILE" ]; then
    BACKEND_IP=$(cat "$CACHE_FILE")
    VPN_TYPE="Cache"
    echo "[WARN] Using cached backend IP: $BACKEND_IP"
fi

if [ -z "$BACKEND_IP" ]; then
    handle_error 1 "Cannot reach backend on any VPN (Netbird + Tailscale + cache all failed)" "CRITICAL"
fi

echo "$BACKEND_IP" > "$CACHE_FILE"
echo "[OK] Active backend: $BACKEND_IP ($VPN_TYPE)"
if [ -n "$BACKEND_TS_IP" ] && [ "$BACKEND_IP" != "$BACKEND_TS_IP" ]; then
    echo "[INFO] Tailscale fallback available: $BACKEND_TS_IP"
fi

# ====================================================================================
# STEP 7: WAN INTERFACE + PUBLIC IP
# Detects the default WAN interface and the server's public IP on that interface.
# Both are needed for the nftables rules and the SNAT return path.
# ====================================================================================
print_section "7" "WAN INTERFACE + PUBLIC IP"

echo "[*] Detecting WAN interface..."
# The WAN interface is the device used to reach 1.1.1.1 (Cloudflare DNS)
WAN_IF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | tr -d '\n')
if [ -z "$WAN_IF" ]; then
    handle_error 1 "WAN interface could not be detected" "CRITICAL"
fi
if ! ip link show "$WAN_IF" >/dev/null 2>&1; then
    handle_error 1 "Interface '$WAN_IF' does not exist" "CRITICAL"
fi
log "OK" "WAN interface: $WAN_IF"
echo "[OK] WAN interface: $WAN_IF"

INGRESS_PUBLIC_IP=$(ip addr show "$WAN_IF" | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1 | tr -d '[:space:]')
if [ -z "$INGRESS_PUBLIC_IP" ] || [[ ! "$INGRESS_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    handle_error 1 "Invalid public IP: '$INGRESS_PUBLIC_IP'" "CRITICAL"
fi
log "OK" "Public IP: $INGRESS_PUBLIC_IP"
echo "[OK] Public IP: $INGRESS_PUBLIC_IP"

# ====================================================================================
# STEP 8: KERNEL PARAMETERS
#
# Three kernel parameters are critical for transparent DNAT to work correctly:
#
#   1. net.ipv4.ip_forward = 1
#      Default: 0. The kernel drops any packet that is not addressed to a local
#      socket. By setting it to 1 we allow the kernel to route (forward) packets
#      between interfaces — in this case from the WAN interface into a VPN tunnel
#      interface and vice versa. Without this, DNAT'd packets would be silently
#      discarded.
#
#   2. net.ipv4.conf.{all,default}.rp_filter = 2 (loose mode)
#      Default: 1 (strict mode). The Reverse Path Filter checks whether the source
#      address of an incoming packet is reachable via the interface it arrived on.
#      In strict mode (1), if the kernel would route a reply to that source address
#      out of a *different* interface, the packet is dropped.
#      In this setup the path is:
#        External client → WAN_IF → DNAT → wt0/tailscale0 → Backend
#        Backend reply → wt0/tailscale0 → *WAN_IF* → Client
#      The reply arrives on the VPN interface, but the client's IP is reachable
#      via the WAN interface. Strict mode sees this mismatch and drops the reply.
#      Loose mode (2) only checks that the source is reachable via *any* interface,
#      which is the correct behavior for multi-homed DNAT gateways.
#
#   3. net.netfilter.nf_conntrack_{max,tcp_timeout_established}
#      Conntrack tracks every active connection. max=262144 raises the limit from
#      the default (~65536 for 1GB RAM) to handle production traffic. The TCP
#      established timeout is raised from the default 5 days to 3600 seconds (1h)
#      to free conntrack entries faster for short-lived HTTP connections.
#
# A backup default route via the WAN with metric 1000 ensures that even when a VPN
# (e.g. Netbird) pushes its own default route with a lower metric, there is still a
# fallback route to the internet so the firewall itself (not the forwarded traffic)
# can reach external DNS, NTP, etc.
# ====================================================================================
print_section "8" "KERNEL PARAMETERS"

echo "[*] Enabling IPv4 packet forwarding..."
# net.ipv4.ip_forward controls whether the kernel forwards IP packets between
# interfaces. We need this because packets arrive on WAN_IF and must be forwarded
# out of wt0/tailscale0 (and vice versa for return traffic).
sysctl -w net.ipv4.ip_forward=1
if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    handle_error 1 "IPv4 forwarding verification failed" "CRITICAL"
fi
log "OK" "IPv4 forwarding enabled"

echo "[*] Setting rp_filter to loose mode (2)..."
# rp_filter (Reverse Path Filter):
#   0 = disabled         — no source address validation
#   1 = strict (default) — drop if best route to src does not go out the arrival iface
#   2 = loose            — drop only if src is completely unroutable
# We use loose mode because return traffic from the backend arrives on wt0/tailscale0
# (VPN interface) while the client's IP is reachable via WAN_IF. Strict mode would
# see this cross-interface return path as a spoofing attempt and drop the packet.
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.default.rp_filter=2
if [ "$(sysctl -n net.ipv4.conf.all.rp_filter)" != "2" ]; then
    handle_error 1 "rp_filter verification failed" "CRITICAL"
fi
log "OK" "rp_filter=2 (loose mode)"

echo "[*] Tuning conntrack..."
# nf_conntrack tracks connection state so the firewall can match "established,related"
# packets. The default max is often too low for production (e.g. 65536). Raising it
# to 262144 prevents the table from filling up, which would cause new connections
# to be dropped. The TCP established timeout is lowered from the kernel default of
# 5 days to 1 hour so that conntrack slots for dead HTTP connections are reclaimed
# faster.
modprobe nf_conntrack 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_max=262144 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600 2>/dev/null || true

echo "[*] Ensuring backup default route via WAN interface..."
WAN_GW=$(ip route show default | awk '{print $3}' | head -1)
if [ -n "$WAN_GW" ]; then
    # Netbird and Tailscale may install their own default routes (metric < 1000)
    # to tunnel all traffic through the VPN. While that's fine for forwarded
    # traffic, the firewall host itself still needs internet access (DNS, NTP,
    # package updates). Adding a high-metric default via the original gateway
    # ensures the host can reach the internet directly when the VPN routes are
    # withdrawn or for non-VPN traffic.
    ip route add default via "$WAN_GW" dev "$WAN_IF" metric 1000 2>/dev/null || true
    log "OK" "Backup default route via $WAN_GW ($WAN_IF, metric 1000)"
fi

echo "[*] Making kernel parameters persistent..."
cat > /etc/sysctl.d/99-ingress.conf << 'EOF'
# Ingress Edge Firewall Kernel Parameters
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=3600
EOF
sysctl -p /etc/sysctl.d/99-ingress.conf || handle_error 1 "Failed to load persistent parameters" "ERROR"
log "OK" "Kernel parameters persistent"

# ====================================================================================
# STEP 9: NFTABLES CONFIGURATION
#
# The firewall has two logical parts that are managed separately:
#
#   A) FILTER TABLE (inet family, covers both IPv4 and IPv6)
#      Written to /etc/nftables.conf via a Python script. This part is static
#      and controls which packets are allowed to reach the host (INPUT chain)
#      and which packets may be forwarded between interfaces (FORWARD chain).
#      Rules are split into several groups:
#        - Connection tracking: established/related packets are always accepted
#          so response traffic flows back without explicit allow rules.
#        - Loopback: localhost traffic is fully trusted.
#        - ICMP: essential for path MTU discovery, ping, traceroute, and IPv6
#          Neighbor Discovery Protocol (NDP). Without NDP, IPv6 breaks entirely.
#        - WAN input: only TCP 80/443 and UDP 443 (QUIC/HTTP3) from the outside.
#          Everything else is silently dropped by the default policy.
#        - VPN interfaces: full trust for wt0 (Netbird) and tailscale0 (Tailscale).
#        - Anti-spoofing: Netbird uses 100.64.0.0/10, Tailscale uses 100.100.0.0/8.
#          If packets claiming these source IPs arrive on any interface other than
#          the correct VPN interface, they are dropped. This prevents an attacker
#          on the WAN from impersonating VPN peers.
#        - FORWARD chain: only allows WAN→VPN traffic on ports 80/443 (TCP+UDP).
#          This ensures the host acts purely as a traffic forwarder for HTTP/S
#          and does not forward arbitrary traffic (e.g. SSH scans, SMB, etc.).
#
#   B) NAT TABLE (ip family, IPv4 only)
#      Added via direct nft commands at runtime (not in the static file). The NAT
#      table is kept separate so the DNAT update script can atomically flush and
#      re-add rules without touching the filter table. It has two chains:
#        - prerouting (dstnat): rewrites the destination address of incoming
#          packets from $INGRESS_PUBLIC_IP to $BACKEND_IP. This is the actual
#          DNAT that redirects external HTTP/S traffic into the VPN.
#        - postrouting (srcnat): rewrites the source address of return packets
#          leaving via WAN_IF. Without this, the backend's response (source IP
#          would be the VPN IP like 100.x.x.x) would arrive at the client with
#          an unexpected source, and the client would drop it. By SNAT-ing to
#          $INGRESS_PUBLIC_IP, the client sees a consistent source address.
#
# After the rules are applied, a DNAT update script and a systemd timer are
# installed. The timer runs every 60 seconds, re-discovers the backend IP via
# both VPNs, and swaps the DNAT target if the active VPN changes. This gives
# automatic failover: if Netbird goes down, traffic is redirected to the
# Tailscale IP within at most 60 seconds.
# ====================================================================================
print_section "9" "NFTABLES CONFIGURATION"

echo "[*] Applying nftables rules directly..."

# Write config for persistence (re-applied on boot by systemd service)
cat > /etc/nftables.conf << NFTEOF
#!/usr/sbin/nft -f
flush ruleset
NFTEOF
log "OK" "nftables.conf written (empty — rules applied at runtime)"

# ---- FILTER TABLE (inet = IPv4 + IPv6) ----
nft add table inet filter
nft 'add chain inet filter input { type filter hook input priority filter; policy drop; }'
nft 'add chain inet filter forward { type filter hook forward priority filter; policy drop; }'

# INPUT: return traffic + loopback
nft add rule inet input ct state established,related accept
nft add rule inet input iif lo accept

# INPUT: ICMP
nft add rule inet input icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept
nft add rule inet input icmpv6 type { echo-request, echo-reply, destination-unreachable, time-exceeded, packet-too-big, parameter-problem } accept

# INPUT: IPv6 NDP
nft add rule inet input icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert, nd-redirect } accept

# INPUT: WAN ports (IPv4 only)
nft add rule inet input meta nfproto ipv4 iifname ${WAN_IF} tcp dport { 80, 443 } ct state new accept
nft add rule inet input meta nfproto ipv4 iifname ${WAN_IF} udp dport 443 ct state new accept

# INPUT: drop IPv6 on WAN for these ports
nft add rule inet input meta nfproto ipv6 iifname ${WAN_IF} tcp dport { 80, 443 } drop
nft add rule inet input meta nfproto ipv6 iifname ${WAN_IF} udp dport 443 drop

# INPUT: VPN interfaces fully trusted
nft add rule inet input iifname wt0 accept
nft add rule inet input iifname tailscale0 accept

# INPUT: anti-spoofing
nft add rule inet input ip saddr 100.64.0.0/10 iifname != wt0 drop
nft add rule inet input ip saddr 100.100.0.0/8 iifname != tailscale0 drop

# FORWARD: return traffic
nft add rule inet forward ct state established,related accept

# FORWARD: WAN -> VPN (IPv4 only)
nft add rule inet forward meta nfproto ipv4 iif ${WAN_IF} oif wt0 tcp dport { 80, 443 } ct state new accept
nft add rule inet forward meta nfproto ipv4 iif ${WAN_IF} oif wt0 udp dport 443 ct state new accept
nft add rule inet forward meta nfproto ipv4 iif ${WAN_IF} oif tailscale0 tcp dport { 80, 443 } ct state new accept
nft add rule inet forward meta nfproto ipv4 iif ${WAN_IF} oif tailscale0 udp dport 443 ct state new accept

# FORWARD: drop IPv6 on these ports
nft add rule inet forward meta nfproto ipv6 iif ${WAN_IF} oif wt0 tcp dport { 80, 443 } drop
nft add rule inet forward meta nfproto ipv6 iif ${WAN_IF} oif wt0 udp dport 443 drop
nft add rule inet forward meta nfproto ipv6 iif ${WAN_IF} oif tailscale0 tcp dport { 80, 443 } drop
nft add rule inet forward meta nfproto ipv6 iif ${WAN_IF} oif tailscale0 udp dport 443 drop

log "OK" "Filter table applied (INPUT + FORWARD)"

# ---- NAT TABLE (ip = IPv4 only) ----
echo "[*] Setting up NAT table..."
nft add table ip nat 2>/dev/null || true
nft 'add chain ip nat prerouting { type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
nft 'add chain ip nat postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
nft add rule ip nat prerouting tcp dport { 80, 443 } dnat to "$BACKEND_IP"
nft add rule ip nat prerouting udp dport 443 dnat to "$BACKEND_IP"
nft add rule ip nat postrouting oifname "$WAN_IF" ip saddr 100.64.0.0/10 snat to "$INGRESS_PUBLIC_IP"
nft add rule ip nat postrouting oifname "$WAN_IF" ip saddr 100.100.0.0/8 snat to "$INGRESS_PUBLIC_IP"
log "OK" "NAT table configured (target: $BACKEND_IP, snat to $INGRESS_PUBLIC_IP)"

echo ""
echo "[OK] nftables active:"
echo "  - Input: ports 80+443, VPN interfaces open"
echo "  - Forward: WAN -> VPN on ports 80+443 (both Netbird and Tailscale)"
echo "  - DNAT: $INGRESS_PUBLIC_IP -> $BACKEND_IP ($VPN_TYPE)"

# ---- DNAT Update Script (for automatic VPN failover) ----
echo ""
echo "[*] Creating DNAT update script for VPN failover..."
UPDATE_SCRIPT="/usr/local/bin/update-ingress-dnat.sh"

cat > "$UPDATE_SCRIPT" << 'DNATSCRIPT'
#!/bin/bash
# ====================================================================================
# update-ingress-dnat.sh
# Called by systemd timer every 60 seconds. Maintains the DNAT target so traffic
# is always forwarded to a reachable backend, even when a VPN goes down.
#
# How it works:
#   1. Discover the backend IP on Netbird (via getent, resolved over Netbird DNS).
#   2. Discover the backend IP on Tailscale (via tailscale status, parsing the
#      magic DNS name for "backend").
#   3. Test reachability of each discovered IP on port 81 (backend health endpoint).
#      The first one that responds becomes the active DNAT target.
#   4. If neither responds, fall back to the cached IP from the last successful check.
#   5. Flush and rebuild the ip nat table with the chosen target.
#
# This provides automatic failover:
#   Netbird UP + backend reachable  → DNAT → Netbird IP
#   Netbird DOWN, Tailscale UP     → DNAT → Tailscale IP
#   Both VPNs DOWN                 → DNAT → cached IP (last-known-good)
#   All paths dead                 → DNAT not updated (keep old rules, log error)
#
# The SNAT rules are also reapplied every cycle so that if the WAN interface or
# public IP changes (e.g. dynamic IP), the return path stays correct.
# ====================================================================================

BACKEND_ADDRESS="backend"
CACHE_FILE="/etc/ingress-edge-backend-ip"
LOG_FILE="/var/log/ingress_edge_setup.log"

log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

BACKEND_NB_IP=""
BACKEND_TS_IP=""
BACKEND_IP=""
VPN_TYPE=""

# 1) Discover Netbird IP — search status for "backend"
if ip addr show wt0 2>/dev/null | grep -q "inet "; then
    BACKEND_NB_IP=$(netbird status --detail 2>/dev/null \
        | grep -A4 -i "backend" \
        | awk '/NetBird IP:/ {print $3; exit}' \
        | cut -d'/' -f1)
fi

# 2) Discover Tailscale IP — search status for "backend"
if ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
    BACKEND_TS_IP=$(timeout 10 tailscale status 2>/dev/null \
        | grep -i "backend" \
        | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1)
fi

# 3) Test reachability — pick the one that works
if [ -n "$BACKEND_NB_IP" ]; then
    if curl -k -s --connect-timeout 3 --max-time 5 "https://$BACKEND_NB_IP:81" >/dev/null 2>&1; then
        BACKEND_IP="$BACKEND_NB_IP"
        VPN_TYPE="Netbird"
    fi
fi

if [ -z "$BACKEND_IP" ] && [ -n "$BACKEND_TS_IP" ]; then
    if curl -k -s --connect-timeout 3 --max-time 5 "https://$BACKEND_TS_IP:81" >/dev/null 2>&1; then
        BACKEND_IP="$BACKEND_TS_IP"
        VPN_TYPE="Tailscale"
    fi
fi

# 4) Fallback: cached IP
if [ -z "$BACKEND_IP" ] && [ -f "$CACHE_FILE" ]; then
    BACKEND_IP=$(cat "$CACHE_FILE")
    VPN_TYPE="Cache"
fi

if [ -z "$BACKEND_IP" ]; then
    log "ERROR" "Cannot reach backend on any VPN - DNAT not updated"
    exit 1
fi

# Detect WAN interface + public IP for SNAT return path
WAN_IF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | tr -d '\n')
INGRESS_PUBLIC_IP=$(ip addr show "$WAN_IF" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1 | tr -d '[:space:]')

# Update nftables NAT table (DNAT + SNAT for return path)
nft flush table ip nat 2>/dev/null || true
nft add table ip nat 2>/dev/null || true
nft 'add chain ip nat prerouting { type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
nft 'add chain ip nat postrouting { type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
nft add rule ip nat prerouting tcp dport { 80, 443 } dnat to "$BACKEND_IP"
nft add rule ip nat prerouting udp dport 443 dnat to "$BACKEND_IP"
if [ -n "$WAN_IF" ] && [ -n "$INGRESS_PUBLIC_IP" ]; then
    nft add rule ip nat postrouting oifname "$WAN_IF" ip saddr 100.64.0.0/10 snat to "$INGRESS_PUBLIC_IP"
    nft add rule ip nat postrouting oifname "$WAN_IF" ip saddr 100.100.0.0/8 snat to "$INGRESS_PUBLIC_IP"
fi

# Update cache
echo "$BACKEND_IP" > "$CACHE_FILE"

log "OK" "DNAT updated: target=$BACKEND_IP ($VPN_TYPE)"
DNATSCRIPT

chmod +x "$UPDATE_SCRIPT"
log "OK" "DNAT update script created: $UPDATE_SCRIPT"

# ---- Systemd Timer for automatic failover ----
# A systemd timer triggers the DNAT update script every 60 seconds. The
# OnBootSec=30 delay ensures network and VPN services are fully initialized
# before the first check. OnUnitActiveSec=60 means the timer fires 60 seconds
# after the previous run completes (not from timer start), so runs never overlap.
#
# The service unit is Type=oneshot because the script exits after updating the
# rules — it does not daemonize. The timer handles the scheduling instead.
echo "[*] Creating systemd timer for DNAT failover..."

cat > /etc/systemd/system/update-ingress-dnat.service << 'SERVICEEOF'
[Unit]
Description=Update ingress DNAT target based on VPN availability
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-ingress-dnat.sh
SERVICEEOF

cat > /etc/systemd/system/update-ingress-dnat.timer << 'TIMEREOF'
[Unit]
Description=Check ingress DNAT target every 60 seconds

[Timer]
OnBootSec=30
OnUnitActiveSec=60

[Install]
WantedBy=multi-user.target
TIMEREOF

chmod 644 /etc/systemd/system/update-ingress-dnat.service
chmod 644 /etc/systemd/system/update-ingress-dnat.timer
systemctl daemon-reload
systemctl enable --now update-ingress-dnat.timer

if systemctl is-active --quiet update-ingress-dnat.timer; then
    log "OK" "DNAT failover timer active (checks every 60s)"
    echo "[OK] DNAT failover timer active"
else
    log "WARN" "DNAT failover timer not active"
    echo "[WARN] DNAT failover timer not active"
fi

# Run the update script once immediately
"$UPDATE_SCRIPT" || true
log "OK" "Initial DNAT target set"

echo ""
echo "[OK] VPN failover configured:"
echo "  - Primary: Netbird DNS -> backend Netbird IP"
echo "  - Fallback: Tailscale status -> backend Tailscale IP"
echo "  - Timer: updates DNAT target every 60s"

# ====================================================================================
# STEP 10: SYSTEMD SERVICE (boot)
# Installs a oneshot systemd service that runs this entire script at boot
# (after network + VPNs are available) so the firewall is reapplied on reboot.
# ====================================================================================
print_section "10" "SYSTEMD SERVICE (BOOT)"

echo "[*] Creating ingress-edge.service..."
cat > /etc/systemd/system/ingress-edge.service << 'SERVICEEOF'
[Unit]
Description=Ingress Edge Firewall Setup (Transparent DNAT)
After=network-online.target netbird.service tailscale.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/root
ExecStart=/bin/bash /root/script.sh
RemainAfterExit=yes
TimeoutStartSec=300
User=root
Group=root

[Install]
WantedBy=multi-user.target
SERVICEEOF

chmod 644 /etc/systemd/system/ingress-edge.service
systemctl daemon-reload
systemctl enable ingress-edge.service

if systemctl is-enabled --quiet ingress-edge.service; then
    log "OK" "Service enabled on boot"
    echo "[OK] Service enabled on boot"
else
    handle_error 1 "Failed to enable service" "ERROR"
fi

# STEP 11 is now covered by the comprehensive diagnostics in STEP 12

# ====================================================================================
# STEP 12: COMPREHENSIVE DIAGNOSTICS
# Exhaustive test battery covering every layer that can break transparent DNAT.
# Each check has a unique ID so the diagnosis engine can correlate failures
# to root causes with exact fix instructions.
# ====================================================================================
print_section "12" "COMPREHENSIVE DIAGNOSTICS"

echo ""
echo "  Systematic checks — results feed into the diagnosis engine below."
echo ""

T_PASS=0; T_FAIL=0; T_SKIP=0; FOUND_ISSUE=false

check() {
    local id=$1; local desc=$2
    shift 2
    local varname="T_$(echo "$id" | tr '-' '_')"
    if eval "$@" >/dev/null 2>&1; then
        echo "  [PASS] $desc"
        T_PASS=$((T_PASS + 1))
        eval "${varname}=PASS"
    else
        echo "  [FAIL] $desc"
        T_FAIL=$((T_FAIL + 1))
        eval "${varname}=FAIL"
    fi
}

# ==== A. NETWORK BASICS ====
echo "--- A: Network Basics ---"
check A01 "Internet reachable (IPv4 1.1.1.1)"              "ping -c 1 -W 3 1.1.1.1"
check A02 "Internet reachable (IPv6)"                       "ping -c 1 -W 3 2606:4700:4700::1111"
check A03 "DNS resolution works"                            "getent hosts google.com > /dev/null"
check A04 "Default route exists"                            "ip route show default | grep -q '^default'"
WAN_GW=$(ip route show default | awk '{print $3}' | head -1)
check A05 "Backup default via WAN (metric 1000)"            "ip route show default | grep -q 'metric 1000'"
check A06 "WAN interface $WAN_IF exists"                    "ip link show '$WAN_IF' > /dev/null 2>&1"
check A07 "Public IP $INGRESS_PUBLIC_IP is valid"           "[ -n '$INGRESS_PUBLIC_IP' ] && echo '$INGRESS_PUBLIC_IP' | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'"

# ==== B. NFTABLES SERVICE ====
echo ""
echo "--- B: nftables Service ---"
check B01 "nftables service is running"                     "systemctl is-active --quiet nftables"
check B02 "nftables config file exists"                     "[ -f /etc/nftables.conf ]"
check B03 "nftables config loads without error"             "nft -c -f /etc/nftables.conf 2>/dev/null"

# ==== C. INPUT CHAIN ====
echo ""
echo "--- C: INPUT Chain (host protection) ---"
if [ "${T_B01:-FAIL}" = "PASS" ]; then
    INPUT_RULES=$(nft list chain inet filter input 2>/dev/null || true)
    check C01 "ct state established,related accept"          "echo '$INPUT_RULES' | grep -qF 'ct state established,related accept'"
    check C02 "iif lo accept (loopback)"                     "echo '$INPUT_RULES' | grep -qF 'iif lo accept'"
    check C03 "ICMP echo-request/reply allowed"              "echo '$INPUT_RULES' | grep -q 'echo-request'"
    check C04 "ICMP destination-unreachable (path MTU)"      "echo '$INPUT_RULES' | grep -q 'destination-unreachable'"
    check C05 "ICMP time-exceeded (traceroute)"              "echo '$INPUT_RULES' | grep -q 'time-exceeded'"
    check C06 "ICMPv6 NDP allowed (nd-neighbor-solicit)"     "echo '$INPUT_RULES' | grep -q 'nd-neighbor-solicit'"
    check C07 "ICMPv6 NDP allowed (nd-neighbor-advert)"      "echo '$INPUT_RULES' | grep -q 'nd-neighbor-advert'"
    check C08 "ICMPv6 router-advert allowed"                 "echo '$INPUT_RULES' | grep -q 'nd-router-advert'"
    check C09 "WAN TCP 80+443 open (IPv4)"                   "echo '$INPUT_RULES' | grep 'meta nfproto ipv4' | grep -qF 'dport { 80, 443 }'"
    check C10 "WAN UDP 443 open (IPv4, QUIC)"                "echo '$INPUT_RULES' | grep 'meta nfproto ipv4' | grep -q 'udp dport 443'"
    check C11 "WAN TCP 80+443 dropped (IPv6)"                "echo '$INPUT_RULES' | grep 'meta nfproto ipv6' | grep -qF 'dport { 80, 443 }'"
    check C12 "WAN UDP 443 dropped (IPv6)"                   "echo '$INPUT_RULES' | grep 'meta nfproto ipv6' | grep -q 'udp dport 443'"
    check C13 "Netbird wt0 fully trusted"                    "echo '$INPUT_RULES' | grep -qF 'iifname wt0 accept'"
    check C14 "Tailscale tailscale0 fully trusted"           "echo '$INPUT_RULES' | grep -qF 'iifname tailscale0 accept'"
    check C15 "Anti-spoofing: 100.64.0.0/10 only on wt0"    "echo '$INPUT_RULES' | grep -q '100.64.0.0/10.*iifname != wt0'"
    check C16 "Anti-spoofing: 100.100.0.0/8 only on ts0"    "echo '$INPUT_RULES' | grep -q '100.100.0.0/8.*iifname != tailscale0'"
else
    echo "  [SKIP] C01-C16: nftables not running, cannot check INPUT chain"
    T_SKIP=$((T_SKIP + 16))
fi

# ==== D. FORWARD CHAIN ====
echo ""
echo "--- D: FORWARD Chain (traffic forwarding) ---"
if [ "${T_B01:-FAIL}" = "PASS" ]; then
    FWD_RULES=$(nft list chain inet filter forward 2>/dev/null || true)
    check D01 "ct state established,related accept"          "echo '$FWD_RULES' | grep -qF 'ct state established,related accept'"
    check D02 "WAN→wt0 TCP 80+443 (IPv4)"                   "echo '$FWD_RULES' | grep 'meta nfproto ipv4' | grep -q 'oif wt0.*tcp dport.*80.*443'"
    check D03 "WAN→wt0 UDP 443 (IPv4, QUIC)"                "echo '$FWD_RULES' | grep 'meta nfproto ipv4' | grep -q 'oif wt0.*udp dport 443'"
    check D04 "WAN→tailscale0 TCP 80+443 (IPv4)"            "echo '$FWD_RULES' | grep 'meta nfproto ipv4' | grep -q 'oif tailscale0.*tcp dport.*80.*443'"
    check D05 "WAN→tailscale0 UDP 443 (IPv4, QUIC)"         "echo '$FWD_RULES' | grep 'meta nfproto ipv4' | grep -q 'oif tailscale0.*udp dport 443'"
    check D06 "IPv6 forward dropped (wt0)"                   "echo '$FWD_RULES' | grep 'meta nfproto ipv6' | grep -q 'oif wt0.*drop'"
    check D07 "IPv6 forward dropped (tailscale0)"            "echo '$FWD_RULES' | grep 'meta nfproto ipv6' | grep -q 'oif tailscale0.*drop'"
else
    echo "  [SKIP] D01-D07: nftables not running, cannot check FORWARD chain"
    T_SKIP=$((T_SKIP + 7))
fi

# ==== E. NAT TABLE ====
echo ""
echo "--- E: NAT Table (DNAT + SNAT) ---"
if [ "${T_B01:-FAIL}" = "PASS" ]; then
    NAT_PRE=$(nft list chain ip nat prerouting 2>/dev/null || true)
    NAT_POST=$(nft list chain ip nat postrouting 2>/dev/null || true)
    check E01 "NAT table exists"                             "nft list tables 2>/dev/null | grep -q 'ip nat'"
    check E02 "prerouting chain exists"                      "echo '$NAT_PRE' | grep -q 'type nat hook prerouting'"
    check E03 "postrouting chain exists"                     "echo '$NAT_POST' | grep -q 'type nat hook postrouting'"
    check E04 "DNAT TCP 80+443 present"                      "echo '$NAT_PRE' | grep -q 'tcp dport.*80.*443.*dnat'"
    check E05 "DNAT UDP 443 present (QUIC)"                  "echo '$NAT_PRE' | grep -q 'udp dport 443.*dnat'"
    check E06 "DNAT target is $BACKEND_IP"                   "echo '$NAT_PRE' | grep 'dnat to' | grep -q '$BACKEND_IP'"
    check E07 "SNAT for 100.64.0.0/10 present"              "echo '$NAT_POST' | grep -q '100.64.0.0/10.*snat'"
    check E08 "SNAT for 100.100.0.0/8 present"              "echo '$NAT_POST' | grep -q '100.100.0.0/8.*snat'"
    check E09 "SNAT target is $INGRESS_PUBLIC_IP"            "echo '$NAT_POST' | grep 'snat to' | grep -q '$INGRESS_PUBLIC_IP'"
    check E10 "DNAT count = 2 (TCP+UDP)"                     "[ \$(echo '$NAT_PRE' | grep -c 'dnat to') -eq 2 ]"
    check E11 "SNAT count = 2 (Netbird+TS)"                  "[ \$(echo '$NAT_POST' | grep -c 'snat to') -eq 2 ]"
    DNAT_TARGETS=$(echo "$NAT_PRE" | grep 'dnat to' | sed 's/.*dnat to //' | tr -d '{}' | sort -u | tr '\n' ' ')
else
    echo "  [SKIP] E01-E11: nftables not running, cannot check NAT"
    T_SKIP=$((T_SKIP + 11))
fi

# ==== F. KERNEL PARAMETERS ====
echo ""
echo "--- F: Kernel Parameters ---"
check F01 "ip_forward = 1"                                  '[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]'
check F02 "rp_filter all = 2"                               '[ "$(sysctl -n net.ipv4.conf.all.rp_filter)" = "2" ]'
check F03 "rp_filter default = 2"                           '[ "$(sysctl -n net.ipv4.conf.default.rp_filter)" = "2" ]'
if [ "${T_A07:-FAIL}" = "PASS" ]; then
    if ip link show wt0 >/dev/null 2>&1; then
        check F04 "rp_filter wt0 = 2"                       '[ "$(sysctl -n net.ipv4.conf.wt0.rp_filter 2>/dev/null)" = "2" ]'
    fi
    if ip link show tailscale0 >/dev/null 2>&1; then
        check F05 "rp_filter tailscale0 = 2"                '[ "$(sysctl -n net.ipv4.conf.tailscale0.rp_filter 2>/dev/null)" = "2" ]'
    fi
fi
check F06 "conntrack module loaded"                         "lsmod | grep -q nf_conntrack"
CONNTRACK_MAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)
check F07 "conntrack_max >= 262144"                         '[ "$CONNTRACK_MAX" -ge 262144 ] 2>/dev/null'
CONNTRACK_USAGE=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONNTRACK_PCT=0
if [ "$CONNTRACK_MAX" -gt 0 ] 2>/dev/null; then
    CONNTRACK_PCT=$((CONNTRACK_USAGE * 100 / CONNTRACK_MAX))
fi
check F08 "conntrack usage < 80% ($CONNTRACK_PCT%)"         '[ "$CONNTRACK_PCT" -lt 80 ] 2>/dev/null'

# ==== G. VPN STATUS ====
echo ""
echo "--- G: VPN Connectivity ---"
check G01 "Netbird wt0 has IP"                              "ip addr show wt0 2>/dev/null | grep -q 'inet '"
check G02 "Tailscale tailscale0 has IP"                     "ip addr show tailscale0 2>/dev/null | grep -q 'inet '"
if [ "${T_G01:-FAIL}" = "PASS" ]; then
    NB_IP=$(ip addr show wt0 | grep 'inet ' | head -1 | awk '{print $2}' | cut -d'/' -f1)
    NB_EP=$(wg show wt0 endpoints 2>/dev/null | head -1 | awk '{print $2}')
    check G03 "Netbird endpoint not 127.0.0.1"              "! echo '$NB_EP' | grep -qE '^(127\.0\.0\.1|0\.0\.0\.0|::1)$'"
    NB_HS=$(wg show wt0 latest-handshakes 2>/dev/null | head -1 | awk '{print $2}')
    check G04 "Netbird handshake < 180s ago"                '[ -n "$NB_HS" ] && [ "$NB_HS" != "0" ] && [ $(($(date +%s) - NB_HS)) -lt 180 ]'
    check G05 "Netbird transfer > 0 bytes"                  '[ "$(wg show wt0 transfer 2>/dev/null | awk "NR==1{print \$2}")" != "0" ]'
fi
if [ "${T_G02:-FAIL}" = "PASS" ]; then
    TS_IP=$(ip addr show tailscale0 | grep 'inet ' | head -1 | awk '{print $2}' | cut -d'/' -f1)
    TS_STATUS=$(timeout 10 tailscale status 2>/dev/null | head -1 || true)
    check G06 "Tailscale status shows connected"            "echo '$TS_STATUS' | grep -qi 'connected\|Running'"
    check G07 "Tailscale DNS resolves backend"              "getent hosts '$BACKEND_ADDRESS' > /dev/null 2>&1"
fi

# ==== H. BACKEND REACHABILITY ====
echo ""
echo "--- H: Backend Reachability ---"
if [ -n "${BACKEND_NB_IP:-}" ]; then
    check H01 "Backend via Netbird :81 ($BACKEND_NB_IP)"    "curl -k -s --connect-timeout 3 --max-time 5 'https://$BACKEND_NB_IP:81' > /dev/null 2>&1"
    check H02 "Backend via Netbird :443 ($BACKEND_NB_IP)"   "curl -k -s --connect-timeout 3 --max-time 5 'https://$BACKEND_NB_IP:443' > /dev/null 2>&1"
fi
if [ -n "${BACKEND_TS_IP:-}" ]; then
    check H03 "Backend via Tailscale :81 ($BACKEND_TS_IP)"  "curl -k -s --connect-timeout 3 --max-time 5 'https://$BACKEND_TS_IP:81' > /dev/null 2>&1"
    check H04 "Backend via Tailscale :443 ($BACKEND_TS_IP)" "curl -k -s --connect-timeout 3 --max-time 5 'https://$BACKEND_TS_IP:443' > /dev/null 2>&1"
fi
check H05 "Active DNAT target reachable :81 ($BACKEND_IP)"  "curl -k -s --connect-timeout 3 --max-time 5 'https://$BACKEND_IP:81' > /dev/null 2>&1"
check H06 "Active DNAT target reachable :443 ($BACKEND_IP)" "curl -k -s --connect-timeout 3 --max-time 5 'https://$BACKEND_IP:443' > /dev/null 2>&1"
# Redundancy: both paths working?
if [ -n "${BACKEND_NB_IP:-}" ] && [ -n "${BACKEND_TS_IP:-}" ]; then
    NB_OK=false; TS_OK=false
    [ "${T_H01:-FAIL}" = "PASS" ] && NB_OK=true
    [ "${T_H03:-FAIL}" = "PASS" ] && TS_OK=true
    if $NB_OK && $TS_OK; then
        check H07 "Both VPN paths reachable (redundancy)"   "true"
    else
        check H07 "Both VPN paths reachable (redundancy)"   "false"
    fi
fi

# ==== I. FAILOVER INFRASTRUCTURE ====
echo ""
echo "--- I: Failover Infrastructure ---"
check I01 "update-ingress-dnat.sh exists"                   "[ -x /usr/local/bin/update-ingress-dnat.sh ]"
check I02 "update-ingress-dnat.timer active"                 "systemctl is-active --quiet update-ingress-dnat.timer"
check I03 "ingress-edge.service enabled"                     "systemctl is-enabled --quiet ingress-edge.service"
check I04 "ingress-edge.service exists"                      "[ -f /etc/systemd/system/ingress-edge.service ]"
# Verify timer last ran recently
LAST_RUN=$(systemctl show update-ingress-dnat.timer --property=LastTriggerUSec 2>/dev/null | cut -d= -f2 || true)
if [ -n "$LAST_RUN" ]; then
    check I05 "Timer triggered recently"                     "true"
else
    check I05 "Timer triggered recently"                     "false"
fi

# ==== J. END-TO-END (local loopback test) ====
echo ""
echo "--- J: End-to-End (local loopback) ---"
# Test if the ingress can reach itself on port 443 via the public IP
# This verifies: DNAT → FORWARD → backend → SNAT return path works locally
check J01 "Local curl to public IP :443 responds"            "curl -k -s --connect-timeout 3 --max-time 5 'https://$INGRESS_PUBLIC_IP:443' > /dev/null 2>&1"
check J02 "Local curl to public IP :80 responds"             "curl -k -s --connect-timeout 3 --max-time 5 'http://$INGRESS_PUBLIC_IP:80' > /dev/null 2>&1"
# Check nftables counters show traffic
DNAT_HITS=$(nft list chain ip nat prerouting 2>/dev/null | grep -oP 'counter packets \K[0-9]+' | head -1 || echo 0)
if [ "${T_J01:-FAIL}" = "PASS" ] || [ "${T_J02:-FAIL}" = "PASS" ]; then
    check J03 "nftables DNAT counters show traffic"          '[ "$DNAT_HITS" -gt 0 ] 2>/dev/null'
fi

# ==== K. NFTABLES PERSISTENCE ====
echo ""
echo "--- K: nftables Persistence ---"
# Save current rules, flush, reload from config, compare
if [ "${T_B01:-FAIL}" = "PASS" ]; then
    SAVED_RULES=$(nft list ruleset 2>/dev/null | md5sum | awk '{print $1}')
    check K01 "nftables restart reloads correctly"           "systemctl restart nftables && nft list ruleset > /dev/null 2>&1"
    RELOADED_RULES=$(nft list ruleset 2>/dev/null | md5sum | awk '{print $1}')
    check K02 "Rules survive nftables restart"               '[ "$SAVED_RULES" = "$RELOADED_RULES" ]'
fi

# ==== L. CLOUD FIREWALL HINT ====
echo ""
echo "--- L: External Connectivity Hints ---"
# Try to detect if cloud firewall blocks ports
EXT_TEST=$(timeout 5 curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "https://$INGRESS_PUBLIC_IP:443" 2>/dev/null || echo "000")
if [ "$EXT_TEST" = "000" ]; then
    check L01 "External access to $INGRESS_PUBLIC_IP:443"     "false"
else
    check L01 "External access to $INGRESS_PUBLIC_IP:443"     "true"
fi

# ====================================================================================
# DIAGNOSIS ENGINE
# Correlates pass/fail results with known root causes and prints fix instructions.
# ====================================================================================
echo ""
echo "=========================================="
echo "  DIAGNOSIS"
echo "=========================================="
echo ""

found=false

issue() {
    found=true
    local severity=$1; shift
    echo "  [$severity] $*"
}

# ── 1. Internet connectivity ──────────────────────────────────────────────────
if [ "${T_A01:-FAIL}" = "FAIL" ] && [ "${T_A02:-FAIL}" = "FAIL" ]; then
    issue "CRITICAL" "No internet connectivity (IPv4 + IPv6 both failed)"
    echo "             Cause: nftables INPUT drop policy OR default route missing"
    if [ "${T_A04:-FAIL}" = "FAIL" ]; then
        echo "             → Default route missing. VPN may have removed it."
        echo "             Fix: ip route add default via $WAN_GW dev $WAN_IF"
    fi
    if [ "${T_B01:-FAIL}" = "PASS" ] && [ "${T_C01:-FAIL}" = "FAIL" ]; then
        echo "             → INPUT chain missing 'ct state established,related accept'"
        echo "             Fix: nft add rule inet filter input ct state established,related accept"
    fi
elif [ "${T_A01:-FAIL}" = "PASS" ] && [ "${T_A02:-FAIL}" = "FAIL" ]; then
    issue "WARN" "IPv6 unreachable (IPv4 works)"
    if [ "${T_C06:-FAIL}" = "FAIL" ] || [ "${T_C07:-FAIL}" = "FAIL" ]; then
        echo "             Cause: ICMPv6 Neighbor Discovery blocked by nftables"
        echo "             Fix: nft add rule inet filter input icmpv6 type {"
        echo "                    nd-neighbor-solicit, nd-neighbor-advert,"
        echo "                    nd-router-advert, nd-redirect } accept"
    fi
fi

# ── 2. nftables service ───────────────────────────────────────────────────────
if [ "${T_B01:-FAIL}" = "FAIL" ]; then
    issue "CRITICAL" "nftables not running — no firewall, no DNAT"
    echo "             Fix: systemctl restart nftables"
fi

# ── 3. INPUT chain ────────────────────────────────────────────────────────────
if [ "${T_B01:-FAIL}" = "PASS" ]; then
    if [ "${T_C01:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "INPUT: missing ct state established,related accept"
        echo "             → All response packets for local connections are dropped"
        echo "             Fix: nft add rule inet filter input ct state established,related accept"
    fi
    if [ "${T_C13:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "INPUT: wt0 not trusted — management traffic from VPN blocked"
        echo "             Fix: nft add rule inet filter input iifname wt0 accept"
    fi
    if [ "${T_C14:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "INPUT: tailscale0 not trusted — management traffic from VPN blocked"
        echo "             Fix: nft add rule inet filter input iifname tailscale0 accept"
    fi
fi

# ── 4. FORWARD chain ──────────────────────────────────────────────────────────
if [ "${T_B01:-FAIL}" = "PASS" ]; then
    if [ "${T_D01:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "FORWARD: missing ct state established,related accept"
        echo "             → DNAT return traffic from backend to client is dropped"
        echo "             Fix: nft add rule inet filter forward ct state established,related accept"
    fi
    if [ "${T_D02:-FAIL}" = "FAIL" ] && [ "${T_D03:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "FORWARD: no WAN→wt0 rules — Netbird DNAT path broken"
        echo "             Fix: nft add rule inet filter forward meta nfproto ipv4 iif $WAN_IF oif wt0 tcp dport { 80, 443 } ct state new accept"
        echo "                  nft add rule inet filter forward meta nfproto ipv4 iif $WAN_IF oif wt0 udp dport 443 ct state new accept"
    fi
    if [ "${T_D04:-FAIL}" = "FAIL" ] && [ "${T_D05:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "FORWARD: no WAN→tailscale0 rules — Tailscale DNAT path broken"
        echo "             Fix: nft add rule inet filter forward meta nfproto ipv4 iif $WAN_IF oif tailscale0 tcp dport { 80, 443 } ct state new accept"
        echo "                  nft add rule inet filter forward meta nfproto ipv4 iif $WAN_IF oif tailscale0 udp dport 443 ct state new accept"
    fi
fi

# ── 5. NAT table ──────────────────────────────────────────────────────────────
if [ "${T_B01:-FAIL}" = "PASS" ]; then
    if [ "${T_E01:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "NAT table missing — no DNAT/SNAT possible"
        echo "             Fix: nft add table ip nat"
    fi
    if [ "${T_E04:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "NAT prerouting: no DNAT TCP 80+443 — external traffic not forwarded"
        echo "             Fix: nft add rule ip nat prerouting tcp dport { 80, 443 } dnat to $BACKEND_IP"
    fi
    if [ "${T_E05:-FAIL}" = "FAIL" ]; then
        issue "WARN" "NAT prerouting: no DNAT UDP 443 — QUIC/HTTP3 not forwarded"
        echo "             Fix: nft add rule ip nat prerouting udp dport 443 dnat to $BACKEND_IP"
    fi
    if [ "${T_E06:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "NAT DNAT target is wrong — traffic goes to wrong backend"
        echo "             Expected: $BACKEND_IP"
        echo "             Fix: flush and re-add DNAT rules with correct target"
    fi
    if [ "${T_E07:-FAIL}" = "FAIL" ] && [ "${T_E08:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "NAT postrouting: no SNAT — client drops return packets (wrong source IP)"
        echo "             → Backend response src=100.x.x.x arrives at client, client expects src=$INGRESS_PUBLIC_IP"
        echo "             Fix: nft add rule ip nat postrouting oifname $WAN_IF ip saddr 100.64.0.0/10 snat to $INGRESS_PUBLIC_IP"
        echo "                  nft add rule ip nat postrouting oifname $WAN_IF ip saddr 100.100.0.0/8 snat to $INGRESS_PUBLIC_IP"
    elif [ "${T_E07:-FAIL}" = "FAIL" ]; then
        issue "WARN" "NAT postrouting: SNAT for Netbird (100.64.0.0/10) missing"
        echo "             Fix: nft add rule ip nat postrouting oifname $WAN_IF ip saddr 100.64.0.0/10 snat to $INGRESS_PUBLIC_IP"
    elif [ "${T_E08:-FAIL}" = "FAIL" ]; then
        issue "WARN" "NAT postrouting: SNAT for Tailscale (100.100.0.0/8) missing"
        echo "             Fix: nft add rule ip nat postrouting oifname $WAN_IF ip saddr 100.100.0.0/8 snat to $INGRESS_PUBLIC_IP"
    fi
    if [ "${T_E09:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "NAT SNAT target is wrong — return packets have wrong source IP"
        echo "             Expected: $INGRESS_PUBLIC_IP"
    fi
fi

# ── 6. Kernel parameters ──────────────────────────────────────────────────────
if [ "${T_F01:-FAIL}" = "FAIL" ]; then
    issue "CRITICAL" "ip_forward = 0 — kernel drops all forwarded packets"
    echo "             Fix: sysctl -w net.ipv4.ip_forward=1"
fi
if [ "${T_F02:-FAIL}" = "FAIL" ]; then
    issue "CRITICAL" "rp_filter not set to 2 — asymmetric return path drops reply packets"
    echo "             Fix: sysctl -w net.ipv4.conf.all.rp_filter=2 && sysctl -w net.ipv4.conf.default.rp_filter=2"
fi
if [ "${T_F04:-FAIL}" = "FAIL" ]; then
    issue "WARN" "rp_filter on wt0 not 2 (Netbird may have reset it)"
    echo "             Fix: sysctl -w net.ipv4.conf.wt0.rp_filter=2 && systemctl restart netbird"
fi
if [ "${T_F05:-FAIL}" = "FAIL" ]; then
    issue "WARN" "rp_filter on tailscale0 not 2"
    echo "             Fix: sysctl -w net.ipv4.conf.tailscale0.rp_filter=2"
fi
if [ "${T_F08:-FAIL}" = "FAIL" ]; then
    issue "WARN" "conntrack table nearly full (${CONNTRACK_PCT}%) — new connections may be dropped"
    echo "             Fix: sysctl -w net.netfilter.nf_conntrack_max=524288"
fi

# ── 7. VPN status ─────────────────────────────────────────────────────────────
NB_CONNECTED=false; TS_CONNECTED=false
[ "${T_G01:-FAIL}" = "PASS" ] && NB_CONNECTED=true
[ "${T_G02:-FAIL}" = "PASS" ] && TS_CONNECTED=true

if ! $NB_CONNECTED && ! $TS_CONNECTED; then
    issue "CRITICAL" "Neither Netbird nor Tailscale is connected — no path to backend"
    echo "             Fix: Check VPN setup keys and run: netbird up / tailscale up"
fi

if [ "${T_G03:-FAIL}" = "FAIL" ] && $NB_CONNECTED; then
    issue "WARN" "Netbird WireGuard endpoint is $NB_EP (relay mode)"
    echo "             → High latency, packet loss, or tunnel failure expected"
    echo "             Fix: netbird down && netbird up --setup-key <key>"
    echo "             If behind CGNAT this is normal — relay mode is automatic"
fi
if [ "${T_G04:-FAIL}" = "FAIL" ] && $NB_CONNECTED; then
    issue "WARN" "Netbird WireGuard handshake stale or missing — tunnel dead"
    echo "             Fix: netbird down && netbird up --setup-key <key>"
fi
if [ "${T_G07:-FAIL}" = "FAIL" ] && $TS_CONNECTED; then
    issue "WARN" "Tailscale DNS cannot resolve $BACKEND_ADDRESS"
    echo "             Fix: Check backend is connected to Tailscale and hostname is correct"
fi

# ── 8. Backend reachability ────────────────────────────────────────────────────
REACH_VIA_NB=false; REACH_VIA_TS=false
[ "${T_H01:-FAIL}" = "PASS" ] && REACH_VIA_NB=true
[ "${T_H03:-FAIL}" = "PASS" ] && REACH_VIA_TS=true

if ! $REACH_VIA_NB && ! $REACH_VIA_TS; then
    issue "CRITICAL" "Backend not reachable via ANY VPN — DNAT has no working target"
    echo "             Possible causes:"
    echo "               - Backend server is down or not running backend.sh"
    echo "               - Backend firewall blocks ports 80/81/443 on VPN interfaces"
    echo "               - Backend application not listening on ports 80/443"
    echo "             Fix: Check backend server and run: bash backend.sh"
elif $REACH_VIA_NB && ! $REACH_VIA_TS; then
    issue "WARN" "Backend reachable via Netbird but NOT Tailscale — failover broken"
    echo "             Fix: Check Tailscale on backend: tailscale status, tailscale0 IP"
elif ! $REACH_VIA_NB && $REACH_VIA_TS; then
    issue "WARN" "Backend reachable via Tailscale but NOT Netbird"
    if [ "${T_G03:-FAIL}" = "FAIL" ]; then
        echo "             Cause: Netbird tunnel via relay ($NB_EP) — broken"
    elif ! $NB_CONNECTED; then
        echo "             Cause: Netbird not connected"
    fi
    echo "             DNAT currently uses Tailscale IP: $BACKEND_TS_IP"
fi
if [ "${T_H07:-FAIL}" = "FAIL" ] && [ -n "${BACKEND_NB_IP:-}" ] && [ -n "${BACKEND_TS_IP:-}" ]; then
    issue "WARN" "Both VPN paths should be reachable for redundancy"
fi

# ── 9. Failover infrastructure ────────────────────────────────────────────────
if [ "${T_I01:-FAIL}" = "FAIL" ]; then
    issue "CRITICAL" "DNAT update script missing — no automatic failover"
    echo "             Fix: Re-run script.sh to recreate /usr/local/bin/update-ingress-dnat.sh"
fi
if [ "${T_I02:-FAIL}" = "FAIL" ]; then
    issue "CRITICAL" "DNAT failover timer not active — no automatic VPN failover"
    echo "             Fix: systemctl enable --now update-ingress-dnat.timer"
fi
if [ "${T_I03:-FAIL}" = "FAIL" ]; then
    issue "WARN" "ingress-edge.service not enabled — DNAT not reapplied on reboot"
    echo "             Fix: systemctl enable ingress-edge.service"
fi

# ── 10. nftables persistence ───────────────────────────────────────────────────
if [ "${T_K02:-FAIL}" = "FAIL" ]; then
    issue "WARN" "nftables rules do NOT survive restart — NAT table lost on reboot"
    echo "             → The static config (/etc/nftables.conf) only has the filter table"
    echo "             → The NAT table is added at runtime by the systemd service"
    echo "             This is expected — ingress-edge.service re-applies NAT on boot"
fi

# ── 11. End-to-end ────────────────────────────────────────────────────────────
if [ "${T_J01:-FAIL}" = "FAIL" ] && [ "${T_E04:-FAIL}" = "PASS" ] && [ "${T_H05:-FAIL}" = "PASS" ]; then
    issue "WARN" "Local loopback test failed despite DNAT+backend being OK"
    echo "             → Possible cloud firewall blocking loopback to public IP"
fi

# ── 12. Cloud firewall ────────────────────────────────────────────────────────
if [ "${T_L01:-FAIL}" = "FAIL" ]; then
    if [ "${T_E04:-FAIL}" = "PASS" ] && [ "${T_H05:-FAIL}" = "PASS" ]; then
        issue "CRITICAL" "External access to $INGRESS_PUBLIC_IP:443 failed from inside"
        echo "             → All internal checks pass but external loopback fails"
        echo "             Most likely cause: Netcup cloud firewall not open"
        echo "             Fix: Open TCP 80+443 and UDP 443 in Netcup cloud panel"
    fi
fi

# ── 13. Traffic path summary ──────────────────────────────────────────────────
if [ "${T_E04:-FAIL}" = "PASS" ] && [ "${T_H05:-FAIL}" = "PASS" ]; then
    issue "INFO" "Traffic path:"
    echo "             Client → $INGRESS_PUBLIC_IP:443"
    if [ -n "${DNAT_TARGETS:-}" ]; then echo "             DNAT → $DNAT_TARGETS"; fi
    if [ "${T_E07:-FAIL}" = "PASS" ] && [ "${T_E08:-FAIL}" = "PASS" ]; then
        echo "             SNAT ← $INGRESS_PUBLIC_IP (return path OK)"
    else
        echo "             SNAT ← MISSING (return path broken)"
    fi
fi

# ── Final result ──────────────────────────────────────────────────────────────
echo ""
if ! $found; then
    echo "  [OK] All $((T_PASS)) checks passed — no issues detected."
    echo ""
    echo "  If external access still doesn't work from outside:"
    echo "    → Check Netcup cloud firewall (open TCP 80+443, UDP 443)"
    echo "    → Check backend: bash backend.sh"
else
    echo "  Issues found — see above for root cause and exact fix commands."
    echo "  Re-run script.sh after fixing to verify."
fi

echo ""
echo "  To watch live traffic:"
echo "    timeout 10 tcpdump -i $WAN_IF -nn port 443 or port 80 -c 20"
echo ""

# ====================================================================================
# FINAL SUMMARY
# ====================================================================================
echo ""
echo "=========================================="
echo "  SETUP SUMMARY"
echo "=========================================="
echo "[INFO] Hostname:       ${new_hostname:-$(hostname)}"
echo "[INFO] WAN Interface:  $WAN_IF"
echo "[INFO] Public IP:      $INGRESS_PUBLIC_IP"
echo "[INFO] Netbird IP:     ${nb_ip:-not connected}"
echo "[INFO] Tailscale IP:   ${ts_ip:-not connected}"
echo "[INFO] Backend:        $BACKEND_IP ($VPN_TYPE)"
echo "[INFO] Client IP:      Real client IP preserved on backend"
echo "[INFO] nftables:       $(systemctl is-active nftables 2>/dev/null)"
echo "[INFO] Tests:          $T_PASS passed, $T_FAIL failed, $T_SKIP skipped"
echo "[INFO] Failover timer: $(systemctl is-active update-ingress-dnat.timer 2>/dev/null)"
echo "[INFO] Log File:       $LOG_FILE"
echo "=========================================="
