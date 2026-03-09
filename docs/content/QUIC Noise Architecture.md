# QUIC + Noise Architecture

> **Status: Experimental** — This document describes an alternative transport architecture to WebRTC, optimized for the lowest possible latency. It is implemented alongside the existing WebRTC stack.

---

## Why Not Just WebRTC?

WebRTC is the industry standard for browser-based P2P media. On mobile, however, it carries significant overhead:

| Issue | WebRTC | QUIC + Noise |
|---|---|---|
| Handshake RTTs | 4–6 RTT (ICE + DTLS 1.2) | 1 RTT (Noise IK) / 0 RTT (resume) |
| Protocol complexity | ICE, SDP, JSEP, DTLS, SRTP | QUIC streams + Noise frames |
| NAT traversal | ICE (STUN + TURN) | QUIC + STUN / TURN relay |
| Key verification | DTLS fingerprint (manual TOFU) | Noise static public keys (cryptographic identity) |
| Group calls | Mesh (N²) or SFU required | SFU with SFrame E2E (RFC 9605) |
| Library size (Android) | ~15 MB (libwebrtc) | ~1.5 MB (quinn + noise-rust) |

For a **"very fast, like Zoom"** experience, the right answer depends on the scenario:

| Scenario | Best approach |
|---|---|
| 2-party call, P2P | QUIC + Noise IK |
| Group call (3–100 people) | LiveKit SFU + SFrame E2E |
| Existing codebase migration | WebRTC + SFrame upgrade |

---

## Option 1: QUIC + Noise Protocol (Pure P2P, Ultra-Low Latency)

### What is the Noise Protocol Framework?

