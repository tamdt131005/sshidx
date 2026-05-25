#!/usr/bin/env bash

# Lightweight Linux server VM for IDX.
# Default: Alpine Linux Virt, a small ISO optimized for virtual machines.

DISK_FILE="${DISK_FILE:-/var/linux_server.qcow2}"
DISK_SIZE="${DISK_SIZE:-12G}"
ISO_FILE="${ISO_FILE:-/var/alpine-virt-3.23.4-x86_64.iso}"
ISO_URL="${ISO_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-virt-3.23.4-x86_64.iso}"
ISO_SHA256="${ISO_SHA256:-f802033362595ad55de7bce00c500c51a756c94e229768afdcf7e68e49994c48}"
REMOTE_DIR="${REMOTE_DIR:-gdrive:IDX_VM_linux_server}"
REMOTE_NAME="${REMOTE_NAME:-linux_server.qcow2}"
REMOTE_PATH="${REMOTE_PATH:-$REMOTE_DIR/$REMOTE_NAME}"
FLAG_FILE="${FLAG_FILE:-$HOME/linux_server.installed.flag}"
RAM="${RAM:-2G}"
CORES="${CORES:-2}"
HOST_SSH_PORT="${HOST_SSH_PORT:-2222}"
HOST_HTTP_PORT="${HOST_HTTP_PORT:-8080}"
HOST_HTTPS_PORT="${HOST_HTTPS_PORT:-8443}"
QEMU_VNC_DISPLAY="${QEMU_VNC_DISPLAY:-0}"
QEMU_VNC_PORT="${QEMU_VNC_PORT:-$((5900 + QEMU_VNC_DISPLAY))}"
NOVNC_LISTEN_HOST="${NOVNC_LISTEN_HOST:-127.0.0.1}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
CF_PUBLIC_HOSTNAME="${CF_PUBLIC_HOSTNAME:-}"
CLOUDFLARED_URL="${CLOUDFLARED_URL:-http://127.0.0.1:${NOVNC_PORT}}"
TS_AUTH_KEY="${TS_AUTH_KEY:-tskey-auth-kF3cSZx6s521CNTRL-LMRQEvqqBoC4mBm7ZR29oCGCyADWck5m}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-idx-linux-server}"
TAILSCALE_UP_FLAGS="${TAILSCALE_UP_FLAGS:---ssh}"
PROVISION_DIR="${PROVISION_DIR:-/tmp/linux-server-provision}"
PROVISION_PORT="${PROVISION_PORT:-18080}"
ENABLE_PROVISION_HTTP="${ENABLE_PROVISION_HTTP:-0}"
GUEST_ROOT_PASS="${GUEST_ROOT_PASS:-root}"
AUTO_PROVISION="${AUTO_PROVISION:-1}"
SERIAL_PORT="${SERIAL_PORT:-4321}"
PROVISIONED_FLAG="${PROVISIONED_FLAG:-$HOME/linux_server.provisioned.flag}"
BOOT_WAIT="${BOOT_WAIT:-90}"

log() {
    printf '%s\n' "$*"
}

shell_quote() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

rclone_remote_ready() {
    local remote_name
    remote_name="${REMOTE_DIR%%:*}:"

    command -v rclone >/dev/null 2>&1 || return 1
    rclone listremotes | grep -Fxq "$remote_name" || return 1
    rclone mkdir "$REMOTE_DIR" >/dev/null 2>&1 || return 1
}

cleanup_old_processes() {
    pkill -9 -f qemu-system-x86_64 || true
    pkill -9 -f 'cloudflared.*tunnel' || true
    pkill -9 -f "websockify.*${NOVNC_PORT}" || true
    pkill -9 -f "novnc_proxy.*${NOVNC_PORT}" || true
    sleep 2
}

