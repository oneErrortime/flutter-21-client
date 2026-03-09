# REST API

Base URL: `https://yourserver.com` (or `http://10.0.2.2:3000` for local emulator development)

All protected endpoints require the `Authorization: Bearer <access_token>` header.

## Auth

### POST /api/auth/register

Register a new user.

**Request:**
```json
{
  "username": "alice",
  "password": "hunter2"
}
```

**Response `201`:**
```json
{
  "userId": "uuid",
  "username": "alice",
  "accessToken": "eyJ...",
  "refreshToken": "eyJ..."
}
```

---

### POST /api/auth/login

Login and receive tokens.

**Request:**
```json
{
  "username": "alice",
  "password": "hunter2"
}
```

**Response `200`:**
```json
{
  "userId": "uuid",
  "username": "alice",
  "accessToken": "eyJ...",
  "refreshToken": "eyJ..."
}
```

---

### POST /api/auth/refresh

Exchange a refresh token for a new access token. **Refresh token is rotated on every use.**

**Request:**
```json
{ "refreshToken": "eyJ..." }
```

**Response `200`:**
```json
{
  "accessToken": "eyJ...",
  "refreshToken": "eyJ..."
}
```

> `401` is returned if the refresh token is expired, revoked, or has already been used (reuse attack detected — all sessions are invalidated).

---

### POST /api/auth/logout

Revoke the current refresh token.

**Request:**
```json
{ "refreshToken": "eyJ..." }
```

**Response `204`**: No content.

---

### GET /api/auth/me

Returns the currently authenticated user.

**Response `200`:**
```json
{
  "userId": "uuid",
  "username": "alice",
  "createdAt": "2024-01-15T10:00:00Z"
}
```

## Users

### GET /api/users/:userId

Fetch a user by ID.

**Response `200`:**
```json
{
  "userId": "uuid",
  "username": "alice"
}
```

---

### GET /api/users/search?q=alice

Search users by username prefix.

**Response `200`:**
```json
{
  "users": [
    { "userId": "uuid", "username": "alice" }
  ]
}
```

## Rooms

### POST /api/rooms

Create a shareable room link. Room expires after 24 hours.

**Response `201`:**
```json
{
  "roomId": "uuid",
  "link": "https://yourapp.com/join/uuid",
  "deepLink": "voicecall://join/uuid",
  "expiresAt": "2024-01-16T10:00:00Z"
}
```

---

### GET /api/rooms/:roomId

Validate a room link before joining.

**Response `200`:**
```json
{
  "roomId": "uuid",
  "creatorId": "uuid",
  "expiresAt": "2024-01-16T10:00:00Z",
  "valid": true
}
```

`404` if the room doesn't exist or has expired.

## Error Format

All errors return a consistent JSON body:

```json
{
  "error": "INVALID_CREDENTIALS",
  "message": "Username or password is incorrect"
}
```

| Code | Meaning |
|---|---|
| `400` | Invalid request body |
| `401` | Missing or invalid token |
| `403` | Forbidden |
| `404` | Resource not found |
| `429` | Rate limit exceeded |
| `500` | Internal server error |
