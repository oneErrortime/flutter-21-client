# 📞 VoiceCall — P2P E2E Encrypted Voice Calls

A production-ready Android voice call app with **WebRTC P2P** connections and **DTLS-SRTP end-to-end encryption**.

---

## 🏗️ Architecture Overview

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

### Two calling modes:

| Mode | How it works | When to use |
|------|-------------|-------------|
| **P2P (STUN)** | Direct peer connection via STUN NAT traversal | Same network / simple NAT |
| **P2P (TURN relay)** | Audio relayed via TURN server | Symmetric NAT / corporate firewalls |

The server **never handles audio** — it only brokers the connection setup (signaling). All audio is encrypted end-to-end with **DTLS-SRTP** (RFC 5764).

### Relevant RFCs / Standards:
- **RFC 8825** — WebRTC overview
- **RFC 8829** — JSEP (JavaScript Session Establishment Protocol)  
- **RFC 8445** — ICE (Interactive Connectivity Establishment)
- **RFC 5389** — STUN
- **RFC 8656** — TURN
- **RFC 5764** — DTLS-SRTP (E2E encryption)
- **RFC 4566** — SDP (Session Description Protocol)
- **RFC 7519** — JWT (auth tokens)
- **RFC 6749** — OAuth2 token refresh pattern

---

## 📁 Project Structure

```
/
├── lib/                          # Flutter client
│   ├── core/constants.dart       # ICE servers, URLs, keys
│   ├── models/models.dart        # Data models
│   ├── services/
│   │   ├── api_service.dart      # REST API with JWT auto-refresh
│   │   ├── auth_service.dart     # Auth state management
│   │   ├── signaling_service.dart # WebSocket signaling (WS layer)
│   │   └── webrtc_service.dart   # RTCPeerConnection, ICE, DTLS
│   └── screens/
│       ├── auth/                 # Login, Register
│       ├── home/                 # User ID, search, call actions
│       └── call/                 # Incoming, Active call screens
├── android/
│   └── app/src/main/
│       ├── AndroidManifest.xml   # Permissions, deep links
│       └── res/xml/network_security_config.xml
└── server/                       # Node.js signaling + REST server
    ├── src/
    │   ├── index.js              # Express + WebSocket server
    │   ├── models/User.js        # MongoDB user model
    │   ├── routes/auth.js        # Register / Login / Refresh
    │   ├── routes/users.js       # User lookup
    │   ├── routes/rooms.js       # Room links
    │   └── signaling/signalingServer.js  # WebRTC signaling handler
    ├── docker-compose.yml
    └── nginx.conf                # SSL termination + WS proxy
```

---

## 🚀 Quick Start (Server)

### Prerequisites
- Node.js 18+
- MongoDB (local or Atlas free tier)
- Docker + Docker Compose (optional but recommended)

### 1. Local Development

```bash
cd server
cp .env.example .env
# Edit .env — set MONGODB_URI and JWT secrets

npm install
npm run dev
```

Server runs at `http://localhost:3000`.  
WebSocket at `ws://localhost:3000/ws`.

### 2. Production with Docker

```bash
cd server
cp .env.example .env
# Edit .env — strong JWT secrets, MongoDB URI, TURN credentials

docker-compose up -d
```

### 3. Generate Strong JWT Secrets

```bash
openssl rand -hex 64  # for JWT_ACCESS_SECRET
openssl rand -hex 64  # for JWT_REFRESH_SECRET
```

---

## 📱 Quick Start (Flutter)

### 1. Configure Server URL

Edit `lib/core/constants.dart`:

```dart
// For emulator (Android emulator → your machine's localhost):
static const String baseUrl = 'http://10.0.2.2:3000';
static const String wsUrl = 'ws://10.0.2.2:3000/ws';

// For physical device on same WiFi:
// static const String baseUrl = 'http://192.168.1.x:3000';

// For production:
// static const String baseUrl = 'https://yourapp.com';
// static const String wsUrl = 'wss://yourapp.com/ws';
```

### 2. Install Flutter dependencies

```bash
flutter pub get
```

### 3. Run on emulator

```bash
flutter run
```

---

## 📱 How to Emulate WITHOUT Bricking Your Phone

### Option A: Android Studio Emulator (RECOMMENDED — 100% safe)

This runs in a **virtual machine** on your PC. Your real phone is never involved.

```bash
# 1. Install Android Studio
# https://developer.android.com/studio

# 2. Open Android Studio → Device Manager → Create Virtual Device
#    Recommended: Pixel 6 API 34 (Android 14)
#    Make sure to choose a "Play Store" image for full Google services

# 3. Start emulator then run Flutter:
flutter run

# Key: 10.0.2.2 in the emulator = localhost on your PC
# So your server at localhost:3000 is accessible at 10.0.2.2:3000 from emulator
```

### Option B: Genymotion (faster emulator, free for personal use)

```bash
# 1. Download from https://www.genymotion.com/
# 2. Create a virtual device
# 3. flutter run will detect it
```

### Option C: Physical Device (safe if done correctly)

```bash
# 1. Enable Developer Mode on your phone:
#    Settings → About Phone → tap "Build Number" 7 times

# 2. Enable USB Debugging:
#    Settings → Developer Options → USB Debugging → ON

# 3. Connect via USB, accept the trust prompt

# 4. Check device is detected:
adb devices

# 5. Run:
flutter run

# ⚠️  Safe practices:
# - flutter run installs a DEBUG APK — it's a normal app, won't break anything
# - You can uninstall it like any app
# - DO NOT run `adb` commands you don't understand
# - DO NOT unlock bootloader (that can brick) — flutter run doesn't need it
```