build_qemu_accel_args() {
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        QEMU_ACCEL_ARGS=(-enable-kvm -cpu host)
    else
        log "KVM is not available. Falling back to TCG emulation; this will be slower."
        QEMU_ACCEL_ARGS=(-accel tcg -cpu max)
    fi
}

download_iso() {
    mkdir -p "$(dirname "$ISO_FILE")"

    if [ ! -f "$ISO_FILE" ]; then
        log "Downloading Alpine Linux ISO..."
        rm -f "${ISO_FILE}.part"
        wget -O "${ISO_FILE}.part" "$ISO_URL"
        mv "${ISO_FILE}.part" "$ISO_FILE"
    fi

    if [ -n "$ISO_SHA256" ] && command -v sha256sum >/dev/null 2>&1; then
        log "Verifying ISO checksum..."
        printf '%s  %s\n' "$ISO_SHA256" "$ISO_FILE" | sha256sum -c -
    fi
}

restore_disk() {
    if ! rclone_remote_ready; then
        log "Rclone remote is not ready. Skipping cloud restore."
        return 1
    fi

    if rclone lsf "$REMOTE_DIR" --files-only | grep -Fxq "$REMOTE_NAME"; then
        log "Found cloud backup. Restoring $REMOTE_PATH..."
        rclone copyto "$REMOTE_PATH" "$DISK_FILE" -P
        touch "$FLAG_FILE"
        return 0
    fi

    log "No cloud backup found. A new Linux disk will be created."
    return 1
}

prepare_disk() {
    mkdir -p "$(dirname "$DISK_FILE")"

    if [ -f "$DISK_FILE" ]; then
        if [ ! -f "$FLAG_FILE" ]; then
            download_iso
        fi
        return
    fi

    log "Disk not found at $DISK_FILE"
    if restore_disk; then
        return
    fi

    rm -f "$FLAG_FILE"
    log "Creating new qcow2 disk: $DISK_SIZE"
    qemu-img create -f qcow2 "$DISK_FILE" "$DISK_SIZE"
    download_iso
}

