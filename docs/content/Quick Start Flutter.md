# Quick Start — Flutter

## Prerequisites

- Flutter 3.13+ with Dart SDK ≥ 3.1.0
- Android Studio or VS Code with Flutter extension
- A running [signaling server](/docs?name=Quick+Start+Server)

## 1. Configure Server URL

Edit `lib/core/constants.dart`:

```dart
// Android emulator → your machine's localhost
static const String baseUrl = 'http://10.0.2.2:3000';
static const String wsUrl   = 'ws://10.0.2.2:3000/ws';

// Physical device on the same WiFi
// static const String baseUrl = 'http://192.168.1.x:3000';

// Production
// static const String baseUrl = 'https://yourapp.com';
// static const String wsUrl   = 'wss://yourapp.com/ws';
```

> `10.0.2.2` is the Android emulator's alias for the host machine's `localhost`.

## 2. Install Dependencies

```bash
flutter pub get
```

## 3. Run

```bash
flutter run
```

Flutter will detect connected devices and emulators automatically.

## Key Dependencies

| Package | Purpose |
|---|---|
| `flutter_webrtc ^0.9.48` | RTCPeerConnection, ICE, DTLS-SRTP |
| `dio ^5.3.4` | HTTP client with interceptors |
| `web_socket_channel ^2.4.0` | WebSocket signaling connection |
| `flutter_secure_storage ^9.0.0` | Android Keystore token storage |
| `provider ^6.1.1` | Auth and call state management |
| `go_router ^12.1.3` | Deep link routing |
| `firebase_messaging ^14.7.9` | Background push notifications |

## Device Emulation

See the [Device Emulation](/docs?name=Device+Emulation) guide for detailed setup including running two clients simultaneously to test calls.
