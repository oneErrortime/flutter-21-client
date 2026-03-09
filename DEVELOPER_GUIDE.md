# Developer Guide

Everything you need to build, run, test and debug the VoiceCall app.

---

## 1. Quick-start (local development)

### Prerequisites

| Tool | Min version | Install |
|------|-------------|---------|
| Flutter | 3.22+ | `flutter.dev` |
| Dart | 3.4+ | bundled with Flutter |
| Rust | 1.77+ stable | `rustup.rs` |
| Docker & Compose | any recent | `docker.com` |
| Android Studio / Xcode | latest | for device builds |

---

### 1.1 Start the Rust signaling server

```bash
cd server-rust
cp .env.example .env           # edit DATABASE_URL, JWT secrets, etc.
docker compose up -d           # starts Postgres + Redis
cargo run                      # starts server on :3000
```

The server exposes:
- `ws://localhost:3000/ws` — WebSocket signaling
- `http://localhost:3000/api/` — REST (auth, users, rooms)
- `http://localhost:3000/health` — healthcheck
- `http://localhost:3000/metrics` — Prometheus metrics

### 1.2 Configure the Flutter app

Edit `lib/core/constants.dart`:

```dart
// Android emulator → host machine
static const String baseUrl = 'http://10.0.2.2:3000';
static const String wsUrl   = 'ws://10.0.2.2:3000/ws';

// Physical device on same Wi-Fi (replace with your machine's IP)
static const String baseUrl = 'http://192.168.1.42:3000';
static const String wsUrl   = 'ws://192.168.1.42:3000/ws';
```

### 1.3 Run on Android emulator

```bash
flutter pub get
flutter devices            # confirm emulator is running
flutter run -d emulator-1  # hot-reload enabled
```

### 1.4 Run on physical Android device

1. Enable **Developer Options** → **USB Debugging** on the device.
2. `flutter devices` — confirm device appears.
3. `flutter run -d <device-id>`.

### 1.5 Run on iOS simulator

```bash
open -a Simulator
flutter run -d iPhone      # Xcode + CocoaPods required
```

---

## 2. Building release APKs

### 2.1 GitHub Actions (recommended)

Push a tag to trigger a release build:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow (`.github/workflows/build.yml`) will:
- Build `arm64-v8a`, `armeabi-v7a`, `x86_64` APKs
- Build an App Bundle (AAB) for Play Store
- Create a GitHub Release with the APKs attached

### 2.2 Manual release APK

```bash
# Sign with your keystore (create one with keytool if you don't have it)
flutter build apk --release \
  --target-platform android-arm64 \
  --obfuscate \
  --split-debug-info=build/debug-info/
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

Transfer to device:
```bash
adb install build/app/outputs/flutter-apk/app-release.apk
```

### 2.3 App Bundle (Play Store)

```bash
flutter build appbundle --release
```

Output: `build/app/outputs/bundle/release/app-release.aab`

---

## 3. Deploying the Rust server

### 3.1 Docker Compose (quickest)

```bash
cd server-rust
docker compose up -d
```

`docker-compose.yml` starts:
- `voicecall-server` on port 3000
- `postgres:16` on 5432
- `redis:7` on 6379
- `prom/prometheus` on 9090 (optional)

### 3.2 GitHub Container Registry

Every push to `main` publishes:
```
ghcr.io/<your-org>/flutter-21-client/server:main
```

Use this image in production:

```yaml
# docker-compose.prod.yml
services:
  server:
    image: ghcr.io/<your-org>/flutter-21-client/server:v1.0.0
    environment:
      DATABASE_URL: postgres://user:pass@db/voicecall
      REDIS_URL: redis://redis:6379
      JWT_ACCESS_SECRET: <64-char-hex>
      JWT_REFRESH_SECRET: <64-char-hex>
      SIGNALING_SECRET: <32-byte-hex>
    ports:
      - "3000:3000"
```

### 3.3 Environment variables (server)

| Variable | Required | Description |
|----------|----------|-------------|
| `DATABASE_URL` | ✅ | PostgreSQL DSN |
| `REDIS_URL` | ✅ | Redis URL |
| `JWT_ACCESS_SECRET` | ✅ | 64-char hex secret |
| `JWT_REFRESH_SECRET` | ✅ | 64-char hex secret |
| `SIGNALING_SECRET` | ✅ | 32 bytes hex (AES-256-GCM key) |
| `PORT` | optional | Default 3000 |
| `ALLOWED_ORIGINS` | optional | CORS origins (comma-separated) |
| `TURN_URLS` | optional | TURN server URL |
| `TURN_USERNAME` | optional | TURN credential |
| `TURN_CREDENTIAL` | optional | TURN credential |

---

## 4. Debugging

### 4.1 Flutter debugging

**VS Code**: Install the Flutter extension → press F5 → choose device.

**Android Studio**: Run → Debug (auto-attaches Dart debugger).

**Command line** (verbose logs):
```bash
flutter run --verbose 2>&1 | tee flutter.log
```

**Dart DevTools** (performance, memory, network):
```bash
flutter run --observatory-port=50300
# open http://localhost:50300 in Chrome
```

**Inspect WebRTC internals on Android**:
1. Connect device via USB.
2. Open `chrome://inspect` in desktop Chrome.
3. Find "WebRTC Internals" → shows ICE candidates, codec stats, bitrates.

