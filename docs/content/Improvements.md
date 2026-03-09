# Improvements & Bug Fixes

This page tracks notable fixes and planned improvements to the codebase.

---

## Build Fixes (v1.0.1)

### `User` struct missing `discoverable` field

The database schema defined `discoverable BOOLEAN` on the `users` table, but the Rust `User` struct didn't include it. Every `SELECT * FROM users` query failed at compile time with:

```
error[E0560]: struct `User` has no field named `discoverable`
```

**Fix:** Added `pub discoverable: bool` to the `User` struct in `db/mod.rs`.

---

### Foreign key type mismatch in `contacts` / `invite_links`

Both tables stored `UUID` columns for user references, but the schema wrote:

```sql
-- WRONG: users.id is BIGSERIAL (i64), not UUID
REFERENCES users(id)
```

This caused sqlx to infer parameter types as `i64`, then reject `Uuid` values at compile time:

```
error[E0308]: mismatched types — expected `i64`, found `Uuid`
```

**Fix:** All foreign keys now reference `users(user_id)` (the UUID column):

```sql
-- CORRECT
requester_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
target_id    UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
owner_id     UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
```

---

### `_hub` / `_store` parameters inaccessible in `sfu_relay.rs`

Rust treats a leading underscore as an "intentionally unused" marker — the compiler does not make the value accessible under the bare name. All four SFU handler functions prefixed their parameters with `_`, then tried to use them as `hub` and `store`, producing `E0425: cannot find value 'hub' in this scope` on every call site.

**Fix:** Renamed `_hub` → `hub` and `_store` → `store` across all four functions.

---

### `redis_online` fake table in `list_contacts` query

The contacts listing query contained a conceptual LEFT JOIN:

```sql
LEFT JOIN redis_online r ON r.user_id = u.user_id  -- conceptual; use Redis SET check
```

`redis_online` is not a real PostgreSQL table — it was a design note left in the SQL. sqlx validates queries against the live schema at compile time, so this caused a compile failure.

**Fix:** Removed the JOIN entirely. Online presence is checked per-contact via Redis in the Rust loop that follows the query.

---

### `u.deleted_at IS NULL` references non-existent column

`get_user_by_handle` queried `AND u.deleted_at IS NULL`, but the schema uses `is_active BOOLEAN` for soft deletes — there is no `deleted_at` column.

**Fix:** Replaced with `AND u.is_active = true`, consistent with all other user queries.

---

## Planned Improvements

### sqlx Offline Mode

Currently, `cargo build` requires a live PostgreSQL connection because `sqlx::query!` macros validate SQL at compile time. The Docker image build therefore needs `--build-arg SQLX_OFFLINE=true` and a pre-generated `.sqlx/` directory.

**To generate the offline metadata locally:**

```bash
cd server-rust

# Run postgres (e.g. via docker-compose)
DATABASE_URL=postgres://voicecall:password@localhost/voicecall \
  cargo sqlx prepare

# This creates server-rust/.sqlx/
# Commit it to the repo — Docker builds will then work offline
git add .sqlx
git commit -m "chore: regenerate sqlx offline data"
```

Once `.sqlx/` is committed, set `SQLX_OFFLINE=true` in your Dockerfile:

```dockerfile
ENV SQLX_OFFLINE=true
RUN cargo build --release
```

---

### SFU Media Layer

`sfu_relay.rs` implements the signaling coordination for an SFU relay (room management, participant tracking, ICE/SDP forwarding), but the actual media relay is a stub. To complete it, integrate one of:

| Option | Language | Effort | Notes |
|--------|----------|--------|-------|
| **mediasoup** | Node.js | Low | REST API from Rust → mediasoup worker |
| **LiveKit** | Go | Low | Use LiveKit Flutter SDK directly |
| **Janus Gateway** | C | Medium | WebRTC gateway, REST + WebSocket API |
| **webrtc-rs** | Rust | High | Embed directly, alpha quality |

For most deployments, calling **LiveKit** via its Server SDK is the path of least resistance. See the [QUIC Noise Architecture](/docs?name=QUIC+Noise+Architecture) page for the LiveKit + SFrame integration guide.

---

### Contacts: Pagination

`list_contacts` currently returns all accepted contacts in a single query. For accounts with hundreds of contacts, add cursor-based pagination:

```sql
SELECT u.user_id, u.username, u.display_name, u.avatar_url, u.last_seen, c.created_at
FROM contacts c
JOIN users u ON (
    CASE WHEN c.requester_id = $1 THEN c.target_id ELSE c.requester_id END = u.user_id
)
WHERE (c.requester_id = $1 OR c.target_id = $1)
  AND c.status = 'accepted'
  AND c.created_at < $2   -- cursor
ORDER BY c.created_at DESC
LIMIT 50
```

---

### Push Notifications for Contact Requests

When a contact request is sent, the server currently only notifies via WebSocket (only works if the app is in the foreground). Add FCM fallback:

```rust
// After hub.send_to() in send_request:
if !was_delivered {
    fcm::notify_contact_request(&target, &auth.display_name).await?;
}
```

Store FCM tokens in a `device_tokens` table and send via the Firebase Admin SDK.
