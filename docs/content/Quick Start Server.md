# Quick Start — Server

Get the signaling server running in under five minutes.

## Prerequisites

- Node.js 18+
- MongoDB (local or [Atlas free tier](https://www.mongodb.com/atlas))
- Docker + Docker Compose *(optional, recommended for production)*

## Option A — Local Development

```bash
cd server
cp .env.example .env
# Edit .env: set MONGODB_URI and JWT secrets

npm install
npm run dev
```

Server starts at `http://localhost:3000`.  
WebSocket endpoint at `ws://localhost:3000/ws`.

## Option B — Docker (Recommended)

```bash
cd server
cp .env.example .env
# Edit .env: strong JWT secrets, MongoDB URI, TURN credentials

docker-compose up -d
```

Includes Nginx with SSL termination and automatic restart.

## Option C — Rust Server

```bash
cd server-rust
cp .env.example .env

# With Docker:
docker-compose up -d

# Or natively (requires Rust 1.75+):
cargo run --release
```

The Rust server implements the **identical protocol** as the Node.js server — clients are interchangeable.

## Environment Variables

| Variable | Description | Example |
|---|---|---|
| `MONGODB_URI` | MongoDB connection string | `mongodb://localhost:27017/voicecall` |
| `JWT_ACCESS_SECRET` | Access token signing key | 64-char hex string |
| `JWT_REFRESH_SECRET` | Refresh token signing key | 64-char hex string |
| `PORT` | Server port | `3000` |
| `ALLOWED_ORIGINS` | CORS whitelist | `https://yourapp.com` |
| `TURN_SECRET` | TURN server credential secret | optional |

## Generate Strong JWT Secrets

```bash
openssl rand -hex 64  # JWT_ACCESS_SECRET
openssl rand -hex 64  # JWT_REFRESH_SECRET
```

> **Never reuse secrets between access and refresh tokens.** If an access secret is compromised, refresh tokens must remain secure to allow session revocation.
