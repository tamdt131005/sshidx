# linux_server_idx

Lightweight Linux VM runner for IDX, changed from Windows Lite to Alpine Linux
Virt for server use.

## What it does

- Creates `/var/linux_server.qcow2`.
- Downloads Alpine Linux Virt ISO.
- Opens a browser console through noVNC and Cloudflare Tunnel.
- Generates a guest provision script that installs OpenSSH and Tailscale.
- Forwards host ports to the guest:
  - `2222 -> 22` for SSH
  - `8080 -> 80` for HTTP
  - `8443 -> 443` for HTTPS
- Restores and backs up the disk with `rclone` at
  `gdrive:IDX_VM_linux_server/linux_server.qcow2`.

## First install

Run:

```bash
chmod +x run.sh
bash run.sh
```

Open the printed noVNC Cloudflare URL in a browser. In Alpine:

```bash
root
setup-alpine
```

Recommended installer choices:

- Disk: `vda`
- Install mode: `sys`
- SSH server: `openssh`
- Network: `eth0` with DHCP

After the install finishes, power off the VM from Alpine, then type `xong` in
the script terminal so the disk is marked installed and backed up. Start
`run.sh` again to boot from the installed disk.

To install OpenSSH and Tailscale in the installed guest, run this as root inside
Alpine after the second boot:

```sh
mkdir -p /mnt/provision
for dev in /dev/vdb /dev/vdb1 /dev/sdb /dev/sdb1; do
  mount "$dev" /mnt/provision 2>/dev/null && break
done
sh /mnt/provision/provision.sh
```

Then power off the VM and type `xong` again so the provisioned disk is backed up.

## Tailscale auth key

Put your auth key directly in `run.sh` by replacing `PASTE_TS_AUTH_KEY_HERE`:

```bash
bash run.sh
```

You can still override it from the command line with
`TS_AUTH_KEY=tskey-auth-xxxxx bash run.sh`.

Optional Tailscale settings:

```bash
TAILSCALE_HOSTNAME=my-idx-server TAILSCALE_UP_FLAGS="--ssh --accept-routes" bash run.sh
```

## Runtime access

On later runs, use the printed noVNC Cloudflare URL for the VM console. The
QEMU console backend only listens on `127.0.0.1`, so there is no public VNC port
and no `bore.pub` tunnel.

By default the script uses a temporary Cloudflare Quick Tunnel. For a named
Cloudflare Tunnel, set `CF_TUNNEL_TOKEN` and configure the tunnel service in
Cloudflare Zero Trust to point to `http://127.0.0.1:6080`. Set
`CF_PUBLIC_HOSTNAME` if you want the script to print your stable hostname.

```bash
CF_TUNNEL_TOKEN=xxxxx CF_PUBLIC_HOSTNAME=https://vm.example.com bash run.sh
```

Useful overrides:

```bash
RAM=4G CORES=4 DISK_SIZE=20G bash run.sh
```

Change the local noVNC port if needed:

```bash
NOVNC_PORT=6081 bash run.sh
```

If mounting `/dev/vdb` does not work in the guest, enable the HTTP fallback:

```bash
ENABLE_PROVISION_HTTP=1 TS_AUTH_KEY=tskey-auth-xxxxx bash run.sh
```

Then run this inside Alpine:

```sh
wget -O - http://10.0.2.2:18080/provision.sh | sh
```
