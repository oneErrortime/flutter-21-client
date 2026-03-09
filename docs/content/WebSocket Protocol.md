# WebSocket Protocol

All real-time signaling happens over an authenticated WebSocket connection at `wss://yourserver.com/ws`.

## Authentication

Before any messages can be exchanged, the client must authenticate:

```json
{
  "type": "auth",
  "token": "<JWT access token>"
}
```

Server responds with:

```json
{ "type": "auth-success", "userId": "uuid" }
```

Unauthenticated connections are closed after 5 seconds.

## Client → Server Messages

| Type | Payload | Description |
|---|---|---|
| `auth` | `{ token }` | Authenticate with JWT |
| `call` | `{ targetUserId, offer: SDP }` | Send WebRTC offer to user |
| `answer` | `{ callerId, answer: SDP }` | Send WebRTC answer |
| `ice` | `{ targetId, candidate }` | Send ICE candidate (RFC 8445) |
| `hangup` | `{ targetId }` | End active call |
| `decline` | `{ callerId }` | Decline incoming call |
| `create-room` | `{}` | Create shareable room link |
| `join-room` | `{ roomId, offer: SDP }` | Join room with WebRTC offer |
| `room-host` | `{ roomId }` | Register as room host |
| `room-answer` | `{ roomId, answer: SDP }` | Answer a room joiner |
| `room-ice` | `{ roomId, candidate }` | ICE candidates for room mode |
| `heartbeat` | `{}` | Keep-alive ping (every 30s) |

## Server → Client Messages

| Type | Payload | Description |
|---|---|---|
| `auth-success` | `{ userId }` | Authentication confirmed |
| `call-incoming` | `{ callerId, offer: SDP }` | Incoming call |
| `call-answered` | `{ calleeId, answer: SDP }` | Remote answered |
| `call-declined` | `{ calleeId }` | Remote declined |
| `ice` | `{ fromId, candidate }` | Remote ICE candidate |
| `hangup` | `{ fromId }` | Remote ended call |
| `user-offline` | `{ userId }` | Target user not connected |
| `user-busy` | `{ userId }` | Target user in another call |
| `room-created` | `{ roomId, link }` | Room created with shareable link |
| `room-joined` | `{ roomId, joinerId, offer: SDP }` | Someone joined your room |
| `room-answered` | `{ roomId, answer: SDP }` | Room host answered |
| `session-replaced` | `{}` | New login displaced this session |

## State Machine

```
IDLE
  │
  ├─ outgoing call ──► CALLING
  │                       │
  │                       ├─ answered ──► CONNECTED
  │                       ├─ declined ──► IDLE
  │                       └─ timeout  ──► IDLE
  │
  └─ incoming call ──► RINGING
                          │
                          ├─ accepted ──► CONNECTED
                          └─ declined ──► IDLE

CONNECTED
  └─ hangup (either side) ──► IDLE
```

## Message Framing

All messages are UTF-8 JSON text frames. Binary frames are not used.

```json
{
  "type": "call",
  "targetUserId": "550e8400-e29b-41d4-a716-446655440000",
  "offer": {
    "type": "offer",
    "sdp": "v=0\r\no=- 46117..."
  }
}
```
