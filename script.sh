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

set -eu

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

BACKEND_ADDRESS="reversed-proxy.ma.internal"
BACKUP_ADDRESS="reversed-proxy.ma.internal"    # Alternative DNS if primary fails
CACHE_FILE="/etc/ingress-edge-backend-ip"

echo "[INFO] Backend DNS: $BACKEND_ADDRESS"
log "INFO" "Backend address: $BACKEND_ADDRESS"
echo ""

# ====================================================================================
# STEP 1: SYSTEM VERIFICATION
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
# ====================================================================================
print_section "4" "HOSTNAME CONFIGURATION"

current_hostname=$(hostname)
echo "[INFO] Current hostname: $current_hostname"

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

if ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
    ts_ip=$(ip addr show tailscale0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)
fi

# ---- WireGuard Health Check ----
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
# ====================================================================================
# Resolve the backend address via both VPNs. Netbird DNS is primary.
# Tailscale is the fallback path, used when Netbird is unavailable.
# Both IPs are saved for the automatic failover mechanism.
# ====================================================================================
print_section "6" "BACKEND IP DISCOVERY (DUAL VPN)"

BACKEND_NB_IP=""
BACKEND_TS_IP=""
BACKEND_IP=""
VPN_TYPE=""

# ---- Step A: Discover BOTH IPs (Netbird + Tailscale) ----
echo "[*] Discovering backend IPs on both VPNs..."

# Netbird DNS
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

# Tailscale — search for "backend" in magic DNS name
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
# ====================================================================================
print_section "7" "WAN INTERFACE + PUBLIC IP"

echo "[*] Detecting WAN interface..."
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
# ====================================================================================
print_section "8" "KERNEL PARAMETERS"

echo "[*] Enabling IPv4 packet forwarding..."
sysctl -w net.ipv4.ip_forward=1
if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
    handle_error 1 "IPv4 forwarding verification failed" "CRITICAL"
fi
log "OK" "IPv4 forwarding enabled"

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
# ====================================================================================
# Generates the nftables filter rules via Python (cleaner than shell heredocs).
# The NAT table is set up separately with direct nft commands so it can be
# updated dynamically by the failover mechanism.
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

BACKEND_ADDRESS="reversed-proxy.ma.internal"
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

# ====================================================================================
# STEP 12: AUTOMATIC TEST & DEBUG
# ====================================================================================
print_section "12" "AUTOMATIC TEST & DEBUG"

echo ""
echo "=========================================="
echo "  INTERACTIVE DIAGNOSTICS"
echo "=========================================="
echo ""
echo "Run these tests to verify the setup."
echo ""

# --- TEST 1: Kernel ---
echo "[TEST 1/7] Kernel parameters..."
echo "  ip_forward:     $(sysctl -n net.ipv4.ip_forward)"
echo "  rp_filter all:  $(sysctl -n net.ipv4.conf.all.rp_filter)"
if [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] && \
   [ "$(sysctl -n net.ipv4.conf.all.rp_filter)" = "2" ]; then
    echo "  [OK] Correct"
else
    echo "  [ERROR] Wrong values"
fi
echo "  conntrack max:  $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo N/A)"
ct_used=$(cat /proc/net/nf_conntrack 2>/dev/null | wc -l || echo "0")
echo "  conntrack used: $ct_used"
ct_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "1")
if [ "$ct_max" -gt 0 ]; then
    echo "  conntrack util: $((ct_used * 100 / ct_max))%"
fi

# --- TEST 2: nftables ---
echo ""
echo "[TEST 2/7] nftables..."
if systemctl is-active --quiet nftables; then
    echo "  [OK] Service running"
    dnat_entries=$(nft list table ip nat 2>/dev/null | grep -c "dnat to" || true)
    if [ "$dnat_entries" -gt 0 ]; then
        echo "  [OK] DNAT rules: $dnat_entries"
        nft list table ip nat 2>/dev/null | grep "dnat to" || true
    else
        echo "  [WARN] No DNAT rules"
    fi
else
    echo "  [ERROR] Not running"
fi

# --- TEST 3: VPN Interfaces ---
echo ""
echo "[TEST 3/7] VPN interfaces..."
nb_ok=false; ts_ok=false
if ip addr show wt0 2>/dev/null | grep -q "inet "; then
    echo "  [OK] Netbird (wt0): $(ip addr show wt0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)"
    nb_ok=true
else
    echo "  [ERROR] Netbird not connected"
fi
if ip addr show tailscale0 2>/dev/null | grep -q "inet "; then
    echo "  [OK] Tailscale: $(ip addr show tailscale0 | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1)"
    ts_ok=true
else
    echo "  [ERROR] Tailscale not connected"
fi

