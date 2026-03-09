# Introduction

**VoiceCall** is a production-ready Android voice and video call application built with Flutter, providing end-to-end encrypted peer-to-peer communication.

## What is VoiceCall?

VoiceCall combines a Flutter client with a Node.js signaling server (and an alternative Rust backend) to enable direct peer-to-peer communication. The signaling server only brokers the connection — once established, all media flows directly between devices, encrypted end-to-end.

## Key Properties

| Property | Detail |
|---|---|
| **Client** | Flutter 3.13+ (Android) |
| **Signaling** | Node.js + WebSocket / Rust alternative |
| **P2P Transport** | WebRTC (ICE/STUN/TURN) |
| **Encryption** | DTLS-SRTP (RFC 5764) |
| **Auth** | JWT with rotating refresh tokens |
| **Database** | MongoDB |

## Feature Highlights

- **End-to-End Encrypted** — DTLS-SRTP ensures the signaling server cannot decrypt audio
- **P2P Direct** — Audio bypasses the server entirely via ICE/STUN traversal
- **TURN Fallback** — Relay mode for symmetric NAT / corporate firewalls
- **Deep Links** — Share call rooms via `voicecall://join/ROOM-UUID`
- **Rust Backend** — Alternative high-performance signaling server in Rust
- **QUIC/Noise Architecture** — Experimental next-gen transport (see [QUIC + Noise Protocol](/docs?name=QUIC+Noise+Architecture))

## Project Repositories

The project consists of code in a single repository:

```
flutter-21-client/
├── lib/          # Flutter/Dart client
├── server/       # Node.js signaling server
└── server-rust/  # Rust signaling server (alternative)
```

## Standards & RFCs

VoiceCall is built on open standards:

- **RFC 8825** — WebRTC Overview
- **RFC 8829** — JSEP (Session Establishment)
- **RFC 8445** — ICE (Interactive Connectivity Establishment)
- **RFC 5389** — STUN
- **RFC 8656** — TURN
- **RFC 5764** — DTLS-SRTP (E2E encryption)
- **RFC 4566** — SDP
- **RFC 7519** — JWT
- **RFC 9605** — SFrame (referenced in QUIC/Noise architecture)
