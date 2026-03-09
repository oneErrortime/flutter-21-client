# Security

VoiceCall is built with security as a primary constraint, not an afterthought.

## Authentication

| Feature | Implementation |
|---|---|
| Access tokens | JWT, 15-minute expiry |
| Refresh tokens | JWT, 30-day expiry, **single-use with rotation** |
| Reuse detection | Reused refresh token → all sessions invalidated |
| Password hashing | Bcrypt, cost factor 12 |
| Rate limiting | 10 auth attempts / 15 min / IP |
| Session storage | Android Keystore via `flutter_secure_storage` |

### Token Rotation Flow

```
Client                          Server
  │── POST /auth/refresh ───────►│
  │      { refreshToken: R1 }    │  R1 valid → issue R2 + new access token
  │◄── { accessToken, R2 } ──────│  R1 marked consumed
  │                              │
  │── POST /auth/refresh ───────►│  (attacker reuses R1)
  │      { refreshToken: R1 }    │  R1 already consumed → REVOKE ALL SESSIONS
  │◄── 401 Unauthorized ─────────│
```

## Call Encryption

All audio is **end-to-end encrypted** with DTLS-SRTP (RFC 5764).

- WebRTC enforces DTLS by default — there is no cleartext fallback
- The signaling server **cannot** decrypt calls
- DTLS fingerprints are displayed in-app for manual key verification (TOFU — Trust On First Use)

```
Caller RTCPeerConnection ──── DTLS handshake ──── Callee RTCPeerConnection
              │                                              │
              └──────── SRTP encrypted audio frames ────────┘
                          (server sees nothing)
```

## Android Security

| Feature | Implementation |
|---|---|
| Token storage | `flutter_secure_storage` → Android Keystore |
| Certificate pinning | Template in `network_security_config.xml` |
| Cleartext traffic | Blocked for production domains |
| ADB backup | `allowBackup="false"` — prevents credential extraction |
| Debug APK | All cryptographic keys regenerated for release builds |

## Server Security

| Layer | Measure |
|---|---|
| HTTP headers | Helmet.js security defaults |
| CORS | Explicit origin whitelist |
| Rate limiting | Per-endpoint limits |
| Input validation | Mongoose schema validation (injection prevention) |
| Payload size | 10 KB limit |
| Container | Non-root Docker user |
| WebSocket | JWT authentication required before any operation |

## Threat Model

| Threat | Mitigation |
|---|---|
| MITM on signaling | WSS (TLS) required in production; DTLS fingerprint verification |
| Compromised server | DTLS-SRTP: server cannot decrypt media |
| Token theft | Short access token TTL (15 min); Keystore storage |
| Session hijack | Refresh token rotation + reuse detection |
| Credential brute force | Rate limiting + bcrypt cost 12 |
| ADB token extraction | `allowBackup=false` + Keystore |
