#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
set -e

# ================== CHECK ROOT ==================
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This script must be run as root" 
   exit 1
fi

# ================== INSTALL DEPENDENCIES ==================
echo "[+] Installing dependencies..."
dnf install -y gcc make wget tar >/dev/null 2>&1

# ================== AUTO DETECT INTERFACE ==================
IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
echo "[+] Network interface: $IFACE"

# ================== RANDOM STRING ==================
random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c5
    echo
}

# ================== GEN IPV6 ==================
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# ================== INSTALL 3PROXY ==================
install_3proxy() {
    echo "[+] Installing 3proxy"
    URL="https://github.com/z3APA3A/3proxy/archive/refs/tags/0.8.13.tar.gz"
    wget -qO- "$URL" | tar -xzf-
    cd 3proxy-0.8.13
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd "$WORKDIR"
}

# ================== GEN 3PROXY CONFIG ==================
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

# ================== EXPORT PROXY LIST ==================
gen_proxy_file_for_user() {
    awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA} > proxy.txt
}

# ================== GEN DATA ==================
gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "user$port/$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

# ================== GEN IPV6 ADD SCRIPT ==================
gen_ifconfig() {
    awk -F "/" '{print "ip -6 addr add " $5 "/64 dev '"$IFACE"'"}' ${WORKDATA}
}

# ================== MAIN ==================
WORKDIR="/home/thanhhuyvn"
WORKDATA="${WORKDIR}/data.txt"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# IPv4
IP4=$(curl -4 -s icanhazip.com)

# IPv6 PREFIX /64
IP6=$(ip -6 addr show dev "$IFACE" scope global | \
      awk '/inet6/ {print $2}' | head -n1 | cut -d/ -f1 | cut -d: -f1-4)

if [[ -z "$IP6" ]]; then
    echo "[ERROR] IPv6 /64 prefix not found on interface $IFACE"
    echo "[INFO] Please enable IPv6 on AWS EC2 instance first"
    exit 1
fi

echo "[+] IPv4: $IP4"
echo "[+] IPv6 prefix: $IP6::/64"

# PORT RANGE
FIRST_PORT=22000
LAST_PORT=22300

install_3proxy

gen_data > "$WORKDATA"
gen_ifconfig > "$WORKDIR/boot_ifconfig.sh"
chmod +x "$WORKDIR/boot_ifconfig.sh"

gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

# ================== CREATE SYSTEMD SERVICE ==================
cat > /etc/systemd/system/3proxy.service <<EOF
[Unit]
Description=3proxy proxy server
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/bash $WORKDIR/boot_ifconfig.sh
ExecStart=/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
Restart=on-failure
LimitNOFILE=10048

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
systemctl daemon-reload
systemctl enable 3proxy
systemctl start 3proxy

# ================== CONFIGURE FIREWALL ==================
if systemctl is-active --quiet firewalld; then
    echo "[+] Configuring firewall..."
    firewall-cmd --permanent --add-port=${FIRST_PORT}-${LAST_PORT}/tcp
    firewall-cmd --reload
fi

gen_proxy_file_for_user

echo ""
echo "========================================="
echo "[+] DONE!"
echo "[+] Proxy list: $WORKDIR/proxy.txt"
echo "[+] Service status: systemctl status 3proxy"
echo "========================================="
