# detour-server

A minimal, self-hosted TLS tunnel server (Go) with a built-in user store. Backend for the [`detour_vpn`](../packages/detour_vpn) Flutter package / [`app`](../app) mobile client.

## Why this exists

WireGuard and OpenVPN both work fine in general, but some networks block WireGuard's UDP handshake at the router/DPI level, and OpenVPN has no clean, currently-maintained prebuilt Android library to embed. This is a deliberately small, custom alternative: plain TLS on port 443, which looks like ordinary HTTPS to that kind of filtering.

## Protocol

1. Client opens a TCP connection to the server and performs a TLS handshake.
2. Client sends an auth frame: `1 byte username length | username | 1 byte password length | password`.
3. Server checks the username/password (bcrypt) against its own user database. Response: `1 byte status` (0=ok, others under "Admin protocol"), and if ok, `4 bytes` assigned IPv4 address.
4. From then on, both directions relay length-prefixed raw IP packets (`2-byte big-endian length | packet bytes`) between the client's local TUN device and the server's shared TUN device, NAT'd out to the internet.

No CA, no domain: the server's certificate is self-signed with the server's IP as the Subject Alternative Name. The client pins the certificate's exact SHA-256 fingerprint instead of validating a certificate chain — same trust model as WireGuard pinning a public key, applied to TLS.

## Install

You need a Linux server with a public IPv4 address, root access, `openssl` and `nftables`. Port 443 must be free, and open to TCP from anywhere. If your provider has its own firewall (such as AWS security groups), open it there too, and allow whatever outbound ports you want VPN users to have.

### 1. Build the program

On any computer with [Go](https://go.dev/dl/), in this folder. Use `GOARCH=arm64` for ARM servers:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o detour-server .
scp detour-server you@YOUR.SERVER.IP:/tmp/
```

Run everything below **on the server**, in one terminal session.

### 2. Install it and create the certificate

Set your server's public IP first:

```bash
SERVER_IP=YOUR.SERVER.IP
```

```bash
sudo install -m 755 /tmp/detour-server /usr/local/bin/detour-server
sudo install -d -m 700 /etc/detour /var/lib/detour
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /etc/detour/server.key -out /etc/detour/server.crt \
  -subj "/CN=$SERVER_IP" -addext "subjectAltName=IP:$SERVER_IP"
sudo chmod 600 /etc/detour/server.key
```

Keep this certificate. Apps trust exactly this one, so replacing it breaks every invite link.

### 3. Let VPN traffic reach the internet

This turns on IP forwarding and shares the server's connection with VPN users. It also keeps them away from the server itself and from private networks, including cloud metadata services.

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/90-detour.conf
sudo sysctl -p /etc/sysctl.d/90-detour.conf
NET_IF=$(ip -o route show default | awk '{print $5; exit}')
sudo tee /etc/detour/detour.nft <<EOF
table ip detour
delete table ip detour
table ip detour {
  chain forward {
    type filter hook forward priority 0; policy accept;
    iifname "tun0" ip saddr != 10.10.0.0/24 drop
    iifname "tun0" ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } drop
    iifname "tun0" tcp flags syn tcp option maxseg size set rt mtu
    oifname "tun0" ct state new drop
  }
  chain input {
    type filter hook input priority 0; policy accept;
    iifname "tun0" drop
  }
  chain postrouting {
    type nat hook postrouting priority 100;
    ip saddr 10.10.0.0/24 oifname "$NET_IF" masquerade
  }
}
EOF
```

If you use `ufw`, it needs to allow this too:

```bash
sudo ufw allow 443/tcp
sudo ufw route allow in on tun0 out on "$NET_IF"
```

Docker also blocks forwarding by default. On a server running Docker, allow it with `sudo iptables -I DOCKER-USER -i tun0 -j ACCEPT` and the same for `-o tun0`, and make those rules persistent.

### 4. Start it, now and on every boot

```bash
sudo tee /etc/systemd/system/detour-server.service <<'EOF'
[Unit]
Description=detour-server
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/usr/sbin/nft -f /etc/detour/detour.nft
ExecStart=/usr/local/bin/detour-server serve
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now detour-server
```

It creates and configures its own `tun0` interface. Check it with `systemctl status detour-server`, and read its log with `journalctl -u detour-server`.

### 5. Create your admin and get their invite link

```bash
PASSWORD=$(openssl rand -hex 16)
sudo detour-server adduser admin "$PASSWORD"
sudo detour-server setadmin admin on
FINGERPRINT=$(sudo openssl x509 -in /etc/detour/server.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)
echo "detour://admin:$PASSWORD@$SERVER_IP:443/$FINGERPRINT?name=myserver"
```

Copy the `detour://` line to your phone privately (it contains the password). In the app, tap **+**, then **Paste**, then **Add**. Choose your apps under **⋮ → Select apps** before connecting: with none selected, every app uses the VPN.

From then on, invite everyone else from the app under **⋮ → Manage users**.

## Managing users

```bash
detour-server adduser <username> [password]   # omit password to auto-generate one
detour-server deluser <username>
detour-server setadmin <username> on|off
detour-server listusers
```

All of them, and `serve`, use `/var/lib/detour/users.db`. To use another file, put `--db` right after the command name, before the username.

Every server is independent: it has its own users and its own admins. Make the first admin with `setadmin` on the server. Admins can then add, reset and remove that server's users from the app (**⋮ → Manage users**), but only the CLI can make or unmake admins.

Removing a user or changing their password disconnects them: right away from the app, within 5 seconds from the CLI.

Admins can also give each user a speed limit (each way, shared by all their devices) and a total data allowance (upload plus download, counted until an admin resets it). The server enforces both: packets over the speed are dropped, and a user who runs out is disconnected and refused. Usage is saved every 5 seconds, so a restart can lose that much.

## Admin protocol

An admin client sends a `0` byte before the normal auth frame. After status `0` it sends one framed JSON request (`{"op": "list"|"add"|"reset"|"remove"|"setlimits"|"resetusage", "username": "...", "speedKbps": 0, "quotaBytes": 0}`) and gets one line of JSON back, with `error` set on failure.

Login status bytes: `0` ok, `1` access denied, `2` no free addresses, `3` data limit reached.

## Notes / limitations

- No traffic logging by design. Logs show only connection lifecycle events (connect/disconnect/auth failure), never packet contents.
- Up to 252 clients at once. An address is freed when its client disconnects, or about 40 seconds after a connection dies silently.
- Logins must finish within 10 seconds. Each source IP (IPv6: each /64) gets 8 logins in progress and 10 wrong passwords per 5 minutes, with 128 logins in progress overall. People sharing one public IP share that limit; restarting the server clears it.
- IPv4 only.
- The same invite link works on several devices at once.
- Single shared TUN device for all clients; the server dispatches packets to the right client by destination IP against a small in-memory map.
