# Architecture

VoiceCall uses a standard WebRTC signaling architecture: a lightweight server handles connection negotiation, while all media flows peer-to-peer.

## System Diagram

```
┌──────────────┐         WSS/HTTPS          ┌─────────────────────┐
│ Android App  │ ◄──────────────────────── ► │  Signaling Server   │
│  (Flutter)   │     JWT-authenticated       │  (Node.js + WS)     │
└──────┬───────┘         WebSocket          └────────┬────────────┘
       │                                              │ MongoDB
       │         Direct P2P (ICE/STUN/TURN)           │
       └──────────────────────────────────────────────┘
                  DTLS-SRTP encrypted audio
```

The server **never handles audio** — it only brokers the WebRTC handshake (SDP offer/answer and ICE candidates).

## Call Flow

```
Caller                    Signaling Server               Callee
  │                             │                          │
  │── auth (JWT) ──────────────►│◄──────────── auth (JWT) ─│
  │                             │                          │
  │── call { offer: SDP } ─────►│── call-incoming ────────►│
  │                             │                          │
  │◄──────────────── call-answered { answer: SDP } ────────│
  │                             │                          │
  │── ice { candidate } ───────►│── ice ──────────────────►│
  │◄─────────────────────────── ice { candidate } ─────────│
  │                             │                          │
  │◄════════ DTLS-SRTP encrypted P2P audio ════════════════►│
```

## Two Calling Modes

| Mode | Transport | When to use |
|------|-----------|-------------|
| **P2P (STUN)** | Direct via STUN NAT traversal | Same network / simple NAT |
| **P2P (TURN relay)** | Audio relayed via TURN server | Symmetric NAT / corporate firewalls |

## Component Overview

### Flutter Client (`lib/`)

| File | Responsibility |
|------|---------------|
| `services/webrtc_service.dart` | RTCPeerConnection, ICE negotiation, DTLS handshake |
| `services/signaling_service.dart` | WebSocket connection, message routing |
| `services/api_service.dart` | REST calls with JWT auto-refresh |
| `services/auth_service.dart` | Auth state, token storage (Keystore) |
| `screens/call/` | Incoming call UI, active call UI |
| `core/constants.dart` | ICE servers, base URLs, feature flags |

### Node.js Server (`server/src/`)

| File | Responsibility |
|------|---------------|
| `index.js` | Express + WebSocket server bootstrap |
| `signaling/signalingServer.js` | WebRTC signaling state machine |
| `routes/auth.js` | Register / Login / Refresh / Logout |
| `routes/users.js` | User lookup & search |
| `routes/rooms.js` | Shareable room link management |
| `models/User.js` | MongoDB user schema |

### Rust Server (`server-rust/src/`)

Alternative high-performance backend with identical protocol support.

| File | Responsibility |
|------|---------------|
| `main.rs` | Tokio async runtime, server bootstrap |
| `signaling/` | WebSocket signaling handlers |
| `routes/` | Auth, users, rooms endpoints |
| `db/` | MongoDB async driver integration |
| `metrics/` | Prometheus metrics |
| `crypto/` | JWT, bcrypt primitives |
