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
BACKEND_ADDRESS="backend.ma.internal"
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

# Netbird DNS: try up to 10 times because the DNS resolver may not be ready yet
echo "[*] Resolving via Netbird DNS: $BACKEND_ADDRESS..."
for i in $(seq 1 10); do
    BACKEND_NB_IP=$(getent hosts "$BACKEND_ADDRESS" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$BACKEND_NB_IP" ]; then
        echo "[OK] Netbird IP: $BACKEND_NB_IP"
        break
    fi
    echo "[INFO] Waiting for Netbird DNS... (attempt $i/10)"
    sleep 2
done

# Tailscale magic DNS: search tailscale status output for a device named "backend"
echo "[*] Resolving via Tailscale magic DNS..."
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
# Enables IP forwarding (required for DNAT), sets rp_filter to loose mode (2)
# so that return traffic from the VPN arrives on a different interface than the
# WAN, and tunes conntrack for higher connection capacity. A backup default route
# via the WAN with a high metric prevents the VPN from hijacking the default route.
# All settings are persisted to /etc/sysctl.d/99-ingress.conf.
# ====================================================================================
print_section "8" "KERNEL PARAMETERS"

echo "[*] Enabling IPv4 packet forwarding..."
sysctl -w net.ipv4.ip_forward=1
if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    handle_error 1 "IPv4 forwarding verification failed" "CRITICAL"
fi
log "OK" "IPv4 forwarding enabled"

# rp_filter=2 (loose mode) allows the source address of return packets to arrive
# on an interface different from the one they would go out on — required for VPN
# return traffic that reaches the backend and comes back via the WAN.
echo "[*] Setting rp_filter to loose mode (2)..."
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.default.rp_filter=2
if [ "$(sysctl -n net.ipv4.conf.all.rp_filter)" != "2" ]; then
    handle_error 1 "rp_filter verification failed" "CRITICAL"
fi
log "OK" "rp_filter=2 (loose mode)"

echo "[*] Tuning conntrack..."
modprobe nf_conntrack 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_max=262144 2>/dev/null || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600 2>/dev/null || true

echo "[*] Ensuring backup default route via WAN interface..."
WAN_GW=$(ip route show default | awk '{print $3}' | head -1)
if [ -n "$WAN_GW" ]; then
    # Add backup default route with high metric so VPN doesn't break internet
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
# Two parts:
#   A) A Python script generates /etc/nftables.conf — the static filter rules
#      (input chain, forward chain, anti-spoofing, etc.).
#   B) Direct nft commands add the NAT table (DNAT + SNAT return path) at
#      runtime so it can be updated later by the failover mechanism.
#
# After applying the rules, a DNAT update script (/usr/local/bin/update-ingress-dnat.sh)
# is installed along with a systemd timer that runs it every 60 seconds. This
# provides automatic VPN failover: if Netbird goes down, DNAT is switched to
# the Tailscale IP (or vice versa).
# ====================================================================================
print_section "9" "NFTABLES CONFIGURATION"

echo "[*] Generating filter rules via Python..."
log "INFO" "Creating /root/nft_gen.py"

cat /dev/null > /root/nft_gen.py
echo '#!/usr/bin/env python3' >> /root/nft_gen.py
echo 'import os, sys' >> /root/nft_gen.py
echo '' >> /root/nft_gen.py
echo 'WAN_IF = os.environ.get("WAN_IF", "").strip()' >> /root/nft_gen.py
echo 'INGRESS_PUBLIC_IP = os.environ.get("INGRESS_PUBLIC_IP", "").strip()' >> /root/nft_gen.py
echo '' >> /root/nft_gen.py
echo 'if not WAN_IF or not INGRESS_PUBLIC_IP:' >> /root/nft_gen.py
echo '    print("[ERROR] Missing WAN_IF or INGRESS_PUBLIC_IP")' >> /root/nft_gen.py
echo '    sys.exit(1)' >> /root/nft_gen.py
echo '' >> /root/nft_gen.py
echo 'lines = []' >> /root/nft_gen.py
echo 'lines.append("#!/usr/sbin/nft -f")' >> /root/nft_gen.py
echo 'lines.append("")' >> /root/nft_gen.py
echo 'lines.append("flush ruleset")' >> /root/nft_gen.py
echo 'lines.append("")' >> /root/nft_gen.py
echo '' >> /root/nft_gen.py
echo '# ---- FILTER TABLE ----' >> /root/nft_gen.py
echo 'lines.append("table inet filter {")' >> /root/nft_gen.py
echo 'lines.append("")' >> /root/nft_gen.py
echo 'lines.append("    chain input {")' >> /root/nft_gen.py
echo 'lines.append("        type filter hook input priority filter; policy drop;")' >> /root/nft_gen.py
echo 'lines.append("        ct state established,related accept")' >> /root/nft_gen.py
echo 'lines.append("        iif lo accept")' >> /root/nft_gen.py
echo 'lines.append("        # ICMP (for ping, path-mtu discovery, traceroute)")' >> /root/nft_gen.py
echo 'lines.append("        icmp type { echo-request, echo-reply, destination-unreachable, time-exceeded } accept")' >> /root/nft_gen.py
echo 'lines.append("        icmpv6 type { echo-request, echo-reply, destination-unreachable, time-exceeded, packet-too-big, parameter-problem } accept")' >> /root/nft_gen.py
echo 'lines.append("        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert, nd-redirect } accept")' >> /root/nft_gen.py
echo 'lines.append("        # From outside: only HTTP/HTTPS/QUIC")' >> /root/nft_gen.py
echo 'lines.append(f"        iifname {WAN_IF} tcp dport {{ 80, 443 }} ct state new accept")' >> /root/nft_gen.py
echo 'lines.append(f"        iifname {WAN_IF} udp dport 443 ct state new accept")' >> /root/nft_gen.py
echo 'lines.append("        # VPN-Interfaces: alles erlauben")' >> /root/nft_gen.py
echo 'lines.append("        iifname wt0 accept")' >> /root/nft_gen.py
echo 'lines.append("        iifname tailscale0 accept")' >> /root/nft_gen.py
echo 'lines.append("        # Spoofing-Schutz: VPN-IPs nur auf VPN-Interfaces")' >> /root/nft_gen.py
echo 'lines.append("        ip saddr 100.64.0.0/10 iifname != wt0 drop")' >> /root/nft_gen.py
echo 'lines.append("        ip saddr 100.100.0.0/8 iifname != tailscale0 drop")' >> /root/nft_gen.py
echo 'lines.append("    }")' >> /root/nft_gen.py
echo 'lines.append("")' >> /root/nft_gen.py
echo 'lines.append("    chain forward {")' >> /root/nft_gen.py
echo 'lines.append("        type filter hook forward priority filter; policy drop;")' >> /root/nft_gen.py
echo 'lines.append("        ct state established,related accept")' >> /root/nft_gen.py
echo 'lines.append(f"        iif {WAN_IF} oif wt0 tcp dport {{ 80, 443 }} ct state new accept")' >> /root/nft_gen.py
echo 'lines.append(f"        iif {WAN_IF} oif wt0 udp dport 443 ct state new accept")' >> /root/nft_gen.py
echo 'lines.append(f"        iif {WAN_IF} oif tailscale0 tcp dport {{ 80, 443 }} ct state new accept")' >> /root/nft_gen.py
echo 'lines.append(f"        iif {WAN_IF} oif tailscale0 udp dport 443 ct state new accept")' >> /root/nft_gen.py
echo 'lines.append("    }")' >> /root/nft_gen.py
echo 'lines.append("}")' >> /root/nft_gen.py
echo 'lines.append("")' >> /root/nft_gen.py
echo '# ---- NAT TABLE (static part: SNAT return path, DNAT updated at runtime) ----' >> /root/nft_gen.py
echo 'lines.append("table ip nat {")' >> /root/nft_gen.py
echo 'lines.append("    chain postrouting {")' >> /root/nft_gen.py
echo 'lines.append("        type nat hook postrouting priority srcnat; policy accept;")' >> /root/nft_gen.py
echo 'lines.append(f"        oifname {WAN_IF} ip saddr 100.64.0.0/10 snat to {INGRESS_PUBLIC_IP}")' >> /root/nft_gen.py
echo 'lines.append(f"        oifname {WAN_IF} ip saddr 100.100.0.0/8 snat to {INGRESS_PUBLIC_IP}")' >> /root/nft_gen.py
echo 'lines.append("    }")' >> /root/nft_gen.py
echo 'lines.append("}")' >> /root/nft_gen.py

echo '' >> /root/nft_gen.py
echo 'with open("/etc/nftables.conf", "w") as f:' >> /root/nft_gen.py
echo '    f.write("\n".join(lines) + "\n")' >> /root/nft_gen.py
echo '' >> /root/nft_gen.py
echo 'print(f"[OK] nftables.conf generated: {len(lines)} lines")' >> /root/nft_gen.py

log "OK" "Python generator written"

echo "[*] Running Python generator..."
export WAN_IF INGRESS_PUBLIC_IP
python3 /root/nft_gen.py || handle_error 1 "nftables generation failed" "CRITICAL"
rm -f /root/nft_gen.py

echo "[*] Validating nftables syntax..."
nft -c -f /etc/nftables.conf || handle_error 1 "nftables syntax invalid" "CRITICAL"
log "OK" "Syntax validated"

echo "[*] Activating nftables firewall..."
systemctl restart nftables
systemctl is-active --quiet nftables || handle_error 1 "nftables not running" "CRITICAL"
log "OK" "nftables firewall active"

# ---- NAT Table (added via direct nft commands for dynamic updates) ----
# The NAT table is managed separately so the DNAT rules can be swapped at
# runtime by the failover script without touching the filter table.
echo "[*] Setting up NAT table with current backend IP..."
nft add table ip nat 2>/dev/null || true
nft add chain ip nat prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
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
# Updates the nftables DNAT target based on available VPN connectivity.
# Called by systemd timer every 60 seconds to handle VPN failover.
#
# Logic: discover both IPs, test reachability, use the working one.
# ====================================================================================

BACKEND_ADDRESS="backend.ma.internal"
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

# 1) Discover Netbird IP
if ip addr show wt0 2>/dev/null | grep -q "inet "; then
    BACKEND_NB_IP=$(getent hosts "$BACKEND_ADDRESS" 2>/dev/null | awk '{print $1}' | head -1)
fi

# 2) Discover Tailscale IP — search for "backend" in magic DNS
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
nft add chain ip nat prerouting '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true
nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
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
# This timer runs the DNAT update script every 60 seconds (starting 30s after boot).
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

# ====================================================================================
# STEP 11: VERIFICATION + SUMMARY
# Runs basic checks: service status, kernel parameters, internet connectivity,
# DNAT rule count, failover timer, and prints a summary table.
# ====================================================================================
print_section "11" "VERIFICATION + SUMMARY"

all_ok=true

echo "[*] Checking services..."
for service in nftables netbird tailscaled; do
    if systemctl is-active --quiet "$service"; then
        echo "[OK] $service: active"
    else
        echo "[WARN] $service: not active"
    fi
done

echo "[*] Checking system parameters..."
if [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]; then
    echo "[OK] IP Forwarding: enabled"
else
    echo "[ERROR] IP Forwarding: not enabled"
    all_ok=false
fi

if [ "$(sysctl -n net.ipv4.conf.all.rp_filter)" = "2" ]; then
    echo "[OK] rp_filter: loose mode (2)"
else
    echo "[ERROR] rp_filter: not set to 2"
    all_ok=false
fi

echo "[*] Testing internet connectivity..."
if ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
    echo "[OK] Internet: reachable"
else
    echo "[WARN] Internet: not reachable"
fi

echo "[*] Checking nftables DNAT rules..."
nat_count=$(nft list table ip nat 2>/dev/null | grep -c "dnat to" || true)
if [ "$nat_count" -gt 0 ]; then
    echo "[OK] DNAT rules: $nat_count (target: $BACKEND_IP)"
else
    echo "[ERROR] No DNAT rules found!"
fi

echo "[*] Checking DNAT failover timer..."
if systemctl is-active --quiet update-ingress-dnat.timer; then
    echo "[OK] Failover timer: active (interval: 60s)"
else
    echo "[WARN] Failover timer: not active"
fi

# ====================================================================================
# STEP 12: COMPREHENSIVE DIAGNOSTICS
# ====================================================================================
print_section "12" "COMPREHENSIVE DIAGNOSTICS"

echo ""
echo "  Systematic checks — results feed into the diagnosis engine below."
echo ""

# -- test runner --
check() {
    local id=$1; local desc=$2
    shift 2
    if eval "$@" >/dev/null 2>&1; then
        echo "  [PASS] $desc"
        eval "T_${id}=PASS"
    else
        echo "  [FAIL] $desc"
        eval "T_${id}=FAIL"
    fi
}

# --- 1/5: NETWORK BASICS ---
echo "--- 1/5: Network Basics ---"
check NET4  "Internet reachable (IPv4)"                          "ping -c 1 -W 3 1.1.1.1"
check NET6  "Internet reachable (IPv6)"                          "ping -c 1 -W 3 2606:4700:4700::1111"
check DNS   "DNS resolution works"                               "getent hosts google.com > /dev/null"
check DEFR "Default route present"                              "ip route show default | grep -q '^default'"
WAN_GW=$(ip route show default | awk '{print $3}' | head -1)
check BAKR "Backup default via WAN (metric 1000)"               "ip route show default | grep -q 'metric 1000'"

# --- 2/5: FIREWALL ---
echo ""
echo "--- 2/5: Firewall (nftables) ---"
check NFT  "nftables service is running"                        "systemctl is-active --quiet nftables"
if [ "${T_NFT:-FAIL}" = "PASS" ]; then
    check INCT "INPUT: ct state established,related accept"     "nft list chain inet filter input 2>/dev/null | grep -qF 'ct state established,related accept'"
    check IN6N "INPUT: ICMPv6 Neighbor Discovery allowed"        "nft list chain inet filter input 2>/dev/null | grep -q 'nd-neighbor'"
    check INWAN "INPUT: WAN ports 80+443 TCP, 443 UDP open"     "nft list chain inet filter input 2>/dev/null | grep -qF 'dport { 80, 443 }'"
    check FWCT "FORWARD: ct state established,related accept"    "nft list chain inet filter forward 2>/dev/null | grep -qF 'ct state established,related accept'"
    check FWWAN "FORWARD: WAN→VPN rules for 80+443 exist"       "nft list chain inet filter forward 2>/dev/null | grep -q 'oif wt0'"
    check DNAT "NAT: prerouting DNAT rules present"              "nft list chain ip nat prerouting 2>/dev/null | grep -q 'dnat to'"
    check SNAT "NAT: postrouting SNAT (VPN→WAN) present"         "nft list chain ip nat postrouting 2>/dev/null | grep -q 'snat to'"
    DNAT_TARGETS=$(nft list chain ip nat prerouting 2>/dev/null | grep 'dnat to' | sed 's/.*dnat to //' | sort -u | tr '\n' ' ')
fi

# --- 3/5: VPN ---
echo ""
echo "--- 3/5: VPN Connectivity ---"
check NBIF "Netbird interface (wt0) has IP"                     "ip addr show wt0 2>/dev/null | grep -q 'inet '"
if [ "${T_NBIF:-FAIL}" = "PASS" ]; then
    NB_EP=$(wg show wt0 endpoints 2>/dev/null | head -1 | awk '{print $2}')
    check NBEP "Netbird endpoint not 127.0.0.1"                "! echo '$NB_EP' | grep -qE '^(127\.0\.0\.1|0\.0\.0\.0|::1)'"
    NB_HS=$(wg show wt0 latest-handshakes 2>/dev/null | head -1 | awk '{print $2}')
    check NBHS "Netbird WireGuard handshake exists"             '[ -n "$NB_HS" ] && [ "$NB_HS" != "0" ]'
fi
check TSIF "Tailscale interface (tailscale0) has IP"            "ip addr show tailscale0 2>/dev/null | grep -q 'inet '"

# --- 4/5: SYSTEM ---
echo ""
echo "--- 4/5: System Configuration ---"
check IPFW "ip_forward = 1"                                     '[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]'
check RPF  "rp_filter all = 2"                                  '[ "$(sysctl -n net.ipv4.conf.all.rp_filter)" = "2" ]'
if [ "${T_NBIF:-FAIL}" = "PASS" ]; then
    check RPWT "rp_filter wt0 = 2"                              '[ "$(sysctl -n net.ipv4.conf.wt0.rp_filter 2>/dev/null)" = "2" ]'
fi
if [ "${T_TSIF:-FAIL}" = "PASS" ]; then
    check RPTS "rp_filter tailscale0 = 2"                       '[ "$(sysctl -n net.ipv4.conf.tailscale0.rp_filter 2>/dev/null)" = "2" ]'
fi

# --- 5/5: BACKEND ---
echo ""
echo "--- 5/5: Backend Reachability ---"
if [ -n "$BACKEND_NB_IP" ]; then
    check BNB "Backend reachable via Netbird ($BACKEND_NB_IP:81)" "curl -k -s --connect-timeout 3 --max-time 5 'https://$BACKEND_NB_IP:81' > /dev/null 2>&1"
fi
if [ -n "$BACKEND_TS_IP" ]; then
    check BTS "Backend reachable via Tailscale ($BACKEND_TS_IP:81)" "curl -k -s --connect-timeout 3 --max-time 5 'https://$BACKEND_TS_IP:81' > /dev/null 2>&1"
fi
check BDNAT "Active DNAT target reachable ($BACKEND_IP:81)"      "curl -k -s --connect-timeout 3 --max-time 5 'https://$BACKEND_IP:81' > /dev/null 2>&1"

# ====================================================================================
# DIAGNOSIS ENGINE
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
if [ "${T_NET4:-FAIL}" = "FAIL" ] && [ "${T_NET6:-FAIL}" = "FAIL" ]; then
    issue "CRITICAL" "No internet connectivity at all (IPv4 + IPv6 failed)"
    echo "             Cause: nftables policy drop on INPUT chain OR default route missing"
    if [ "${T_DEFR:-FAIL}" = "FAIL" ]; then
        echo "             → Default route is missing. VPN may have removed it."
        echo "             Fix: ip route add default via $WAN_GW dev $WAN_IF"
    fi
    if [ "${T_NFT:-FAIL}" = "PASS" ] && [ "${T_INCT:-FAIL}" = "FAIL" ]; then
        echo "             → INPUT chain has policy drop but no 'ct state established,related accept'"
        echo "             Fix: nft add rule inet filter input ct state established,related accept"
    fi
elif [ "${T_NET4:-FAIL}" = "PASS" ] && [ "${T_NET6:-FAIL}" = "FAIL" ]; then
    issue "WARN" "IPv6 not reachable (IPv4 works)"
    if [ "${T_IN6N:-FAIL}" = "FAIL" ]; then
        echo "             Cause: nftables INPUT policy drop blocks ICMPv6 Neighbor Discovery"
        echo "             Fix:   Add ICMPv6 NDP rules to nftables"
        echo "                    nft add rule inet filter input icmpv6 type {"
        echo "                      nd-neighbor-solicit, nd-neighbor-advert,"
        echo "                      nd-router-advert, nd-redirect } accept"
        echo "             This causes 'No route to host' for all IPv6 hosts"
    fi
fi

# ── 2. Firewall ────────────────────────────────────────────────────────────────
if [ "${T_NFT:-FAIL}" = "FAIL" ]; then
    issue "CRITICAL" "nftables not running — no firewall, no DNAT"
    echo "             Fix: systemctl restart nftables"
fi

if [ "${T_NFT:-FAIL}" = "PASS" ]; then
    if [ "${T_INCT:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "INPUT chain: missing 'ct state established,related accept'"
        echo "             → All incoming response packets for local connections are dropped"
        echo "             Fix: nft add rule inet filter input ct state established,related accept"
    fi
    if [ "${T_FWCT:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "FORWARD chain: missing 'ct state established,related accept'"
        echo "             → DNAT return traffic from backend to client is dropped"
        echo "             Fix: nft add rule inet filter forward ct state established,related accept"
    fi
    if [ "${T_DNAT:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "No DNAT rules — external traffic not forwarded to backend"
        echo "             Fix: nft add rule ip nat prerouting tcp dport { 80, 443 } dnat to $BACKEND_IP"
        echo "                  nft add rule ip nat prerouting udp dport 443 dnat to $BACKEND_IP"
    fi
    if [ "${T_SNAT:-FAIL}" = "FAIL" ]; then
        issue "CRITICAL" "No SNAT on return path — client drops packets (wrong source IP)"
        if [ -n "$WAN_IF" ] && [ -n "$INGRESS_PUBLIC_IP" ]; then
            echo "             → Backend response (src=100.x.x.x) reaches client, but client expects src=$INGRESS_PUBLIC_IP"
            echo "             Fix: nft add rule ip nat postrouting oifname $WAN_IF ip saddr 100.64.0.0/10 snat to $INGRESS_PUBLIC_IP"
            echo "                  nft add rule ip nat postrouting oifname $WAN_IF ip saddr 100.100.0.0/8 snat to $INGRESS_PUBLIC_IP"
        fi
    fi
fi

# ── 3. VPN ────────────────────────────────────────────────────────────────────
NB_CONNECTED=false; TS_CONNECTED=false
[ "${T_NBIF:-FAIL}" = "PASS" ] && NB_CONNECTED=true
[ "${T_TSIF:-FAIL}" = "PASS" ] && TS_CONNECTED=true

if ! $NB_CONNECTED && ! $TS_CONNECTED; then
    issue "CRITICAL" "Neither Netbird nor Tailscale is connected"
    echo "             → No path to backend at all"
    echo "             Fix: Check VPN setup keys and connectivity"
fi

if $NB_CONNECTED; then
    if [ "${T_NBEP:-FAIL}" = "FAIL" ]; then
        issue "WARN" "Netbird WireGuard endpoint is $NB_EP — tunnel via relay"
        echo "             → Netbird is connected but traffic goes through relay (127.0.0.1)"
        echo "             → High latency, packet loss, or complete failure expected"
        echo "             Fix: netbird down && netbird up --setup-key <key>"
        echo "             If behind NAT/CGNAT this is normal — relay mode is automatic"
    fi
    if [ "${T_NBHS:-FAIL}" = "FAIL" ]; then
        issue "WARN" "Netbird WireGuard has no handshake"
        echo "             → Tunnel is dead, no traffic can pass"
        echo "             Fix: netbird down && netbird up --setup-key <key>"
    fi
fi

# ── 4. Backend reachability ────────────────────────────────────────────────────
REACH_VIA_NB=false; REACH_VIA_TS=false
[ "${T_BNB:-FAIL}" = "PASS" ] && REACH_VIA_NB=true
[ "${T_BTS:-FAIL}" = "PASS" ] && REACH_VIA_TS=true

if ! $REACH_VIA_NB && ! $REACH_VIA_TS; then
    issue "CRITICAL" "Backend not reachable via ANY VPN"
    echo "             → DNAT has no working target — external requests will timeout"
    echo "             Possible causes:"
    echo "               - Backend server is down"
    $NB_CONNECTED && echo "               - Backend firewall blocks ports 80/443 on wt0/tailscale0"
    $NB_CONNECTED && echo "               - Backend application not running"
    echo "             Fix: Check backend server and run: bash backend.sh"
elif $REACH_VIA_NB && ! $REACH_VIA_TS; then
    issue "WARN" "Backend reachable via Netbird but NOT via Tailscale"
    echo "             → Tailscale failover path is broken"
    echo "             Fix: Check Tailscale on backend (tailscale status, tailscale0 IP)"
elif ! $REACH_VIA_NB && $REACH_VIA_TS; then
    issue "WARN" "Backend reachable via Tailscale but NOT via Netbird"
    echo "             → Netbird path broken, Tailscale failover active"
    if $NB_CONNECTED && [ "${T_NBEP:-FAIL}" = "FAIL" ]; then
        echo "             Cause: Netbird WireGuard endpoint is $NB_EP — tunnel broken"
        echo "             → DNAT currently uses Tailscale IP: $BACKEND_TS_IP"
    elif ! $NB_CONNECTED; then
        echo "             Cause: Netbird not connected (no IP on wt0)"
    fi
fi

# ── 5. Traffic path summary ──────────────────────────────────────────────────
if [ "${T_DNAT:-FAIL}" = "PASS" ] && [ "${T_BDNAT:-FAIL}" = "PASS" ]; then
    issue "INFO" "Traffic path summary:"
    echo "             Client → $INGRESS_PUBLIC_IP:443"
    if [ -n "$DNAT_TARGETS" ]; then echo "             DNAT → $DNAT_TARGETS"; fi
    if [ "${T_SNAT:-FAIL}" = "PASS" ]; then
        echo "             SNAT ← $INGRESS_PUBLIC_IP (return path fixed)"
    else
        echo "             SNAT ← MISSING (return path broken)"
    fi
    echo ""
    echo "             If external traffic still fails after all checks PASS:"
    echo "             → Check Netcup cloud firewall (must open TCP 80+443, UDP 443)"
    echo "             → Check backend:"
    echo "                 - bash backend.sh (AllowedIPs + policy routing + rp_filter=2)"
    echo "                 - wg show wt0 allowed-ips (must include 0.0.0.0/0)"
    echo "                 - ip route show table 200 (default via ingress VPN IP)"
fi

# ── 6. Final ----
echo ""
if ! $found; then
    echo "  [OK] All checks passed — no issues detected."
    echo ""
    echo "  If external access still doesn't work, verify the Netcup cloud firewall:"
    echo "    curl -kv https://$INGRESS_PUBLIC_IP (from an external machine)"
else
    echo "  Issues were found — see above for root cause and fixes."
fi

# ── 7. Live capture hint ──────────────────────────────────────────────────────
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
echo "[INFO] Hostname:       $new_hostname"
echo "[INFO] WAN Interface:  $WAN_IF"
echo "[INFO] Public IP:      $INGRESS_PUBLIC_IP"
echo "[INFO] Netbird IP:     ${nb_ip:-not connected}"
echo "[INFO] Tailscale IP:   ${ts_ip:-not connected}"
echo "[INFO] Backend:        $BACKEND_IP ($VPN_TYPE)"
echo "[INFO] Client IP:      Real client IP preserved on backend"
echo "[INFO] nftables:       $(systemctl is-active nftables)"
echo "[INFO] DNAT Rules:     $nat_count (dynamic via nftables)"
echo "[INFO] Failover timer: $(systemctl is-active update-ingress-dnat.timer)"
echo "[INFO] Log File:       $LOG_FILE"
echo "=========================================="

if [ "$all_ok" = true ]; then
    echo "[STATUS] ALL CHECKS PASSED"
else
    echo "[STATUS] SOME CHECKS FAILED - check log"
fi