### Option D: Test two clients simultaneously

```bash
# Terminal 1: Run on emulator
flutter run -d emulator-5554

# Terminal 2: Run on physical device  
flutter run -d your-device-id

# Or use two emulators:
# In Android Studio: Device Manager → Start two different virtual devices
flutter run -d emulator-5554  # in terminal 1
flutter run -d emulator-5556  # in terminal 2
```

---

## 🔒 Security Features

### Authentication
- **JWT Access Tokens** (15-minute expiry) + **Refresh Tokens** (30-day expiry)
- **Token rotation**: Refresh tokens are single-use, rotated on every refresh
- **Refresh token reuse detection**: If a reused refresh token is detected, all sessions are invalidated
- **Bcrypt password hashing** with cost factor 12
- **Rate limiting**: 10 auth attempts per 15 minutes per IP

### Call Encryption
- **DTLS-SRTP** (RFC 5764): All audio is end-to-end encrypted
- WebRTC enforces DTLS by default — the server **cannot** decrypt calls
- **DTLS fingerprints** displayed in-app for manual verification (TOFU — Trust On First Use)

### Android Security
- **Encrypted SharedPreferences** via `flutter_secure_storage` (Android Keystore)
- **Certificate pinning** template in `network_security_config.xml`
- No cleartext traffic to production domains
- `allowBackup="false"` — prevents credential extraction via ADB backup

### Server Security
- Helmet.js security headers
- CORS whitelist
- Rate limiting per endpoint
- MongoDB injection prevention (Mongoose)
- Payload size limits (10KB)
- Non-root Docker container
- WebSocket authentication before any operations

---

## 🌐 TURN Server Setup (for calls through firewalls)

For production calls through corporate NAT/firewalls, deploy Coturn:

```bash
# Ubuntu/Debian
apt install coturn

# /etc/turnserver.conf
listening-port=3478
tls-listening-port=5349
realm=yourapp.com
server-name=yourapp.com
fingerprint
lt-cred-mech
user=turnuser:strongpassword
cert=/path/to/cert.pem
pkey=/path/to/key.pem
log-file=/var/log/coturn/turn.log
```

Update `lib/core/constants.dart` with your TURN credentials.  
Free alternative: [Metered.ca](https://www.metered.ca/) has a free TURN tier.

---

## 🔗 Deep Links / Call by Link

Users can create call rooms and share links:

```
voicecall://join/ROOM-UUID
https://yourapp.com/join/ROOM-UUID
```

Links expire after 24 hours. The room creator waits, the joiner sends the WebRTC offer.

## 🆔 Call by User ID

Each user has a unique UUID shown in the home screen. Copy & paste to call directly.

---

## 📡 WebSocket Signaling Protocol

### Client → Server
| Message | Purpose |
|---------|---------|
| `auth` | Authenticate WS connection with JWT |
| `call` | Send WebRTC offer to a user by ID |
| `answer` | Send WebRTC answer |
| `ice` | Send ICE candidate (RFC 8445) |
| `hangup` | End call |
| `decline` | Decline incoming call |
| `create-room` | Create shareable room link |
| `join-room` | Join room with offer |
| `room-host` | Register as room host |
| `room-answer` | Answer joiner in a room |
| `room-ice` | ICE candidates for room mode |
| `heartbeat` | Keep connection alive |

### Server → Client
| Message | Purpose |
|---------|---------|
| `auth-success` | Authentication confirmed |
| `call-incoming` | Incoming call with SDP offer |
| `call-answered` | Remote answered with SDP answer |
| `call-declined` | Remote declined |
| `ice` | Remote ICE candidate |
| `hangup` | Remote ended call |
| `user-offline` | Target user not connected |
| `user-busy` | Target user in another call |
| `room-created` | Room + link created |
| `room-joined` | Someone joined your room |
| `room-answered` | Room host answered |
| `session-replaced` | New login replaced this session |

---

## 🛠️ REST API

### Auth
| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/auth/register` | Register user |
| `POST` | `/api/auth/login` | Login, returns tokens |
| `POST` | `/api/auth/refresh` | Refresh access token |
| `POST` | `/api/auth/logout` | Revoke refresh token |
| `GET` | `/api/auth/me` | Current user info |

### Users
| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/users/:userId` | Get user by ID |
| `GET` | `/api/users/search?q=` | Search by username |

### Rooms
| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/rooms` | Create room link |
| `GET` | `/api/rooms/:roomId` | Validate room |

---

## 📊 Deployment Checklist

- [ ] Generate strong JWT secrets (`openssl rand -hex 64`)
- [ ] Set up MongoDB Atlas or self-hosted MongoDB with auth
- [ ] Deploy Coturn or configure Metered.ca TURN
- [ ] Get SSL certificate (Let's Encrypt via certbot)
- [ ] Update `nginx.conf` with your domain
- [ ] Update `constants.dart` with production URLs
- [ ] Update `AndroidManifest.xml` deep link domain
- [ ] Update `network_security_config.xml` domain
- [ ] Set `ALLOWED_ORIGINS` to your app's domain
- [ ] Enable `android:usesCleartextTraffic="false"` for release
- [ ] Consider certificate pinning in `network_security_config.xml`
- [ ] Test calls on real devices across different networks
