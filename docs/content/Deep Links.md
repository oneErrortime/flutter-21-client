# Deep Links

VoiceCall supports two call initiation methods: direct by User ID, and via shareable room links.

## Room Links

Create a room and share a link. The room expires after **24 hours**.

```
voicecall://join/ROOM-UUID         ← native deep link
https://yourapp.com/join/ROOM-UUID ← HTTPS universal link
```

### Flow

```
Creator                  Server                    Joiner
  │── create-room ───────►│                          │
  │◄── room-created ───────│ { roomId, link }         │
  │                        │                          │
  │   [shares link] ──────────────────────────────── │
  │                        │                          │
  │── room-host ───────────►│         join-room ◄─────│
  │                        │                          │
  │◄── room-joined ─────────│ { joinerId, offer: SDP } │
  │── room-answer ─────────►│── room-answered ────────►│
  │◄══════════ DTLS-SRTP P2P audio ══════════════════►│
```

## Call by User ID

Every user has a stable UUID shown on the home screen. Copy it and dial directly — no link needed.

```dart
// Home screen displays:
Text('Your ID: ${authService.currentUser.userId}')
```

## Android Deep Link Configuration

Configured in `android/app/src/main/AndroidManifest.xml`:

```xml
<intent-filter android:autoVerify="true">
  <action android:name="android.intent.action.VIEW" />
  <category android:name="android.intent.category.DEFAULT" />
  <category android:name="android.intent.category.BROWSABLE" />

  <!-- HTTPS universal link -->
  <data android:scheme="https"
        android:host="yourapp.com"
        android:pathPrefix="/join/" />

  <!-- Custom scheme -->
  <data android:scheme="voicecall"
        android:host="join" />
</intent-filter>
```

Update `yourapp.com` to your actual domain before release.

## Handling Links in Flutter

```dart
// In main.dart or app router
appLinks.uriLinkStream.listen((uri) {
  if (uri.pathSegments.first == 'join') {
    final roomId = uri.pathSegments.last;
    router.go('/join/$roomId');
  }
});
```
