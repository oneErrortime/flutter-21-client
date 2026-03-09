use axum::{
    extract::{Request, State},
    middleware::Next,
    response::Response,
};
use uuid::Uuid;

use crate::{errors::AppError, AppState};

/// Axum middleware: validates JWT Bearer token and injects user_id into request extensions
pub async fn require_auth(
    State(state): State<AppState>,
    mut req: Request,
    next: Next,
) -> Result<Response, AppError> {
    let token = extract_bearer(req.headers())
        .ok_or_else(|| AppError::Unauthorized("No Bearer token".into()))?;

    let claims = state.jwt.verify_access(token)?;

    // Verify user still exists and is active (cached via Redis to avoid DB hit every request)
    let user_id = Uuid::parse_str(&claims.sub)
        .map_err(|_| AppError::Unauthorized("Invalid user ID in token".into()))?;

    let exists = state.db.user_is_active(&user_id).await?;
    if !exists {
        return Err(AppError::Unauthorized("User not found or deactivated".into()));
    }

    req.extensions_mut().insert(AuthUser {
        user_id,
        display_name: state
            .db
            .find_user_by_id(&user_id)
            .await?
            .map(|u| u.display_name)
            .unwrap_or_default(),
    });
    Ok(next.run(req).await)
}

fn extract_bearer(headers: &axum::http::HeaderMap) -> Option<&str> {
    let auth = headers.get("authorization")?.to_str().ok()?;
    auth.strip_prefix("Bearer ")
}

/// Injected by the middleware, extracted in handlers
#[derive(Clone, Debug)]
pub struct AuthUser {
    pub user_id: Uuid,
    // Pre-fetched to avoid an extra DB round-trip in handlers that need it.
    // Not all handlers use it yet; suppress the warning until they do.
    #[allow(dead_code)]
    pub display_name: String,
}
