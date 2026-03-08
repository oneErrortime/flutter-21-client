use axum::{extract::State, http::StatusCode, Extension, Json};
use regex::Regex;
use serde::{Deserialize, Serialize};
use once_cell::sync::Lazy;

use crate::{
    auth::AuthUser,
    crypto::{hash_password, verify_password},
    db::PublicUser,
    errors::{ApiResult, AppError},
    AppState,
};

static USERNAME_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[a-zA-Z0-9_.\-]{3,30}$").unwrap());
static EMAIL_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^\S+@\S+\.\S+$").unwrap());

// ── Register ──────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub username: String,
    pub email: String,
    pub display_name: String,
    pub password: String,
}

#[derive(Serialize)]
pub struct AuthResponse {
    pub user: PublicUser,
    pub access_token: String,
    pub refresh_token: String,
}

pub async fn register(
    State(state): State<AppState>,
    Json(body): Json<RegisterRequest>,
) -> ApiResult<(StatusCode, Json<AuthResponse>)> {
    // Validate
    if !USERNAME_RE.is_match(&body.username) {
        return Err(AppError::BadRequest(
            "Username: 3-30 chars, only letters/numbers/_.-".into(),
        ));
    }
    if !EMAIL_RE.is_match(&body.email) {
        return Err(AppError::BadRequest("Invalid email".into()));
    }
    if body.password.len() < 8 {
        return Err(AppError::BadRequest("Password min 8 chars".into()));
    }
    if body.password.len() > 128 {
        return Err(AppError::BadRequest("Password too long".into()));
    }
    if body.display_name.is_empty() || body.display_name.len() > 50 {
        return Err(AppError::BadRequest("Display name: 1-50 chars".into()));
    }

    // Check conflicts
    if state.db.username_exists(&body.username).await? {
        return Err(AppError::Conflict("Username already taken".into()));
    }
    if state.db.email_exists(&body.email).await? {
        return Err(AppError::Conflict("Email already in use".into()));
    }

    // Hash password with Argon2id (this is the slow operation — ~100ms intentionally)
    let hash = hash_password(&body.password)?;

    let user = state
        .db
        .create_user(&body.username, &body.email, &body.display_name, &hash)
        .await?;

    let (access_token, refresh_token) = issue_tokens(&state, &user.user_id).await?;

    tracing::info!(user_id = %user.user_id, username = %user.username, "User registered");
    metrics::counter!("auth.register.success").increment(1);

    Ok((
        StatusCode::CREATED,
        Json(AuthResponse {
            user: user.into(),
            access_token,
            refresh_token,
        }),
    ))
}

// ── Login ─────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct LoginRequest {
    pub identifier: String, // email or username
    pub password: String,
}

pub async fn login(
    State(state): State<AppState>,
    Json(body): Json<LoginRequest>,
) -> ApiResult<Json<AuthResponse>> {
    let user = state
        .db
        .find_user_by_identifier(&body.identifier)
        .await?
        .ok_or_else(|| AppError::Unauthorized("Invalid credentials".into()))?;

    // Verify password (Argon2id — timing-safe comparison)
    let valid = verify_password(&body.password, &user.password_hash)?;
    if !valid {
        metrics::counter!("auth.login.failed").increment(1);
        return Err(AppError::Unauthorized("Invalid credentials".into()));
    }

    let (access_token, refresh_token) = issue_tokens(&state, &user.user_id).await?;
    state.db.update_last_seen(&user.user_id).await?;

    tracing::info!(user_id = %user.user_id, "User logged in");
    metrics::counter!("auth.login.success").increment(1);

    Ok(Json(AuthResponse {
        user: user.into(),
        access_token,
        refresh_token,
    }))
}

// ── Refresh Token ─────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct RefreshRequest {
    pub refresh_token: String,
}

#[derive(Serialize)]
pub struct RefreshResponse {
    pub access_token: String,
    pub refresh_token: String,
}

pub async fn refresh(
    State(state): State<AppState>,
    Json(body): Json<RefreshRequest>,
) -> ApiResult<Json<RefreshResponse>> {
    let claims = state
        .jwt
        .verify_refresh(&body.refresh_token)
        .map_err(|_| AppError::Unauthorized("Invalid or expired refresh token".into()))?;

    let user_id = uuid::Uuid::parse_str(&claims.sub)
        .map_err(|_| AppError::Unauthorized("Bad token".into()))?;

    // Check JTI is valid (not revoked)
    let valid = state
        .redis
        .is_refresh_token_valid(&user_id, &claims.jti)
        .await?;

    if !valid {
        // TOFU: token reuse detected — revoke ALL sessions
        tracing::warn!(user_id = %user_id, jti = %claims.jti, "Refresh token reuse detected — revoking all sessions");
        state.redis.revoke_all_refresh_tokens(&user_id).await?;
        metrics::counter!("auth.refresh.reuse_detected").increment(1);
        return Err(AppError::Unauthorized(
            "Refresh token invalid — all sessions revoked for security".into(),
        ));
    }

    // Rotate: revoke old, issue new
    state.redis.revoke_refresh_token(&user_id, &claims.jti).await?;
    let (access_token, refresh_token) = issue_tokens(&state, &user_id).await?;

    Ok(Json(RefreshResponse {
        access_token,
        refresh_token,
    }))
}

// ── Logout ────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct LogoutRequest {
    pub refresh_token: Option<String>,
    pub logout_all: Option<bool>,
}

#[derive(Serialize)]
pub struct MessageResponse {
    pub message: String,
}

pub async fn logout(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Json(body): Json<LogoutRequest>,
) -> ApiResult<Json<MessageResponse>> {
    if body.logout_all.unwrap_or(false) {
        state.redis.revoke_all_refresh_tokens(&auth.user_id).await?;
        tracing::info!(user_id = %auth.user_id, "User logged out from all devices");
    } else if let Some(rt) = body.refresh_token {
        // Revoke just this token
        if let Ok(claims) = state.jwt.verify_refresh(&rt) {
            state.redis.revoke_refresh_token(&auth.user_id, &claims.jti).await?;
        }
    }
    Ok(Json(MessageResponse {
        message: "Logged out successfully".into(),
    }))
}

// ── Me ────────────────────────────────────────────────────────────────────────

pub async fn me(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult<Json<serde_json::Value>> {
    let user = state
        .db
        .find_user_by_id(&auth.user_id)
        .await?
        .ok_or_else(|| AppError::NotFound("User not found".into()))?;
    Ok(Json(serde_json::json!({ "user": PublicUser::from(user) })))
}

// ── Helpers ───────────────────────────────────────────────────────────────────

async fn issue_tokens(
    state: &AppState,
    user_id: &uuid::Uuid,
) -> ApiResult<(String, String)> {
    let access_token = state.jwt.generate_access_token(user_id)?;
    let refresh_token = state.jwt.generate_refresh_token(user_id)?;

    // Store refresh JTI in Redis
    let refresh_claims = state.jwt.verify_refresh(&refresh_token)?;
    state
        .redis
        .store_refresh_token(user_id, &refresh_claims.jti, state.config.jwt_refresh_exp_secs)
        .await?;

    Ok((access_token, refresh_token))
}
