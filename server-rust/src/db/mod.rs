pub mod redis_store;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

use crate::errors::AppError;

// ── Models ────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct User {
    pub id: i64,       // BIGSERIAL primary key
    pub user_id: Uuid,
    pub username: String,
    pub email: String,
    pub display_name: String,
    pub avatar_url: Option<String>,
    pub password_hash: String,
    pub is_active: bool,
    pub last_seen: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublicUser {
    pub user_id: Uuid,
    pub username: String,
    pub display_name: String,
    pub avatar_url: Option<String>,
    pub last_seen: DateTime<Utc>,
}

impl From<User> for PublicUser {
    fn from(u: User) -> Self {
        PublicUser {
            user_id: u.user_id,
            username: u.username,
            display_name: u.display_name,
            avatar_url: u.avatar_url,
            last_seen: u.last_seen,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Room {
    pub id: i64,       // BIGSERIAL primary key
    pub room_id: Uuid,
    pub created_by: Uuid,
    pub is_active: bool,
    pub expires_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

// ── Database Client ───────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct Database {
    pub pool: PgPool,
}

impl Database {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    // ── Users ──────────────────────────────────────────────────────────────

    pub async fn create_user(
        &self,
        username: &str,
        email: &str,
        display_name: &str,
        password_hash: &str,
    ) -> Result<User, AppError> {
        let user = sqlx::query_as!(
            User,
            r#"
            INSERT INTO users (user_id, username, email, display_name, password_hash)
            VALUES (gen_random_uuid(), $1, $2, $3, $4)
            RETURNING *
            "#,
            username,
            email,
            display_name,
            password_hash,
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(user)
    }

    pub async fn find_user_by_identifier(&self, identifier: &str) -> Result<Option<User>, AppError> {
        let user = sqlx::query_as!(
            User,
            r#"
            SELECT * FROM users
            WHERE (email = LOWER($1) OR username = $1) AND is_active = true
            "#,
            identifier,
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(user)
    }

    pub async fn find_user_by_id(&self, user_id: &Uuid) -> Result<Option<User>, AppError> {
        let user = sqlx::query_as!(
            User,
            "SELECT * FROM users WHERE user_id = $1 AND is_active = true",
            user_id,
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(user)
    }

    pub async fn user_is_active(&self, user_id: &Uuid) -> Result<bool, AppError> {
        let row = sqlx::query!(
            "SELECT is_active FROM users WHERE user_id = $1",
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| r.is_active).unwrap_or(false))
    }

    pub async fn username_exists(&self, username: &str) -> Result<bool, AppError> {
        let row = sqlx::query!("SELECT 1 as one FROM users WHERE username = $1", username)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.is_some())
    }

    pub async fn email_exists(&self, email: &str) -> Result<bool, AppError> {
        let row = sqlx::query!(
            "SELECT 1 as one FROM users WHERE email = LOWER($1)",
            email
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }

    pub async fn update_last_seen(&self, user_id: &Uuid) -> Result<(), AppError> {
        sqlx::query!(
            "UPDATE users SET last_seen = NOW() WHERE user_id = $1",
            user_id
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn search_users(&self, query: &str, exclude_id: &Uuid) -> Result<Vec<User>, AppError> {
        let pattern = format!("%{}%", query);
        let users = sqlx::query_as!(
            User,
            r#"
            SELECT * FROM users
            WHERE username ILIKE $1 AND user_id != $2 AND is_active = true
            LIMIT 20
            "#,
            pattern,
            exclude_id,
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(users)
    }

    // ── Rooms ──────────────────────────────────────────────────────────────

    pub async fn create_room(&self, created_by: &Uuid) -> Result<Room, AppError> {
        let room = sqlx::query_as!(
            Room,
            r#"
            INSERT INTO rooms (room_id, created_by, expires_at)
            VALUES (gen_random_uuid(), $1, NOW() + INTERVAL '24 hours')
            RETURNING *
            "#,
            created_by,
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(room)
    }

    pub async fn find_room(&self, room_id: &Uuid) -> Result<Option<Room>, AppError> {
        let room = sqlx::query_as!(
            Room,
            r#"
            SELECT * FROM rooms
            WHERE room_id = $1 AND is_active = true AND expires_at > NOW()
            "#,
            room_id,
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(room)
    }

    // ── Refresh tokens (stored in Redis, but record in PG for audit) ──────
    // Actual token storage is in Redis for fast lookup
}

// ── DB Migrations (embedded) ─────────────────────────────────────────────────

pub const MIGRATIONS: &str = r#"
-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS users (
    id            BIGSERIAL PRIMARY KEY,
    user_id       UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    username      VARCHAR(30) NOT NULL UNIQUE,
    email         VARCHAR(255) NOT NULL UNIQUE,
    display_name  VARCHAR(50) NOT NULL,
    avatar_url    TEXT,
    password_hash TEXT        NOT NULL,
    is_active     BOOLEAN     NOT NULL DEFAULT true,
    last_seen     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_user_id  ON users(user_id);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_email    ON users(LOWER(email));

CREATE TABLE IF NOT EXISTS rooms (
    id          BIGSERIAL PRIMARY KEY,
    room_id     UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    created_by  UUID        NOT NULL REFERENCES users(user_id),
    is_active   BOOLEAN     NOT NULL DEFAULT true,
    expires_at  TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '24 hours',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rooms_room_id ON rooms(room_id);
CREATE INDEX IF NOT EXISTS idx_rooms_expires ON rooms(expires_at);

-- Auto-expire rooms
CREATE OR REPLACE FUNCTION expire_rooms()
RETURNS void LANGUAGE sql AS $$
    UPDATE rooms SET is_active = false
    WHERE expires_at < NOW() AND is_active = true;
$$;
"#;
