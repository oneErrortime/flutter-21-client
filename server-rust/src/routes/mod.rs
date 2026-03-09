pub mod auth;
pub mod contacts;

// ── Users ─────────────────────────────────────────────────────────────────────

use axum::{
    extract::{Path, Query, State},
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{auth::AuthUser, db::PublicUser, errors::{ApiResult, AppError}, AppState};

pub async fn get_user(
    State(state): State<AppState>,
    Extension(_auth): Extension<AuthUser>,
    Path(user_id): Path<Uuid>,
) -> ApiResult<Json<serde_json::Value>> {
    let user = state
        .db
        .find_user_by_id(&user_id)
        .await?
        .ok_or_else(|| AppError::NotFound("User not found".into()))?;
    Ok(Json(serde_json::json!({ "user": PublicUser::from(user) })))
}

#[derive(Deserialize)]
pub struct SearchQuery {
    pub q: String,
}

pub async fn search_users(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
    Query(params): Query<SearchQuery>,
) -> ApiResult<Json<serde_json::Value>> {
    if params.q.len() < 2 {
        return Err(AppError::BadRequest("Query must be at least 2 chars".into()));
    }
    let users = state.db.search_users(&params.q, &auth.user_id).await?;
    let public: Vec<PublicUser> = users.into_iter().map(Into::into).collect();
    Ok(Json(serde_json::json!({ "users": public })))
}

// ── Rooms ─────────────────────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct RoomResponse {
    pub room_id: Uuid,
    pub link: String,
    pub expires_at: String,
}

pub async fn create_room(
    State(state): State<AppState>,
    Extension(auth): Extension<AuthUser>,
) -> ApiResult<Json<RoomResponse>> {
    let room = state.db.create_room(&auth.user_id).await?;
    let link = format!("{}/join/{}", state.config.app_base_url, room.room_id);
    tracing::info!(room_id = %room.room_id, user_id = %auth.user_id, "Room created");
    Ok(Json(RoomResponse {
        room_id: room.room_id,
        link,
        expires_at: room.expires_at.to_rfc3339(),
    }))
}

pub async fn get_room(
    State(state): State<AppState>,
    Extension(_auth): Extension<AuthUser>,
    Path(room_id): Path<Uuid>,
) -> ApiResult<Json<serde_json::Value>> {
    let room = state
        .db
        .find_room(&room_id)
        .await?
        .ok_or_else(|| AppError::NotFound("Room not found or expired".into()))?;

    let creator = state.db.find_user_by_id(&room.created_by).await?;

    Ok(Json(serde_json::json!({
        "roomId": room.room_id,
        "createdBy": creator.map(PublicUser::from),
        "expiresAt": room.expires_at.to_rfc3339(),
    })))
}
