# detour-server

A minimal, self-hosted TLS tunnel server (Go) with a built-in user store. Backend for the [`detour_vpn`](../packages/detour_vpn) Flutter package / [`app`](../app) mobile client.

## Why this exists

WireGuard and OpenVPN both work fine in general, but some networks block WireGuard's UDP handshake at the router/DPI level, and OpenVPN has no clean, currently-maintained prebuilt Android library to embed. This is a deliberately small, custom alternative: plain TLS on port 443, indistinguishable from ordinary HTTPS to that kind of filtering.

## Protocol

1. Client opens a TCP connection to the server and performs a TLS handshake.
2. Client sends an auth frame: `1 byte username length | username | 1 byte password length | password`.
3. Server checks the username/password (bcrypt) against its own user database. Response: `1 byte status (0=ok, 1=fail)`, and if ok, `4 bytes` assigned IPv4 address.
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
detour-server listusers
```

All three default to `/var/lib/detour/users.db` (override with `--db`); `serve` reads the same file with `--db`.

## Notes / limitations

- No traffic logging by design. Logs show only connection lifecycle events (connect/disconnect/auth failure), never packet contents.
- The IP allocator hands out addresses sequentially and doesn't reuse them within a process lifetime — restart the service if you're churning through the `/24` (254 addresses; a non-issue for personal use).
- Single shared TUN device for all clients; the server dispatches packets to the right client by destination IP against a small in-memory map.