# --- TEST 4: Backend ---
echo ""
echo "[TEST 4/7] Backend reachability..."
echo -n "  $BACKEND_IP:81... "
if curl -k -s --connect-timeout 3 --max-time 5 "https://$BACKEND_IP:81" >/dev/null 2>&1; then
    echo "[OK]"
else
    echo "[ERROR] not reachable"
fi

# --- TEST 5: Port Bindings ---
echo ""
echo "[TEST 5/7] Port bindings..."
for port in 80 443; do
    echo -n "  Port $port TCP: "
    if ss -tlnp | grep -q ":${port} "; then echo "[OK] bound"; else echo "[INFO] not bound (OK for DNAT)"; fi
done
echo -n "  Port 443 UDP: "
if ss -ulnp | grep -q ":443 "; then echo "[OK] bound"; else echo "[INFO] not bound (OK for DNAT)"; fi

# --- TEST 6: External ---
echo ""
echo "[TEST 6/7] External access..."
echo "  [INFO] Testing from the server itself won't work for DNAT."
echo "  [INFO] Test from an external machine with:"
echo "    curl -kv https://$INGRESS_PUBLIC_IP"
echo ""
echo "--- CURL FROM SERVER (expected to fail - hairpin NAT) ---"
curl -kv --connect-timeout 5 --max-time 8 "https://$INGRESS_PUBLIC_IP" 2>&1 | head -10 || true
echo "--- END ---"
echo ""
echo "  [INFO] The curl from this server to its own public IP"
echo "  [INFO] does NOT go through DNAT (it's local traffic)."
echo "  [INFO] This test is ONLY valid from an EXTERNAL machine."
echo ""
read -p "Have you tested from an external machine (laptop/phone)? (y/n): " external_tested < /dev/tty
if [ "$external_tested" = "y" ] || [ "$external_tested" = "Y" ]; then
    echo "  [OK] External test done"
else
    echo "  [INFO] External test hint:"
    echo "    curl -kv https://$INGRESS_PUBLIC_IP"
fi

# --- TEST 7: tcpdump ---
echo ""
echo "[TEST 7/7] tcpdump live test..."
echo ""
echo "Open a second terminal and run:"
echo "  tcpdump -i $WAN_IF -nn port 443 or port 80 -c 20"
echo ""
echo "Then send a request from outside:"
echo "  curl -kv https://$INGRESS_PUBLIC_IP"
echo ""
read -p "Ready? (y/n): " ready < /dev/tty
if [ "$ready" = "y" ] || [ "$ready" = "Y" ]; then
    echo "[*] Starting tcpdump (Ctrl+C to stop)..."
    tcpdump -i "$WAN_IF" -nn port 443 or port 80 -c 20 2>/dev/null || true
fi

# --- DIAGNOSIS ---
echo ""
echo "=========================================="
echo "  TROUBLESHOOTING"
echo "=========================================="
echo ""
echo "1. NO EXTERNAL TRAFFIC:"
echo "   - Open Netcup firewall: TCP 80+443, UDP 443"
echo ""
echo "2. BACKEND UNREACHABLE:"
echo "   - curl -k https://$BACKEND_IP:81"
echo "   - Check VPN: ip addr show wt0 / tailscale0"
echo ""
echo "3. WRONG CLIENT IP ON BACKEND:"
echo "   - Backend: AllowedIPs must include 0.0.0.0/0"
echo "   - Backend: policy routing must be active"
echo "   - Backend: rp_filter must be 2"
echo ""
echo "4. 502/BROWSER HANGS (return path broken):"
echo "   - Backend: ip route show table 200"
echo "   - Backend: default route via ingress?"
echo ""
echo "5. QUIC NOT WORKING:"
echo "   - UDP 443 open in cloud firewall?"
echo "   - nftables DNAT includes UDP 443?"
echo ""
echo "6. CHECK COMMANDS:"
echo "   - nft list ruleset"
echo "   - nft list table ip nat"
echo "   - ip route show"
echo "   - cat $LOG_FILE"
echo ""

# ====================================================================================
# FINAL SUMMARY
# ====================================================================================
echo ""
echo "=========================================="
echo "  SETUP COMPLETE"
echo "=========================================="
echo "[INFO] Hostname:       $new_hostname"
echo "[INFO] WAN Interface:  $WAN_IF"
echo "[INFO] Public IP:      $INGRESS_PUBLIC_IP"
echo "[INFO] Netbird:        ${nb_ip:-not connected}"
echo "[INFO] Tailscale:      ${ts_ip:-not connected}"
echo "[INFO] Backend:        $BACKEND_IP ($VPN_TYPE)"
echo "[INFO] Client IP:      Real client IP preserved on backend"
echo "[INFO] nftables:       $(systemctl is-active nftables)"
echo "[INFO] Failover timer: $(systemctl is-active update-ingress-dnat.timer)"
echo "[INFO] Log File:       $LOG_FILE"
echo "=========================================="
echo ""
log "INFO" "Setup completed successfully"
