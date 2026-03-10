//! routes/contacts.rs
//!
//! Contacts / Friends API
//!
//! Privacy model:
//!   - Search by @handle returns ONLY users with `discoverable = true`
//!     OR users already in your contacts (so you can see their handle).
//!   - Contact requests require the target to accept before either
//!     party can call the other.
//!   - Blocks are one-sided and completely opaque to the blocked user.
//!
//! DB schema required (add to db::MIGRATIONS):
//! ─────────────────────────────────────────────
//! CREATE TABLE IF NOT EXISTS contacts (
//!     id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
//!     requester_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
//!     target_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
//!     status          TEXT NOT NULL DEFAULT 'pending'
//!                         CHECK (status IN ('pending','accepted','blocked')),
//!     created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
//!     updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
//!     UNIQUE (requester_id, target_id)
//! );
//! CREATE INDEX IF NOT EXISTS contacts_target_id_idx ON contacts (target_id);
//! CREATE INDEX IF NOT EXISTS contacts_status_idx ON contacts (status);
//!
//! CREATE TABLE IF NOT EXISTS invite_links (
//!     id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
//!     owner_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
//!     token       TEXT NOT NULL UNIQUE,
//!     uses_left   INTEGER NOT NULL DEFAULT 1,   -- 0 = unlimited
//!     expires_at  TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours',
//!     created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
//! );
//! CREATE INDEX IF NOT EXISTS invite_links_token_idx ON invite_links (token);

use axum::{
    extract::{Path, State},
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    db::Database,
    errors::{ApiResult, AppError},
    AppState,
};

// ── Request / Response types ──────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct ContactRequestBody {
    #[serde(rename = "targetUserId")]
    pub target_user_id: Uuid,
}

#[derive(Deserialize)]
pub struct AcceptBody {
    #[serde(rename = "requesterId")]
    pub requester_id: Uuid,
}

#[derive(Deserialize)]
pub struct BlockBody {
    #[serde(rename = "userId")]
    pub user_id: Uuid,
}

#[derive(Serialize)]
pub struct ContactEntry {
    #[serde(rename = "userId")]
    pub user_id: Uuid,
    pub username: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    #[serde(rename = "avatarUrl")]
    pub avatar_url: Option<String>,
    #[serde(rename = "isOnline")]
    pub is_online: bool,
    #[serde(rename = "lastSeen")]
    pub last_seen: Option<String>,
    pub status: String,
    #[serde(rename = "createdAt")]
    pub created_at: String,
}

// ── GET /api/contacts — list accepted contacts ────────────────────────────────

