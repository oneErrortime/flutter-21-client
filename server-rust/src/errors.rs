use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("Not found: {0}")]
    NotFound(String),

    #[error("Unauthorized: {0}")]
    Unauthorized(String),

    #[error("Forbidden: {0}")]
    Forbidden(String),

    #[error("Conflict: {0}")]
    Conflict(String),

    #[error("Bad request: {0}")]
    BadRequest(String),

    #[error("Rate limited")]
    RateLimited,

    #[error("Database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("Redis error: {0}")]
    Redis(#[from] redis::RedisError),

    #[error("Internal error: {0}")]
    Internal(#[from] anyhow::Error),

    #[error("Crypto error: {0}")]
    Crypto(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, msg, code) = match &self {
            AppError::NotFound(m) => (StatusCode::NOT_FOUND, m.clone(), "NOT_FOUND"),
            AppError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, m.clone(), "UNAUTHORIZED"),
            AppError::Forbidden(m) => (StatusCode::FORBIDDEN, m.clone(), "FORBIDDEN"),
            AppError::Conflict(m) => (StatusCode::CONFLICT, m.clone(), "CONFLICT"),
            AppError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone(), "BAD_REQUEST"),
            AppError::RateLimited => (
                StatusCode::TOO_MANY_REQUESTS,
                "Too many requests".into(),
                "RATE_LIMITED",
            ),
            AppError::Database(e) => {
                tracing::error!("DB error: {e}");
                (StatusCode::INTERNAL_SERVER_ERROR, "Database error".into(), "DB_ERROR")
            }
            AppError::Redis(e) => {
                tracing::error!("Redis error: {e}");
                (StatusCode::INTERNAL_SERVER_ERROR, "Cache error".into(), "CACHE_ERROR")
            }
            AppError::Internal(e) => {
                tracing::error!("Internal error: {e}");
                (StatusCode::INTERNAL_SERVER_ERROR, "Internal error".into(), "INTERNAL")
            }
            AppError::Crypto(m) => {
                tracing::error!("Crypto error: {m}");
                (StatusCode::INTERNAL_SERVER_ERROR, "Crypto error".into(), "CRYPTO_ERROR")
            }
        };

        (status, Json(json!({ "error": msg, "code": code }))).into_response()
    }
}

pub type ApiResult<T> = Result<T, AppError>;