find_novnc_web() {
    local candidate
    local vnc_html

    if [ -n "${NOVNC_WEB:-}" ] && [ -f "$NOVNC_WEB/vnc.html" ]; then
        printf '%s\n' "$NOVNC_WEB"
        return 0
    fi

    for candidate in \
        /usr/share/novnc \
        /usr/share/noVNC \
        /usr/share/webapps/novnc \
        /usr/share/webapps/noVNC
    do
        if [ -f "$candidate/vnc.html" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    vnc_html="$(find /nix/store /usr/share -maxdepth 6 -type f -name vnc.html 2>/dev/null \
        | grep -i '/novnc/' | head -n 1 || true)"
    if [ -n "$vnc_html" ]; then
        dirname "$vnc_html"
        return 0
    fi

    return 1
}

start_novnc() {
    local novnc_web

    NOVNC_PID=""
    novnc_web="$(find_novnc_web || true)"

    if command -v websockify >/dev/null 2>&1; then
        if [ -z "$novnc_web" ]; then
            log "Could not find noVNC web files. Set NOVNC_WEB=/path/to/noVNC."
            return 1
        fi

        log "Starting noVNC on http://${NOVNC_LISTEN_HOST}:${NOVNC_PORT}/vnc.html"
        websockify --web "$novnc_web" "${NOVNC_LISTEN_HOST}:${NOVNC_PORT}" "127.0.0.1:${QEMU_VNC_PORT}" \
            >/tmp/novnc.log 2>&1 &
        NOVNC_PID="$!"
        return 0
    fi

    if command -v novnc_proxy >/dev/null 2>&1; then
        log "Starting noVNC proxy on port ${NOVNC_PORT}"
        novnc_proxy --listen "$NOVNC_PORT" --vnc "127.0.0.1:${QEMU_VNC_PORT}" \
            >/tmp/novnc.log 2>&1 &
        NOVNC_PID="$!"
        return 0
    fi

    log "websockify or novnc_proxy is required for noVNC."
    return 1
}

read_cloudflared_addr() {
    local log_file="$1"
    grep -oE 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$log_file" 2>/dev/null \
        | grep -v 'api\.trycloudflare\.com' \
        | tail -n 1 || true
}

start_cloudflared() {
    CLOUDFLARED_PID=""
    CLOUDFLARE_ADDR="$CF_PUBLIC_HOSTNAME"

    if ! command -v cloudflared >/dev/null 2>&1; then
        log "cloudflared is required for Cloudflare Tunnel."
        return 1
    fi

    rm -f /tmp/cloudflared-novnc.log

    if [ -n "$CF_TUNNEL_TOKEN" ]; then
        log "Starting Cloudflare named tunnel from CF_TUNNEL_TOKEN..."
        cloudflared tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN" \
            >/tmp/cloudflared-novnc.log 2>&1 &
    else
        log "Starting Cloudflare quick tunnel to $CLOUDFLARED_URL..."
        cloudflared tunnel --no-autoupdate --url "$CLOUDFLARED_URL" \
            >/tmp/cloudflared-novnc.log 2>&1 &
    fi

    CLOUDFLARED_PID="$!"
    sleep 8

    if [ -z "$CLOUDFLARE_ADDR" ]; then
        CLOUDFLARE_ADDR="$(read_cloudflared_addr /tmp/cloudflared-novnc.log)"
    fi
}

novnc_public_url() {
    local base="$1"

    [ -n "$base" ] || return 0
    base="${base%/}"
    printf '%s/vnc.html?autoconnect=true&resize=scale&reconnect=true&path=websockify\n' "$base"
}

wait_for_tcp() {
    local host="$1"
    local port="$2"
    local timeout_seconds="$3"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout_seconds" ]; do
        if (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
            return 0
        fi

        sleep 1
        elapsed=$((elapsed + 1))
    done

    return 1
}

backup_disk() {
    if ! rclone_remote_ready; then
        log "Rclone remote is not ready. Skipping cloud backup."
        return 0
    fi

    log "Uploading latest disk backup to $REMOTE_PATH..."
    rclone copyto "$DISK_FILE" "$REMOTE_PATH" -P
}

write_provision_script() {
    local quoted_ts_auth_key
    local quoted_tailscale_hostname
    local quoted_tailscale_up_flags

    quoted_ts_auth_key="$(shell_quote "$TS_AUTH_KEY")"
    quoted_tailscale_hostname="$(shell_quote "$TAILSCALE_HOSTNAME")"
    quoted_tailscale_up_flags="$(shell_quote "$TAILSCALE_UP_FLAGS")"

    mkdir -p "$PROVISION_DIR"
    chmod 700 "$PROVISION_DIR"
    rm -f "$PROVISION_DIR/provision.sh"

    cat >"$PROVISION_DIR/provision.sh" <<EOF
#!/bin/sh
set -eu

TS_AUTH_KEY=$quoted_ts_auth_key
TAILSCALE_HOSTNAME=$quoted_tailscale_hostname
TAILSCALE_UP_FLAGS=$quoted_tailscale_up_flags

log() {
    printf '%s\n' "\$*"
}

require_root() {
    if [ "\$(id -u)" != "0" ]; then
        log "Run this provision script as root."
        exit 1
    fi
}

enable_community_repo() {
    main_repo=""
    community_repo=""

    if grep -Eq '^[[:space:]]*https?://.*/community/?[[:space:]]*$' /etc/apk/repositories; then
        return
    fi

    main_repo="\$(grep -E '^[[:space:]]*https?://.*/v[0-9]+\\.[0-9]+/main/?[[:space:]]*$' /etc/apk/repositories | head -n 1 | tr -d '[:space:]' || true)"
    main_repo="\${main_repo%/}"

    if [ -n "\$main_repo" ]; then
        community_repo="\${main_repo%/main}/community"
    else
        community_repo="https://dl-cdn.alpinelinux.org/alpine/v3.23/community"
    fi

    log "Enabling Alpine community repository: \$community_repo"
    printf '%s\n' "\$community_repo" >> /etc/apk/repositories
}

start_service() {
    service_name="\$1"

    if command -v rc-update >/dev/null 2>&1; then
        rc-update add "\$service_name" default >/dev/null 2>&1 || true
    fi

    if command -v rc-service >/dev/null 2>&1; then
        rc-service "\$service_name" restart >/dev/null 2>&1 || rc-service "\$service_name" start >/dev/null 2>&1 || true
    fi
}

require_root
enable_community_repo

log "Updating apk indexes..."
apk update

log "Installing OpenSSH and Tailscale..."
apk add --no-cache openssh openssh-server openssh-server-common-openrc tailscale tailscale-openrc ca-certificates iptables ip6tables kmod

if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -A
fi

modprobe tun >/dev/null 2>&1 || true

# --- Bật serial console getty trên ttyS0 (cần cho auto-provision) ---
if ! grep -q 'ttyS0' /etc/inittab 2>/dev/null; then
    log "Enabling serial console getty on ttyS0..."
    echo 'ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100' >> /etc/inittab
    kill -HUP 1 2>/dev/null || true
fi

# --- Cho phép root SSH login (cần cho quản lý từ xa) ---
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
fi

start_service sshd
start_service tailscale
sleep 2

if [ -n "\$TS_AUTH_KEY" ] && [ "\$TS_AUTH_KEY" != "PASTE_TS_AUTH_KEY_HERE" ]; then
    log "Logging in to Tailscale with TS_AUTH_KEY..."
    set -- --auth-key "\$TS_AUTH_KEY"

    if [ -n "\$TAILSCALE_HOSTNAME" ]; then
        set -- "\$@" --hostname "\$TAILSCALE_HOSTNAME"
    fi

    # TAILSCALE_UP_FLAGS is intentionally split so callers can pass multiple flags.
    tailscale up "\$@" \$TAILSCALE_UP_FLAGS
else
    log "TS_AUTH_KEY is empty or still set to placeholder; installed Tailscale but skipped login."
fi

tailscale status || true
log "Provision complete."

# --- Tạo script tự động re-authenticate Tailscale mỗi lần boot ---
log "Creating Tailscale auto-reauth boot script..."
mkdir -p /etc/local.d

{
echo '#!/bin/sh'
echo 'sleep 15'
echo 'if ! command -v tailscale >/dev/null 2>&1; then exit 0; fi'
echo 'if tailscale status 2>/dev/null | grep -q "^100\\."; then exit 0; fi'
echo "tailscale up --auth-key \$TS_AUTH_KEY --hostname \$TAILSCALE_HOSTNAME \$TAILSCALE_UP_FLAGS 2>/dev/null || true"
echo 'tailscale status || true'
} > /etc/local.d/tailscale-reauth.start

chmod +x /etc/local.d/tailscale-reauth.start
rc-update add local default 2>/dev/null || true
log "Tailscale auto-reauth boot script installed."
EOF

    chmod 700 "$PROVISION_DIR/provision.sh"
}

start_provision_http_server() {
    PROVISION_HTTP_PID=""

    [ "$ENABLE_PROVISION_HTTP" = "1" ] || return 0
    command -v python3 >/dev/null 2>&1 || {
        log "python3 is not available. Provision HTTP server is disabled."
        return 0
    }

    (cd "$PROVISION_DIR" && python3 -m http.server "$PROVISION_PORT" --bind 127.0.0.1 >/tmp/provision-http.log 2>&1) &
    PROVISION_HTTP_PID="$!"
}

_auto_provision_worker() {
    # Worker chạy nền, tương tác serial console qua raw TCP.
    # Dùng bash /dev/tcp/ + cat reader nền + grep pattern matching.

    local serial_out="/tmp/serial-provision.out"
    local reader_pid=""

    log "[auto-provision] Chờ ${BOOT_WAIT}s cho VM boot..."
    sleep "$BOOT_WAIT"

    # Retry kết nối serial (VM có thể chưa sẵn sàng)
    local attempt
    for attempt in 1 2 3 4 5; do
        if (echo >/dev/tcp/127.0.0.1/${SERIAL_PORT}) 2>/dev/null; then
            break
        fi
        if [ "$attempt" -eq 5 ]; then
            log "[auto-provision] Serial không sẵn sàng sau 5 lần thử. Bỏ qua."
            return 1
        fi
        log "[auto-provision] Serial chưa sẵn sàng, thử lại ($attempt/5)..."
        sleep 5
    done

    # Mở kết nối TCP (fd 3 = đọc + ghi)
    exec 3<>/dev/tcp/127.0.0.1/${SERIAL_PORT} || {
        log "[auto-provision] Không thể mở kết nối serial."
        return 1
    }

    # Reader nền: ghi mọi output serial vào file để grep kiểm tra
    > "$serial_out"
    cat <&3 >> "$serial_out" 2>/dev/null &
    reader_pid=$!

    # Cleanup khi worker thoát
    trap 'kill $reader_pid 2>/dev/null; exec 3>&- 2>/dev/null' EXIT

    # --- Helper ---
    _send() {
        printf '%s\r\n' "$1" >&3
        sleep "${2:-1}"
    }

    _wait_for() {
        local pattern="$1" timeout="${2:-120}" i=0
        while [ "$i" -lt "$timeout" ]; do
            if grep -q "$pattern" "$serial_out" 2>/dev/null; then
                return 0
            fi
            sleep 1
            i=$((i + 1))
        done
        return 1
    }

    _recent_has() {
        # Kiểm tra 500 byte cuối (tránh match boot messages cũ)
        tail -c 500 "$serial_out" 2>/dev/null | grep -qi "$1"
    }

    # --- Bắt đầu tương tác serial ---
    log "[auto-provision] Đã kết nối serial console."

    # Gửi Enter để kích hoạt login prompt
    _send "" 2
    _send "" 2

    # Chờ login prompt
    log "[auto-provision] Chờ login prompt..."
    if ! _wait_for "login:" 120; then
        log "[auto-provision] Timeout chờ login. VM có thể chưa bật serial."
        return 1
    fi

    # Đăng nhập root
    log "[auto-provision] Đăng nhập root..."
    _send "root" 3

    # Kiểm tra password prompt (500 byte cuối)
    if _recent_has "password"; then
        log "[auto-provision] Gửi mật khẩu..."
        _send "$GUEST_ROOT_PASS" 3
    fi

    # Xác nhận shell sẵn sàng bằng echo marker
    _send 'echo __SHELL_READY__' 2
    if ! _wait_for "__SHELL_READY__" 15; then
        log "[auto-provision] Shell chưa sẵn sàng. Bỏ qua."
        return 1
    fi

    # --- Chạy provision ---
    log "[auto-provision] Mount provision drive..."
    _send 'mkdir -p /mnt/provision' 2
    _send 'for dev in /dev/vdb /dev/vdb1 /dev/sdb /dev/sdb1; do mount "$dev" /mnt/provision 2>/dev/null && break; done' 4

    log "[auto-provision] Chạy provision.sh..."
    _send 'if [ -f /mnt/provision/provision.sh ]; then sh /mnt/provision/provision.sh && echo AUTO_PROVISION_OK || echo AUTO_PROVISION_FAIL; else echo AUTO_PROVISION_NO_SCRIPT; fi' 5

    # Chờ provision hoàn tất (apk install có thể mất vài phút)
    log "[auto-provision] Chờ provision hoàn tất (tối đa 10 phút)..."
    if _wait_for "AUTO_PROVISION_OK" 600; then
        log "[auto-provision] === THÀNH CÔNG! Tailscale đã online. ==="
        touch "$PROVISIONED_FLAG"
        return 0
    fi

    # Kiểm tra lỗi cụ thể
    if grep -q "AUTO_PROVISION_FAIL" "$serial_out" 2>/dev/null; then
        log "[auto-provision] Provision thất bại. Kiểm tra qua noVNC."
    elif grep -q "AUTO_PROVISION_NO_SCRIPT" "$serial_out" 2>/dev/null; then
        log "[auto-provision] Không tìm thấy provision.sh trên ổ provision."
    else
        log "[auto-provision] Timeout. Kiểm tra qua noVNC hoặc /tmp/serial-provision.out"
    fi
    return 1
}

auto_provision() {
    AUTO_PROVISION_PID=""

    [ "$AUTO_PROVISION" = "1" ] || return 0
    [ -f "$FLAG_FILE" ] || return 0

    if [ -f "$PROVISIONED_FLAG" ]; then
        log "Already provisioned. Tailscale auto-starts on boot."
        return 0
    fi

    if [ -z "$GUEST_ROOT_PASS" ]; then
        log "GUEST_ROOT_PASS is empty. Skipping auto-provision."
        return 0
    fi

    log "Auto-provision will start in ${BOOT_WAIT}s (background, log: /tmp/auto-provision.log)..."
    _auto_provision_worker >/tmp/auto-provision.log 2>&1 &
    AUTO_PROVISION_PID="$!"
}

cleanup_old_processes
prepare_disk
build_qemu_accel_args
write_provision_script
start_provision_http_server

if [ ! -f "$FLAG_FILE" ]; then
    BOOT_ARGS=(-cdrom "$ISO_FILE" -boot order=d)
    MODE="INSTALL (Alpine ISO)"
else
    BOOT_ARGS=(-boot order=c)
    MODE="RUNNING (installed disk)"
fi

rm -f /tmp/qemu.log /tmp/novnc.log /tmp/cloudflared-novnc.log /tmp/auto-provision.log

log "------------------------------------------------"
log "Linux server VM is starting"
log "Mode: $MODE"
if [ ! -f "$FLAG_FILE" ]; then
    log "First install: run setup-alpine via noVNC, complete the install, type 'poweroff', then type 'xong' here to save."
    log "IMPORTANT: set root password to '${GUEST_ROOT_PASS}' during setup-alpine for auto-provision."
    log "NOTE: Auto-provision might fail if serial console is not enabled on the installed disk."
    log "      If Tailscale doesn't connect on next boot, run provision.sh manually from noVNC:"
    log "      mount /dev/vdb /mnt && sh /mnt/provision.sh"
else
    if [ -f "$PROVISIONED_FLAG" ]; then
        log "Tailscale: already provisioned, auto-starts on boot."
    elif [ "$AUTO_PROVISION" = "1" ] && [ -n "$GUEST_ROOT_PASS" ]; then
        log "Auto-provision: will run provision.sh automatically after boot (${BOOT_WAIT}s delay)."
        log "Serial console: nc 127.0.0.1 ${SERIAL_PORT}"
    else
        log "Manual provision: mount /dev/vdb at /mnt/provision, then run /mnt/provision/provision.sh."
    fi
    if [ "$ENABLE_PROVISION_HTTP" = "1" ]; then
        log "Provision HTTP fallback: wget -O - http://10.0.2.2:${PROVISION_PORT}/provision.sh | sh"
    fi
fi
log "Install hint: login root, run 'setup-alpine', set password to '${GUEST_ROOT_PASS}', install to disk 'vda', enable 'openssh'."
log "------------------------------------------------"

qemu-system-x86_64 \
    "${QEMU_ACCEL_ARGS[@]}" -smp "$CORES" -m "$RAM" -machine q35 \
    -drive "file=$DISK_FILE,if=virtio,format=qcow2,cache=writeback,discard=unmap" \
    -drive "file=fat:ro:$PROVISION_DIR,if=virtio,readonly=on" \
    "${BOOT_ARGS[@]}" \
    -netdev "user,id=net0,hostfwd=tcp::${HOST_SSH_PORT}-:22,hostfwd=tcp::${HOST_HTTP_PORT}-:80,hostfwd=tcp::${HOST_HTTPS_PORT}-:443" \
    -device virtio-net-pci,netdev=net0 \
    -device virtio-rng-pci \
    -vnc "127.0.0.1:${QEMU_VNC_DISPLAY}" -usb -device usb-tablet \
    -serial tcp:127.0.0.1:${SERIAL_PORT},server=on,wait=off \
    >/tmp/qemu.log 2>&1 &

QEMU_PID=$!
auto_provision

if ! wait_for_tcp 127.0.0.1 "$QEMU_VNC_PORT" 45; then
    log "QEMU console did not open on 127.0.0.1:${QEMU_VNC_PORT}."
    log "Last QEMU log lines:"
    tail -n 80 /tmp/qemu.log 2>/dev/null || true
    kill "$QEMU_PID" 2>/dev/null || true
    exit 1
fi

start_novnc || {
    kill "$QEMU_PID" 2>/dev/null || true
    exit 1
}

if ! wait_for_tcp "$NOVNC_LISTEN_HOST" "$NOVNC_PORT" 20; then
    log "noVNC/websockify did not open on ${NOVNC_LISTEN_HOST}:${NOVNC_PORT}."
    log "Last noVNC log lines:"
    tail -n 80 /tmp/novnc.log 2>/dev/null || true
    kill "$QEMU_PID" 2>/dev/null || true
    exit 1
fi

start_cloudflared || {
    kill "$NOVNC_PID" 2>/dev/null || true
    kill "$QEMU_PID" 2>/dev/null || true
    exit 1
}
NOVNC_URL="$(novnc_public_url "$CLOUDFLARE_ADDR")"

log "------------------------------------------------"
log "noVNC via Cloudflare: ${NOVNC_URL:-not ready; check /tmp/cloudflared-novnc.log}"
log "noVNC local: http://${NOVNC_LISTEN_HOST}:${NOVNC_PORT}/vnc.html"
log "QEMU console backend is local only: 127.0.0.1:${QEMU_VNC_PORT}"
log "Serial console: nc 127.0.0.1 ${SERIAL_PORT}"
log "Guest host forwards stay local: ${HOST_SSH_PORT}->22, ${HOST_HTTP_PORT}->80, ${HOST_HTTPS_PORT}->443"
log "Type 'xong' then Enter to stop and backup."
log "------------------------------------------------"

while true; do
    read -rp "Type 'xong' to stop VM and backup: " input
    if [ "$input" = "xong" ]; then
        log "Stopping VM..."
        kill "$QEMU_PID" 2>/dev/null || pkill -f qemu-system-x86_64 || true
        sleep 3
        kill -9 "$QEMU_PID" 2>/dev/null || true

        if [ ! -f "$FLAG_FILE" ]; then
            touch "$FLAG_FILE"
            rm -f "$ISO_FILE"
        fi
        break
    fi
done

backup_disk
if [ -n "${CLOUDFLARED_PID:-}" ]; then
    kill "$CLOUDFLARED_PID" 2>/dev/null || true
fi
if [ -n "${NOVNC_PID:-}" ]; then
    kill "$NOVNC_PID" 2>/dev/null || true
fi
if [ -n "${PROVISION_HTTP_PID:-}" ]; then
    kill "$PROVISION_HTTP_PID" 2>/dev/null || true
fi
if [ -n "${AUTO_PROVISION_PID:-}" ]; then
    kill "$AUTO_PROVISION_PID" 2>/dev/null || true
fi
log "Done."
