# TURN Server

For calls through corporate NAT or symmetric firewalls, you need a TURN relay server.

## Why TURN?

WebRTC ICE tries direct P2P first (STUN). If both peers are behind symmetric NAT, direct connection fails and a relay is needed. TURN servers relay encrypted media — the DTLS-SRTP encryption is maintained end-to-end, the TURN server cannot decrypt audio.

## Deploy Coturn

[Coturn](https://github.com/coturn/coturn) is the standard open-source TURN server.

```bash
# Ubuntu/Debian
apt install coturn
```

### Configuration (`/etc/turnserver.conf`)

```conf
listening-port=3478
tls-listening-port=5349
realm=yourapp.com
server-name=yourapp.com
fingerprint
lt-cred-mech
user=turnuser:strongpassword
cert=/path/to/fullchain.pem
pkey=/path/to/privkey.pem
log-file=/var/log/coturn/turn.log
no-multicast-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
```

```bash
systemctl enable coturn
systemctl start coturn
```

### Configure the Flutter Client

In `lib/core/constants.dart`:

```dart
static const List<Map<String, dynamic>> iceServers = [
  { 'urls': 'stun:stun.l.google.com:19302' },
  {
    'urls': 'turn:yourapp.com:3478',
    'username': 'turnuser',
    'credential': 'strongpassword',
  },
  {
    'urls': 'turns:yourapp.com:5349',  // TLS
    'username': 'turnuser',
    'credential': 'strongpassword',
  },
];
```

## Free Alternatives

| Provider | Free Tier | Notes |
|---|---|---|
| [Metered.ca](https://www.metered.ca/) | 50 GB / month | Easy setup, managed |
| [Cloudflare Calls](https://developers.cloudflare.com/calls/) | 1000 min / month | SFU + TURN |
| [Twilio](https://www.twilio.com/en-us/stun-turn) | Trial credits | Pay-as-you-go after |

## Firewall Rules

For Coturn, open these ports:

| Port | Protocol | Purpose |
|---|---|---|
| `3478` | TCP + UDP | TURN / STUN |
| `5349` | TCP + UDP | TURN over TLS |
| `49152-65535` | UDP | TURN relay media ports |
