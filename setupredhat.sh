#!/bin/bash
# Full 3proxy IPv6 Proxy Server Installation Script
# For RHEL 10 / AlmaLinux / Rocky Linux on AWS EC2
# Author: Auto-setup script
# Usage: sudo bash install_3proxy_full.sh

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ================== CHECK ROOT ==================
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] This script must be run as root${NC}"
   echo "Please run: sudo bash $0"
   exit 1
fi

clear
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}   3proxy IPv6 Proxy Server Installer${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""

# ================== DETECT USER ==================
REAL_USER=${SUDO_USER:-$USER}
if [[ "$REAL_USER" == "root" ]]; then
    REAL_USER="ec2-user"
fi
echo -e "${GREEN}[+] Running as root, files will be owned by: $REAL_USER${NC}"

# ================== INSTALL DEPENDENCIES ==================
echo ""
echo -e "${YELLOW}[*] Installing dependencies...${NC}"
dnf install -y gcc make wget tar curl net-tools >/dev/null 2>&1
echo -e "${GREEN}[✓] Dependencies installed${NC}"

# ================== AUTO DETECT INTERFACE ==================
IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
if [[ -z "$IFACE" ]]; then
    echo -e "${RED}[ERROR] Cannot detect network interface${NC}"
    exit 1
fi
echo -e "${GREEN}[+] Network interface: $IFACE${NC}"

# ================== GET IPv4 ==================
IP4=$(curl -4 -s --max-time 10 icanhazip.com 2>/dev/null || echo "")
if [[ -z "$IP4" ]]; then
    IP4=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
fi

if [[ -z "$IP4" ]]; then
    echo -e "${RED}[ERROR] Cannot detect IPv4 address${NC}"
    exit 1
fi
echo -e "${GREEN}[+] IPv4: $IP4${NC}"

# ================== GET IPv6 PREFIX ==================
IP6=$(ip -6 addr show dev "$IFACE" scope global 2>/dev/null | \
      awk '/inet6/ {print $2}' | head -n1 | cut -d/ -f1 | cut -d: -f1-4)

if [[ -z "$IP6" ]]; then
    echo ""
    echo -e "${RED}[ERROR] IPv6 /64 prefix not found on interface $IFACE${NC}"
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║          IPv6 NOT CONFIGURED ON AWS EC2                ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "To enable IPv6 on AWS EC2:"
    echo "1. AWS Console → VPC → Your VPC → Actions → Edit CIDRs"
    echo "2. Add IPv6 CIDR block"
    echo "3. Subnet → Actions → Edit IPv6 CIDRs → Add IPv6 CIDR"
    echo "4. EC2 Instance → Actions → Networking → Manage IP Addresses"
    echo "5. Auto-assign IPv6 address"
    echo "6. Security Group → Add Inbound Rule for IPv6 (::/0)"
    echo ""
    echo "After configuring, run this script again."
    exit 1
fi

echo -e "${GREEN}[+] IPv6 prefix: $IP6::/64${NC}"

# ================== CONFIGURATION ==================
FIRST_PORT=22000
LAST_PORT=22700
PROXY_COUNT=$((LAST_PORT - FIRST_PORT + 1))

echo ""
echo -e "${BLUE}Configuration:${NC}"
echo -e "  • Port range: $FIRST_PORT - $LAST_PORT"
echo -e "  • Number of proxies: $PROXY_COUNT"
echo ""

read -p "Press Enter to continue or Ctrl+C to cancel..."

# ================== RANDOM STRING GENERATOR ==================
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c8
    echo
}

# ================== IPv6 GENERATOR ==================
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# ================== INSTALL 3PROXY ==================
install_3proxy() {
    echo ""
    echo -e "${YELLOW}[*] Downloading and compiling 3proxy...${NC}"
    
    WORKDIR="/tmp/3proxy-install"
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.9.4.tar.gz"
    wget -q --show-progress "$URL" -O 3proxy.tar.gz
    tar -xzf 3proxy.tar.gz
    cd 3proxy-0.9.4
    
    echo -e "${YELLOW}[*] Compiling 3proxy (this may take a minute)...${NC}"
    make -f Makefile.Linux >/dev/null 2>&1
    
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    chmod +x /usr/local/etc/3proxy/bin/3proxy
    
    cd /
    rm -rf "$WORKDIR"
    
    echo -e "${GREEN}[✓] 3proxy installed${NC}"
}

# ================== GENERATE 3PROXY CONFIG ==================
gen_3proxy() {
cat <<EOF
daemon
maxconn 4000
nserver 1.1.1.1
nserver 8.8.8.8
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush
auth strong

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "allow " $1 "\nproxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\nflush\n"}' ${WORKDATA})
EOF
}

# ================== GENERATE PROXY LIST ==================
gen_proxy_file_for_user() {
    echo "# 3proxy IPv6 Proxy List" > proxy.txt
    echo "# Format: IP:PORT:USERNAME:PASSWORD" >> proxy.txt
    echo "# Generated: $(date)" >> proxy.txt
    echo "# Total proxies: $PROXY_COUNT" >> proxy.txt
    echo "" >> proxy.txt
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA} >> proxy.txt
}

# ================== GENERATE DATA ==================
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "user$port/$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

# ================== GENERATE IPv6 CONFIGURATION ==================
gen_ifconfig() {
    awk -F "/" '{print "ip -6 addr add " $5 "/64 dev '"$IFACE"'"}' ${WORKDATA}
}

# ================== MAIN INSTALLATION ==================
PROXY_DIR="/home/$REAL_USER/3proxy"
WORKDATA="${PROXY_DIR}/data.txt"

echo ""
echo -e "${YELLOW}[*] Creating working directory: $PROXY_DIR${NC}"
mkdir -p "$PROXY_DIR"
cd "$PROXY_DIR"

