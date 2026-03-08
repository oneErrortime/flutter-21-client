/// Redis Session Store
///
/// Used for:
/// 1. Refresh token storage (with TTL = refresh token expiry)
///    Key: `rt:{user_id}:{jti}` → "1"
/// 2. Online presence (which users are connected)
///    Key: `online:{user_id}` → "1" (with TTL)
/// 3. Rate limiting counters
///    Key: `rl:{ip}:{endpoint}` → count
/// 4. Call busy state
///    Key: `busy:{user_id}` → call_id (with TTL)

use redis::{aio::ConnectionManager, AsyncCommands, Client};
use uuid::Uuid;

use crate::errors::AppError;

#[derive(Clone)]
pub struct RedisStore {
    pub conn: ConnectionManager,
}

impl RedisStore {
    pub async fn new(url: &str) -> Result<Self, AppError> {
        let client = Client::open(url).map_err(|e| AppError::Redis(e))?;
        let conn = ConnectionManager::new(client)
            .await
            .map_err(|e| AppError::Redis(e))?;
        Ok(Self { conn })
    }

    // ── Refresh Tokens ──────────────────────────────────────────────────────

    /// Store a refresh token JTI with TTL
    pub async fn store_refresh_token(
        &self,
        user_id: &Uuid,
        jti: &str,
        exp_secs: u64,
    ) -> Result<(), AppError> {
        let mut c = self.conn.clone();
        let key = refresh_key(user_id, jti);
        c.set_ex::<_, _, ()>(&key, "1", exp_secs)
            .await
            .map_err(AppError::Redis)?;

        // Track all JTIs for a user (for revoke-all)
        let list_key = format!("rt_list:{user_id}");
        c.lpush::<_, _, ()>(&list_key, jti)
            .await
            .map_err(AppError::Redis)?;
        c.ltrim::<_, ()>(&list_key, 0, 9) // keep max 10 sessions
            .await
            .map_err(AppError::Redis)?;
        c.expire::<_, ()>(&list_key, exp_secs as i64)
            .await
            .map_err(AppError::Redis)?;

        Ok(())
    }

    /// Returns true if the JTI exists (token is valid, not revoked)
    pub async fn is_refresh_token_valid(&self, user_id: &Uuid, jti: &str) -> Result<bool, AppError> {
        let mut c = self.conn.clone();
        let exists: bool = c
            .exists(refresh_key(user_id, jti))
            .await
            .map_err(AppError::Redis)?;
        Ok(exists)
    }

    /// Revoke a specific refresh token
    pub async fn revoke_refresh_token(&self, user_id: &Uuid, jti: &str) -> Result<(), AppError> {
        let mut c = self.conn.clone();
        c.del::<_, ()>(refresh_key(user_id, jti))
            .await
            .map_err(AppError::Redis)?;
        Ok(())
    }

    /// Revoke ALL refresh tokens for a user (logout everywhere / security breach)
    pub async fn revoke_all_refresh_tokens(&self, user_id: &Uuid) -> Result<(), AppError> {
        let mut c = self.conn.clone();
        let list_key = format!("rt_list:{user_id}");
        let jtis: Vec<String> = c.lrange(&list_key, 0, -1).await.map_err(AppError::Redis)?;

        let mut pipe = redis::pipe();
        for jti in &jtis {
            pipe.del(refresh_key(user_id, jti));
        }
        pipe.del(&list_key);
        pipe.execute_async(&mut c).await.map_err(AppError::Redis)?;

        Ok(())
    }

    // ── Online Presence ─────────────────────────────────────────────────────

    pub async fn set_online(&self, user_id: &Uuid) -> Result<(), AppError> {
        let mut c = self.conn.clone();
        c.set_ex::<_, _, ()>(format!("online:{user_id}"), "1", 60)
            .await
            .map_err(AppError::Redis)?;
        Ok(())
    }

    pub async fn set_offline(&self, user_id: &Uuid) -> Result<(), AppError> {
        let mut c = self.conn.clone();
        c.del::<_, ()>(format!("online:{user_id}"))
            .await
            .map_err(AppError::Redis)?;
        Ok(())
    }

    pub async fn is_online(&self, user_id: &Uuid) -> Result<bool, AppError> {
        let mut c = self.conn.clone();
        let exists: bool = c
            .exists(format!("online:{user_id}"))
            .await
            .map_err(AppError::Redis)?;
        Ok(exists)
    }

    // ── Call Busy State ─────────────────────────────────────────────────────

    pub async fn set_busy(&self, user_id: &Uuid, call_id: &str) -> Result<(), AppError> {
        let mut c = self.conn.clone();
        c.set_ex::<_, _, ()>(format!("busy:{user_id}"), call_id, 300) // 5 min max call setup
            .await
            .map_err(AppError::Redis)?;
        Ok(())
    }

    pub async fn clear_busy(&self, user_id: &Uuid) -> Result<(), AppError> {
        let mut c = self.conn.clone();
        c.del::<_, ()>(format!("busy:{user_id}"))
            .await
            .map_err(AppError::Redis)?;
        Ok(())
    }

    pub async fn is_busy(&self, user_id: &Uuid) -> Result<bool, AppError> {
        let mut c = self.conn.clone();
        let exists: bool = c
            .exists(format!("busy:{user_id}"))
            .await
            .map_err(AppError::Redis)?;
        Ok(exists)
    }
}

fn refresh_key(user_id: &Uuid, jti: &str) -> String {
    format!("rt:{user_id}:{jti}")
}