### 4.2 Server debugging

**Structured logs** (JSON):
```bash
RUST_LOG=voicecall_server=debug,tower_http=info cargo run 2>&1 | jq .
```

**Test WebSocket signaling** (the test script in repo):
```bash
cd server
node test_signaling.js
```

**Prometheus metrics**:
```bash
curl http://localhost:3000/metrics
```

Key metrics:
- `ws.connected_clients` — active WebSocket connections
- `ws.auth.success` — successful authentications
- `sfu.active_rooms` — active SFU rooms
- `sfu.room_join` / `sfu.room_leave` counters

### 4.3 Network debugging with Wireshark

To inspect DTLS/SRTP negotiation:
1. Run `flutter run` on device, observe IP.
2. Start Wireshark capture on your network interface.
3. Filter: `stun or dtls or srtp`
4. DTLS handshake appears as a sequence of `ClientHello`/`ServerHello`.

Note: SRTP payload is encrypted. You'll see RTP packets but not audio content.

### 4.4 Common issues

| Problem | Likely cause | Fix |
|---------|-------------|-----|
| ICE fails (no connection) | Symmetric NAT | Enable TURN servers in `constants.dart` |
| Remote video not showing | `onTrack` not firing | Check SDP has `a=recvonly` or `a=sendrecv` for video |
| WebSocket auth fails | Token expired | Ensure app calls `/api/auth/refresh` |
| App crashes on Android 14 | Missing permission | Add `FOREGROUND_SERVICE_MICROPHONE` to `AndroidManifest.xml` |
| `flutter pub get` fails | Pub cache stale | `flutter clean && flutter pub cache repair` |
| Rust build fails | Missing OpenSSL | `sudo apt install pkg-config libssl-dev` |

---

## 5. Running tests

### Flutter
```bash
flutter test                              # unit tests
flutter test --coverage                   # with coverage
genhtml coverage/lcov.info -o coverage/html  # HTML coverage report
```

### Rust
```bash
cd server-rust
cargo test                                # unit + integration (needs DB)
cargo test --lib                          # unit tests only (no DB needed)
```

### Signaling end-to-end test
```bash
cd server
node test_signaling.js   # simulates two clients calling each other
```

---

## 6. Transport architecture

### Which transport is used when?

```
participantCount == 2 AND peer supports QUIC-Noise
  → TransportMode.quicNoise  (ultra-low latency, 1-RTT handshake)

participantCount == 2
  → TransportMode.webrtcTurn  (P2P via TURN, works everywhere)

participantCount >= 3 AND LiveKit available
  → TransportMode.livekit  (SFU + SFrame E2E, Zoom-like)

fallback
  → TransportMode.webrtcDirect  (STUN only, same network)
```

See `lib/services/livekit_service.dart` → `TransportSelector`.

### P2P + E2E alternatives to WebRTC

| Protocol | Latency | E2E | NAT Traversal | Status in repo |
|----------|---------|-----|----------------|----------------|
| **WebRTC** | ~100-200ms | DTLS-SRTP | ICE (STUN/TURN) | ✅ Implemented |
| **QUIC + Noise IK** | <50ms | ChaCha20-Poly1305 | Same as WebRTC | 🚧 Skeleton (needs Dart QUIC lib) |
| **LiveKit SFU + SFrame** | ~80ms | SFrame (RFC 9605) | Server-mediated | 🚧 Skeleton (add `livekit_client`) |
| **WebRTC SFU relay** | ~100ms | Optional (SFrame) | None (all via server) | 🚧 `sfu_relay.rs` (needs media server) |

### Enabling LiveKit (step-by-step)

1. Add `livekit_client: ^2.1.0` to `pubspec.yaml`.
2. Deploy a [LiveKit server](https://docs.livekit.io/realtime/self-hosting/local/) or use LiveKit Cloud.
3. Uncomment the LiveKit code in `lib/services/livekit_service.dart`.
4. Add server-side token generation (see comment at bottom of `livekit_service.dart`).
5. Call `LiveKitCallService.joinRoom()` from your call screen.

### Enabling QUIC + Noise (step-by-step)

1. Choose a QUIC binding:
   - **Android**: Cronet via `cronet_http` Flutter plugin.
   - **iOS**: custom Swift + `nwprotocol` QUIC support.
   - **Cross-platform**: watch `quic_dart` (not stable yet).
2. Replace the `TODO` comments in `lib/services/quic_noise_service.dart`.
3. Test with `quiche` CLI (`cloudflare/quiche` on GitHub) as a fake peer.