# Install 3proxy
install_3proxy

# Generate configuration
echo -e "${YELLOW}[*] Generating proxy configurations...${NC}"
gen_data > "$WORKDATA"
gen_ifconfig > "$PROXY_DIR/boot_ifconfig.sh"
chmod +x "$PROXY_DIR/boot_ifconfig.sh"

gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

echo -e "${GREEN}[✓] Configuration files created${NC}"

# ================== CREATE SYSTEMD SERVICE ==================
echo -e "${YELLOW}[*] Creating systemd service...${NC}"

cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy - Tiny but powerful proxy server
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash $PROXY_DIR/boot_ifconfig.sh
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy >/dev/null 2>&1
echo -e "${GREEN}[✓] Systemd service created${NC}"

# ================== CONFIGURE FIREWALL ==================
echo -e "${YELLOW}[*] Configuring firewall...${NC}"

# Install firewalld if not present
if ! command -v firewall-cmd &> /dev/null; then
    echo -e "${YELLOW}[*] Installing firewalld...${NC}"
    dnf install -y firewalld >/dev/null 2>&1
    systemctl start firewalld
    systemctl enable firewalld >/dev/null 2>&1
fi

# Configure firewall
if systemctl is-active --quiet firewalld; then
    if ! firewall-cmd --list-ports | grep -q "${FIRST_PORT}-${LAST_PORT}/tcp"; then
        firewall-cmd --permanent --add-port=${FIRST_PORT}-${LAST_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "${GREEN}[✓] Firewall configured (ports ${FIRST_PORT}-${LAST_PORT})${NC}"
    else
        echo -e "${GREEN}[✓] Firewall already configured${NC}"
    fi
else
    echo -e "${YELLOW}[!] Firewall not active, using iptables...${NC}"
    iptables -I INPUT -p tcp --dport ${FIRST_PORT}:${LAST_PORT} -j ACCEPT
    echo -e "${GREEN}[✓] Iptables rule added${NC}"
fi

# ================== START SERVICE ==================
echo -e "${YELLOW}[*] Starting 3proxy service...${NC}"
systemctl start 3proxy

sleep 2

if systemctl is-active --quiet 3proxy; then
    echo -e "${GREEN}[✓] 3proxy service started successfully${NC}"
else
    echo -e "${RED}[✗] Failed to start 3proxy service${NC}"
    echo "Check logs: journalctl -u 3proxy -n 50"
    exit 1
fi

# ================== GENERATE PROXY LIST ==================
gen_proxy_file_for_user

# Fix permissions
chown -R $REAL_USER:$REAL_USER "$PROXY_DIR"
chmod 644 "$PROXY_DIR/proxy.txt"

# ================== TEST PROXY ==================
echo ""
echo -e "${YELLOW}[*] Testing first proxy...${NC}"

FIRST_PROXY=$(head -n 5 "$PROXY_DIR/proxy.txt" | tail -n 1)
if [[ -n "$FIRST_PROXY" ]]; then
    PROXY_IP=$(echo "$FIRST_PROXY" | cut -d: -f1)
    PROXY_PORT=$(echo "$FIRST_PROXY" | cut -d: -f2)
    PROXY_USER=$(echo "$FIRST_PROXY" | cut -d: -f3)
    PROXY_PASS=$(echo "$FIRST_PROXY" | cut -d: -f4)
    
    TEST_RESULT=$(curl -x "http://${PROXY_USER}:${PROXY_PASS}@${PROXY_IP}:${PROXY_PORT}" \
                       -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "FAILED")
    
    if [[ "$TEST_RESULT" != "FAILED" ]] && [[ -n "$TEST_RESULT" ]]; then
        echo -e "${GREEN}[✓] Proxy test successful! External IP: $TEST_RESULT${NC}"
    else
        echo -e "${YELLOW}[!] Proxy test failed (may need AWS Security Group configuration)${NC}"
    fi
fi

# ================== FINAL REPORT ==================
echo ""
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}         INSTALLATION COMPLETE!${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
echo -e "${GREEN}✓ Summary:${NC}"
echo "  • IPv4 Address: $IP4"
echo "  • IPv6 Prefix: $IP6::/64"
echo "  • Port Range: $FIRST_PORT - $LAST_PORT"
echo "  • Total Proxies: $PROXY_COUNT"
echo "  • Proxy List: $PROXY_DIR/proxy.txt"
echo ""
echo -e "${GREEN}✓ Service Status:${NC}"
systemctl status 3proxy --no-pager -l | head -n 3
echo ""
echo -e "${YELLOW}📋 Important Commands:${NC}"
echo "  • View proxy list:    cat $PROXY_DIR/proxy.txt"
echo "  • Service status:     systemctl status 3proxy"
echo "  • Restart service:    systemctl restart 3proxy"
echo "  • View logs:          journalctl -u 3proxy -f"
echo "  • Stop service:       systemctl stop 3proxy"
echo ""
echo -e "${YELLOW}⚠️  AWS Security Group Configuration:${NC}"
echo "  Don't forget to open ports in AWS Security Group:"
echo "  • Type: Custom TCP"
echo "  • Port Range: ${FIRST_PORT}-${LAST_PORT}"
echo "  • Source IPv4: 0.0.0.0/0"
echo "  • Source IPv6: ::/0"
echo ""
echo -e "${GREEN}✓ Proxy format:${NC}"
echo "  IP:PORT:USERNAME:PASSWORD"
echo ""
head -n 6 "$PROXY_DIR/proxy.txt" | tail -n 1
echo "  ... (and $((PROXY_COUNT - 1)) more)"
echo ""
echo -e "${BLUE}=========================================${NC}"
echo -e "${GREEN}Installation completed successfully!${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