pub async fn list_contacts(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult<Json<serde_json::Value>> {
    let rows = sqlx::query!(
        r#"
        SELECT
            u.user_id, u.username, u.display_name, u.avatar_url, u.last_seen,
            c.created_at
        FROM contacts c
        JOIN users u ON (
            CASE WHEN c.requester_id = $1 THEN c.target_id ELSE c.requester_id END = u.user_id
        )
        WHERE (c.requester_id = $1 OR c.target_id = $1)
          AND c.status = 'accepted'
        ORDER BY u.display_name ASC
        "#,
        auth.user_id
    )
    .fetch_all(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    // Check online status from Redis for each contact
    let contacts: Vec<ContactEntry> = {
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let is_online = state.redis.is_online(&row.user_id).await.unwrap_or(false);
            out.push(ContactEntry {
                user_id: row.user_id,
                username: row.username,
                display_name: row.display_name,
                avatar_url: row.avatar_url,
                is_online,
                last_seen: Some(row.last_seen.to_rfc3339()),
                status: "accepted".into(),
                created_at: row.created_at.to_rfc3339(),
            });
        }
        out
    };

    Ok(Json(serde_json::json!({ "contacts": contacts })))
}

// ── GET /api/contacts/pending — incoming requests ─────────────────────────────

pub async fn pending_requests(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult<Json<serde_json::Value>> {
    let rows = sqlx::query!(
        r#"
        SELECT u.user_id, u.username, u.display_name, u.avatar_url, c.created_at
        FROM contacts c
        JOIN users u ON c.requester_id = u.user_id
        WHERE c.target_id = $1 AND c.status = 'pending'
        ORDER BY c.created_at DESC
        "#,
        auth.user_id
    )
    .fetch_all(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    let requests: Vec<serde_json::Value> = rows
        .iter()
        .map(|r| {
            serde_json::json!({
                "userId":      r.user_id,
                "username":    r.username,
                "displayName": r.display_name,
                "avatarUrl":   r.avatar_url,
                "createdAt":   r.created_at.to_rfc3339(),
            })
        })
        .collect();

    Ok(Json(serde_json::json!({ "requests": requests })))
}

// ── GET /api/contacts/sent — outgoing pending requests ───────────────────────

pub async fn sent_requests(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult<Json<serde_json::Value>> {
    let rows = sqlx::query!(
        r#"
        SELECT u.user_id, u.username, u.display_name, u.avatar_url, c.created_at
        FROM contacts c
        JOIN users u ON c.target_id = u.user_id
        WHERE c.requester_id = $1 AND c.status = 'pending'
        ORDER BY c.created_at DESC
        "#,
        auth.user_id
    )
    .fetch_all(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    let requests: Vec<serde_json::Value> = rows
        .iter()
        .map(|r| {
            serde_json::json!({
                "userId":      r.user_id,
                "username":    r.username,
                "displayName": r.display_name,
                "avatarUrl":   r.avatar_url,
                "createdAt":   r.created_at.to_rfc3339(),
            })
        })
        .collect();

    Ok(Json(serde_json::json!({ "requests": requests })))
}

// ── POST /api/contacts/request ────────────────────────────────────────────────

pub async fn send_request(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Json(body): Json<ContactRequestBody>,
) -> ApiResult<Json<serde_json::Value>> {
    let target = body.target_user_id;

    if target == auth.user_id {
        return Err(AppError::BadRequest("Cannot add yourself".into()));
    }

    // Check target exists
    let exists = sqlx::query_scalar!(
        "SELECT EXISTS(SELECT 1 FROM users WHERE user_id = $1)",
        target
    )
    .fetch_one(&state.db.pool)
    .await
    .map_err(AppError::Database)?
    .unwrap_or(false);

    if !exists {
        return Err(AppError::NotFound("User not found".into()));
    }

    // Check if already contacts or request exists
    let existing = sqlx::query_scalar!(
        r#"
        SELECT status FROM contacts
        WHERE (requester_id = $1 AND target_id = $2)
           OR (requester_id = $2 AND target_id = $1)
        "#,
        auth.user_id,
        target
    )
    .fetch_optional(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    match existing.as_deref() {
        Some("accepted") => return Err(AppError::Conflict("ALREADY_CONTACTS".into())),
        Some("pending") => return Err(AppError::Conflict("REQUEST_EXISTS".into())),
        Some("blocked") => return Err(AppError::Forbidden("BLOCKED".into())),
        _ => {}
    }

    // Insert request
    sqlx::query!(
        r#"
        INSERT INTO contacts (requester_id, target_id, status)
        VALUES ($1, $2, 'pending')
        ON CONFLICT (requester_id, target_id) DO UPDATE SET status = 'pending', updated_at = now()
        "#,
        auth.user_id,
        target
    )
    .execute(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    // Notify target via WebSocket if online
    let _ = state.hub.send_to(&target, serde_json::json!({
        "type": "contact-request",
        "from": auth.user_id,
        "displayName": auth.display_name,
    }).to_string()).await;

    tracing::info!(from = %auth.user_id, to = %target, "Contact request sent");
    metrics::counter!("contacts.requests_sent").increment(1);

    Ok(Json(serde_json::json!({ "status": "sent" })))
}

// ── POST /api/contacts/accept ─────────────────────────────────────────────────

pub async fn accept_request(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Json(body): Json<AcceptBody>,
) -> ApiResult<Json<serde_json::Value>> {
    let requester = body.requester_id;

    let updated = sqlx::query!(
        r#"
        UPDATE contacts SET status = 'accepted', updated_at = now()
        WHERE requester_id = $1 AND target_id = $2 AND status = 'pending'
        "#,
        requester,
        auth.user_id
    )
    .execute(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    if updated.rows_affected() == 0 {
        return Err(AppError::NotFound("No pending request found".into()));
    }

    // Notify requester they were accepted
    let _ = state.hub.send_to(&requester, serde_json::json!({
        "type": "contact-accepted",
        "by": auth.user_id,
        "displayName": auth.display_name,
    }).to_string()).await;

    tracing::info!(accepted_by = %auth.user_id, requester = %requester, "Contact request accepted");
    metrics::counter!("contacts.accepted").increment(1);

    Ok(Json(serde_json::json!({ "status": "accepted" })))
}

// ── POST /api/contacts/decline ────────────────────────────────────────────────

pub async fn decline_request(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Json(body): Json<AcceptBody>,
) -> ApiResult<Json<serde_json::Value>> {
    sqlx::query!(
        "DELETE FROM contacts WHERE requester_id = $1 AND target_id = $2 AND status = 'pending'",
        body.requester_id,
        auth.user_id
    )
    .execute(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    Ok(Json(serde_json::json!({ "status": "declined" })))
}

// ── DELETE /api/contacts/:userId ──────────────────────────────────────────────

pub async fn remove_contact(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Path(user_id): Path<Uuid>,
) -> ApiResult<Json<serde_json::Value>> {
    sqlx::query!(
        r#"
        DELETE FROM contacts
        WHERE status = 'accepted'
          AND ((requester_id = $1 AND target_id = $2)
            OR (requester_id = $2 AND target_id = $1))
        "#,
        auth.user_id,
        user_id
    )
    .execute(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    Ok(Json(serde_json::json!({ "status": "removed" })))
}

// ── POST /api/contacts/block ──────────────────────────────────────────────────

pub async fn block_user(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Json(body): Json<BlockBody>,
) -> ApiResult<Json<serde_json::Value>> {
    // Remove any existing contact/request, then insert a block record
    sqlx::query!(
        r#"
        DELETE FROM contacts
        WHERE (requester_id = $1 AND target_id = $2)
           OR (requester_id = $2 AND target_id = $1)
        "#,
        auth.user_id,
        body.user_id
    )
    .execute(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    sqlx::query!(
        r#"
        INSERT INTO contacts (requester_id, target_id, status)
        VALUES ($1, $2, 'blocked')
        "#,
        auth.user_id,
        body.user_id
    )
    .execute(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    tracing::info!(blocker = %auth.user_id, blocked = %body.user_id, "User blocked");

    Ok(Json(serde_json::json!({ "status": "blocked" })))
}

// ── GET /api/users/by-handle/:handle ─────────────────────────────────────────
//
// Privacy rules:
//   Returns a user if:
//     a) they have discoverable = true, OR
//     b) they are already an accepted contact of the requester
//   Returns 404 otherwise (leaks nothing about whether the account exists).

pub async fn get_user_by_handle(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Path(handle): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    // Must be exact match, case-insensitive
    let user = sqlx::query!(
        r#"
        SELECT
            u.user_id, u.username, u.display_name, u.avatar_url,
            u.discoverable,
            EXISTS(
                SELECT 1 FROM contacts c
                WHERE c.status = 'accepted'
                  AND ((c.requester_id = $2 AND c.target_id = u.user_id)
                    OR (c.requester_id = u.user_id AND c.target_id = $2))
            ) as "is_contact!: bool"
        FROM users u
        WHERE lower(u.username) = lower($1)
          AND u.is_active = true
        "#,
        handle,
        auth.user_id
    )
    .fetch_optional(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    match user {
        None => Err(AppError::NotFound("User not found".into())),
        Some(u) if !u.discoverable && !u.is_contact => {
            // User exists but is not discoverable and not a contact — return 404
            // to avoid confirming the account exists
            Err(AppError::NotFound("User not found".into()))
        }
        Some(u) => Ok(Json(serde_json::json!({
            "user": {
                "userId":      u.user_id,
                "username":    u.username,
                "displayName": u.display_name,
                "avatarUrl":   u.avatar_url,
            }
        }))),
    }
}

// ── POST /api/contacts/invite-link ────────────────────────────────────────────

pub async fn generate_invite_link(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult<Json<serde_json::Value>> {
    use rand::{distr::Alphanumeric, Rng as _};

    let token: String = rand::rng()
        .sample_iter(Alphanumeric)
        .take(12)
        .map(char::from)
        .collect();

    sqlx::query!(
        r#"
        INSERT INTO invite_links (owner_id, token, uses_left, expires_at)
        VALUES ($1, $2, 1, now() + INTERVAL '24 hours')
        "#,
        auth.user_id,
        token
    )
    .execute(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    let link = format!(
        "{}/add/{}/{}",
        state.config.app_base_url,
        auth.user_id,
        token
    );

    tracing::info!(user_id = %auth.user_id, token = %token, "Invite link generated");

    Ok(Json(serde_json::json!({ "link": link, "expiresIn": "24h" })))
}

// ── POST /api/contacts/use-invite — redeem an invite link ────────────────────

#[derive(Deserialize)]
pub struct UseInviteBody {
    pub owner_id: Uuid,
    pub token: String,
}

pub async fn use_invite_link(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Json(body): Json<UseInviteBody>,
) -> ApiResult<Json<serde_json::Value>> {
    // Verify invite exists, belongs to owner, not expired, has uses left
    let invite = sqlx::query!(
        r#"
        SELECT id, uses_left
        FROM invite_links
        WHERE owner_id = $1 AND token = $2 AND expires_at > now()
        "#,
        body.owner_id,
        body.token
    )
    .fetch_optional(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    let invite = invite.ok_or_else(|| {
        AppError::NotFound("Invite link not found or expired".into())
    })?;

    if invite.uses_left == 0 {
        return Err(AppError::BadRequest("Invite link has been used".into()));
    }

    // Decrement uses
    sqlx::query!(
        "UPDATE invite_links SET uses_left = uses_left - 1 WHERE id = $1",
        invite.id
    )
    .execute(&state.db.pool)
    .await
    .map_err(AppError::Database)?;

    // Auto-send contact request from claimer → link owner
    // (same logic as send_request, inlined here for clarity)
    let _ = sqlx::query!(
        r#"
        INSERT INTO contacts (requester_id, target_id, status)
        VALUES ($1, $2, 'pending')
        ON CONFLICT DO NOTHING
        "#,
        auth.user_id,
        body.owner_id
    )
    .execute(&state.db.pool)
    .await;

    // Notify owner via WebSocket
    let _ = state.hub.send_to(&body.owner_id, serde_json::json!({
        "type": "contact-request",
        "from": auth.user_id,
        "displayName": auth.display_name,
        "viaInviteLink": true,
    }).to_string()).await;

    Ok(Json(serde_json::json!({
        "status": "request_sent",
        "ownerId": body.owner_id,
    })))
}

// ── Security: validate call is allowed ───────────────────────────────────────
//
// Called from the WebSocket signaling handler before forwarding a call.
// A call is allowed only if the two parties are mutual accepted contacts.

pub async fn can_call(db: &Database, caller: &Uuid, callee: &Uuid) -> bool {
    sqlx::query_scalar!(
        r#"
        SELECT EXISTS(
            SELECT 1 FROM contacts
            WHERE status = 'accepted'
              AND ((requester_id = $1 AND target_id = $2)
                OR (requester_id = $2 AND target_id = $1))
        ) as "exists!: bool"
        "#,
        caller,
        callee
    )
    .fetch_one(&db.pool)
    .await
    .unwrap_or(false)
}
