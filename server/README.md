# detour-server

A minimal, self-hosted TLS tunnel server (Go) with a built-in user store. Backend for the [`detour_vpn`](../packages/detour_vpn) Flutter package / [`app`](../app) mobile client.

## Why this exists

WireGuard and OpenVPN both work fine in general, but some networks block WireGuard's UDP handshake at the router/DPI level, and OpenVPN has no clean, currently-maintained prebuilt Android library to embed. This is a deliberately small, custom alternative: plain TLS on port 443, indistinguishable from ordinary HTTPS to that kind of filtering.

## Protocol

1. Client opens a TCP connection to the server and performs a TLS handshake.
2. Client sends an auth frame: `1 byte username length | username | 1 byte password length | password`.
3. Server checks the username/password (bcrypt) against its own user database. Response: `1 byte status` (0=ok, others under "Admin protocol"), and if ok, `4 bytes` assigned IPv4 address.
4. From then on, both directions relay length-prefixed raw IP packets (`2-byte big-endian length | packet bytes`) between the client's local TUN device and the server's shared TUN device, NAT'd out to the internet.

No CA, no domain: the server's certificate is self-signed with the server's IP as the Subject Alternative Name. The client pins the certificate's exact SHA-256 fingerprint instead of validating a certificate chain — same trust model as WireGuard pinning a public key, applied to TLS.

## Building

```bash
GOOS=linux GOARCH=amd64 go build -o detour-server-linux-amd64 .
```

## First-time setup on a fresh server

```bash
# 1. Generate the self-signed cert (replace with your server's IP, no domain needed)
sudo mkdir -p /etc/detour /var/lib/detour
sudo openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /etc/detour/server.key -out /etc/detour/server.crt -days 3650 \
  -subj '/CN=YOUR.SERVER.IP' -addext 'subjectAltName=IP:YOUR.SERVER.IP'
sudo chmod 600 /etc/detour/server.key

# 2. Deploy the binary (after cross-compiling locally, scp it over)
scp detour-server-linux-amd64 user@server:/tmp/detour-server
ssh user@server 'sudo mv /tmp/detour-server /usr/local/bin/detour-server && sudo chmod 755 /usr/local/bin/detour-server'

# 3. Add a user (prints the fingerprint-free config line to paste into the app)
sudo detour-server adduser alice
#   user "alice" added/updated
#   username: alice
#   password: <generated>
# Get the cert fingerprint for the app's config text (see packages/detour_vpn):
openssl x509 -in /etc/detour/server.crt -noout -fingerprint -sha256

# 4. Firewall + NAT (adjust interface name / subnet as needed)
sudo ufw allow 443/tcp comment 'detour-server'
# Add to /etc/ufw/before.rules, before the filter rules:
#   *nat
#   :POSTROUTING ACCEPT [0:0]
#   -A POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE
#   COMMIT
sudo ufw reload

# 5. Run it (needs root: TUN device creation + binding port 443)
sudo detour-server serve
```

A sample systemd unit:

```ini
[Unit]
Description=detour-server
After=network.target

[Service]
ExecStart=/usr/local/bin/detour-server serve
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

The binary configures its own TUN device (creates it, assigns `10.10.0.1/24`, brings it up) on startup — no manual `ip` commands needed.

## Managing users

```bash
detour-server adduser <username> [password]   # omit password to auto-generate one
detour-server deluser <username>
detour-server setadmin <username> on|off
detour-server listusers
```

All of them default to `/var/lib/detour/users.db` (override with `--db`); `serve` reads the same file with `--db`.

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
- Single shared TUN device for all clients; the server dispatches packets to the right client by destination IP against a small in-memory map.