[Noise](https://noiseprotocol.org/) is a framework for building cryptographic protocols. WireGuard VPN and the Signal messaging protocol both use Noise. It provides:

- **Authenticated key exchange** with forward secrecy
- **Static public keys** as cryptographic identities (like WireGuard peers)
- **No certificate authorities** — keys are exchanged out-of-band (via the signaling server)
- **1-RTT handshake** with the `IK` pattern (identity key known in advance)

### What is QUIC?

QUIC (RFC 9000) is the transport underlying HTTP/3. Key properties for media:

- **0-RTT connection resumption** — reconnect instantly after network change (WiFi → LTE)
- **No head-of-line blocking** — dropped audio frame doesn't block video stream
- **Built-in congestion control** — better than UDP + SCTP under WebRTC
- **Multiplexed streams** — audio, video, data channel on one connection
- **Connection migration** — keeps the call alive when the user changes networks

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Signaling Server                   │
│                                                      │
│  1. Exchange Noise static public keys (DH key pair)  │
│  2. Exchange QUIC connection hints (IP:port)         │
│  3. TURN relay fallback (if NAT traversal fails)     │
└──────────────────────┬──────────────────────────────┘
                       │ WSS (existing signaling)
          ┌────────────┴────────────┐
          │                         │
   ┌──────▼──────┐           ┌──────▼──────┐
   │  Flutter A  │           │  Flutter B  │
   │             │           │             │
   │  Noise IK   │◄─────────►│  Noise IK   │
   │  handshake  │  1 RTT    │  handshake  │
   │             │           │             │
   │  QUIC conn  │◄─────────►│  QUIC conn  │
   │  ├ stream 0 │  audio    │  ├ stream 0 │
   │  ├ stream 1 │  video    │  ├ stream 1 │
   │  └ stream 2 │  data     │  └ stream 2 │
   └─────────────┘           └─────────────┘
         All frames: Noise encrypted (ChaCha20-Poly1305)
```

### Noise Handshake Pattern: IK

The `IK` pattern is optimal for this use case: Bob's static key is **K**nown (retrieved from the signaling server), and **I**nitiator identity is hidden from passive observers.

```
Handshake:
  <- s               (Bob's static public key, known from server)
  ...
  -> e, es, s, ss    (Alice's ephemeral + static, DH operations)
  <- e, ee, se       (Bob's ephemeral, DH operations)

Result:
  - 1 RTT total
  - Forward secrecy via ephemeral keys
  - Alice's identity hidden from passive adversaries
  - Bob's identity authenticated
```

After the handshake, all frames use **ChaCha20-Poly1305** (AEAD).

### Flutter Implementation

#### Dependencies (`pubspec.yaml`)

```yaml
dependencies:
  # QUIC transport (dart FFI wrapper around quinn)
  quic_dart: ^0.2.0          # or use raw UDP + custom QUIC
  
  # Noise Protocol
  noise_protocol: ^1.0.0     # Dart implementation
  
  # Opus audio codec
  opus_dart: ^2.1.0
  
  # H.264 / VP8 video (if adding video)
  camera: ^0.10.5
```

#### Key Exchange via Signaling

```dart
class NoiseService {
  late KeyPair _staticKeyPair;
  
  Future<void> init() async {
    // Generate or load persistent static key pair (stored in Keystore)
    _staticKeyPair = await _loadOrGenerateKeyPair();
  }
  
  // Called when initiating a call
  Future<NoiseSession> initiateCall(String remotePublicKeyBase64) async {
    final remoteKey = base64.decode(remotePublicKeyBase64);
    
    // Noise IK pattern: we know remote's static key
    final handshake = NoiseHandshake.initiator(
      pattern: HandshakePattern.IK,
      staticKey: _staticKeyPair,
      remoteStaticKey: remoteKey,
    );
    
    return NoiseSession(handshake);
  }
  
  String get publicKeyBase64 => base64.encode(_staticKeyPair.publicKey);
}
```

#### QUIC Connection with Noise Framing

```dart
class QuicNoiseTransport {
  late QuicConnection _conn;
  late NoiseSession _noise;
  
  // Audio stream (stream ID 0)
  late QuicStream _audioStream;
  
  Future<void> connect(String peerIp, int peerPort, NoiseSession noise) async {
    _noise = noise;
    _conn = await QuicConnection.connect(peerIp, peerPort);
    _audioStream = await _conn.openBidirectionalStream(id: 0);
    
    // Perform Noise IK handshake over QUIC stream 0
    await _performHandshake();
  }
  
  Future<void> sendAudioFrame(Uint8List opusFrame) async {
    // Noise encrypt: ChaCha20-Poly1305 AEAD
    final encrypted = _noise.encrypt(opusFrame);
    
    // QUIC framing: 2-byte length prefix + payload
    final frame = ByteData(2 + encrypted.length)
      ..setUint16(0, encrypted.length, Endian.big);
    frame.buffer.asUint8List(2).setAll(0, encrypted);
    
    await _audioStream.write(frame.buffer.asUint8List());
  }
  
  Stream<Uint8List> get audioFrames => _audioStream.incoming.map((bytes) {
    // Noise decrypt
    return _noise.decrypt(bytes.sublist(2));
  });
}
```

#### Signaling Extension (new message types)

Add to the WebSocket signaling protocol:

```json
// Share Noise public key when registering
{
  "type": "auth",
  "token": "JWT...",
  "noisePublicKey": "base64-encoded-X25519-public-key"
}

// Include Noise public key in call offer
{
  "type": "call-quic",
  "targetUserId": "uuid",
  "noisePublicKey": "base64...",
  "quicEndpoint": "1.2.3.4:50000"
}
```

### Server-side Changes

Add to `server/src/models/User.js`:

```javascript
noisePublicKey: {
  type: String,
  required: false,
  maxlength: 64  // 32 bytes base64
}
```

Add to `server/src/signaling/signalingServer.js`:

```javascript
// Store Noise public key on auth
case 'auth':
  user.noisePublicKey = data.noisePublicKey;
  // ... existing auth logic

// New call type: forward QUIC endpoint + Noise key
case 'call-quic':
  const target = connectedUsers.get(data.targetUserId);
  if (target) {
    target.send(JSON.stringify({
      type: 'call-quic-incoming',
      callerId: user.id,
      noisePublicKey: user.noisePublicKey,
      quicEndpoint: data.quicEndpoint
    }));
  }
```

---

## Option 2: LiveKit SFU + SFrame (Zoom-like Group Calls)

For **group calls with E2E encryption** — the architecture Zoom, Google Meet, and Cloudflare Calls use.

### What is SFrame?

[SFrame (RFC 9605)](https://www.rfc-editor.org/rfc/rfc9605) is an E2E encryption layer for media **on top of** SFU infrastructure. The SFU can forward encrypted frames without decrypting them.

```
Alice ──[Encrypt(frame, K_alice)]──► SFU ──[Forward]──► Bob
                                      │                  │
                                      │                  └─ Decrypt(frame, K_alice)
                                      │                      (Bob has K_alice via MLS)
                                      └─ Cannot decrypt (doesn't have K_alice)
```

### What is LiveKit?

[LiveKit](https://livekit.io/) is an open-source, self-hostable SFU with a Flutter SDK. It handles:

- WebRTC SFU (media forwarding at scale)
- Selective forwarding (simulcast, bandwidth adaptation)
- Room management
- E2E encryption via SFrame

### Architecture

```
┌─────────────────────────────────────────┐
│              LiveKit Server             │
│                                         │
│  ┌─────────┐   ┌─────────┐             │
│  │  Room   │   │  Room   │             │
│  │  A-B-C  │   │  D-E    │  ...        │
│  └─────────┘   └─────────┘             │
│                                         │
│  Media: SFU forwarding (no decryption)  │
│  Keys:  MLS key distribution            │
└───────────────┬─────────────────────────┘
                │
     ┌──────────┼──────────┐
     │          │          │
 Flutter A  Flutter B  Flutter C
     │          │          │
     └──────────┴──────────┘
        SFrame E2E encrypted
        (each client holds MLS epoch key)
```

### Flutter Integration

```yaml
dependencies:
  livekit_client: ^2.1.0
```

```dart
class LiveKitCallService {
  Room? _room;
  
  Future<void> joinRoom(String roomToken, String serverUrl) async {
    _room = Room();
    
    // Connect with E2E encryption enabled
    await _room!.connect(
      serverUrl,
      roomToken,
      roomOptions: const RoomOptions(
        // Enable SFrame E2E encryption
        e2eeOptions: E2EEOptions(
          keyProvider: SharedKeyKeyProvider(
            sharedKey: 'your-derived-room-key',
          ),
        ),
        defaultAudioPublishOptions: AudioPublishOptions(
          audioBitrate: 32000,  // Opus 32kbps — Zoom-quality voice
          dtx: true,            // Discontinuous transmission (silence suppression)
        ),
        defaultVideoPublishOptions: VideoPublishOptions(
          simulcast: true,      // Multiple quality layers
          videoEncoding: VideoEncoding(
            maxBitrate: 1200000, // 1.2 Mbps for 720p
            maxFramerate: 30,
          ),
        ),
      ),
    );
    
    // Publish microphone
    await _room!.localParticipant?.setMicrophoneEnabled(true);
  }
  
  Future<void> enableVideo() async {
    await _room!.localParticipant?.setCameraEnabled(true);
  }
  
  Future<void> leaveRoom() async {
    await _room?.disconnect();
  }
}
```

### Self-host LiveKit

```bash
# Docker
docker run --rm \
  -p 7880:7880 \
  -p 7881:7881 \
  -p 7882:7882/udp \
  -v $PWD/livekit.yaml:/livekit.yaml \
  livekit/livekit-server \
  --config /livekit.yaml \
  --dev
```

```yaml
# livekit.yaml
port: 7880
rtc:
  tcp_port: 7881
  udp_port: 7882
  use_external_ip: true
keys:
  APIkey: APIsecret
```

---

## Comparison

| | WebRTC (current) | QUIC + Noise | LiveKit + SFrame |
|---|---|---|---|
| **Parties** | 2 | 2 | 2–100+ |
| **Latency** | ~150–400ms | ~50–150ms | ~80–200ms |
| **E2E Encryption** | DTLS-SRTP | Noise ChaCha20-Poly1305 | SFrame AES-128-GCM |
| **Key verification** | DTLS fingerprint | Static X25519 key | MLS epoch key |
| **NAT traversal** | ICE/STUN/TURN | QUIC + STUN/TURN | LiveKit handles it |
| **Network migration** | Reconnect required | QUIC seamless | WebRTC reconnect |
| **Library size** | ~15 MB | ~1.5 MB | ~3 MB |
| **Flutter SDK** | `flutter_webrtc` | Custom / `quic_dart` | `livekit_client` |
| **Group video** | Complex mesh | Not designed for | Native SFU |
| **Self-hostable** | Yes (signaling) | Yes | Yes |

## Recommended Path

```
Current:   WebRTC P2P (implemented)
                │
      ┌─────────┴─────────┐
      │                   │
  2-party calls      Group calls (3+)
  ultra-low latency  Zoom-like experience
      │                   │
  QUIC + Noise IK     LiveKit + SFrame
  (1 RTT, 50ms)       (SFU, E2E via RFC 9605)
```

Both can **coexist** — the signaling server routes call requests to the appropriate transport based on participant count or user preference.

---

## Implementation Files

The QUIC/Noise implementation lives in:

```
lib/
  services/
    quic_noise_service.dart      # Noise key management + QUIC transport
    livekit_service.dart         # LiveKit room management
  models/
    transport_type.dart          # Enum: WEBRTC | QUIC_NOISE | LIVEKIT

server/src/
  signaling/
    signalingServer.js           # Extended with call-quic message types
  models/
    User.js                      # noisePublicKey field added
```
