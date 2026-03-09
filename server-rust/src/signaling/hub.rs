//! Signaling Hub
//!
//! Manages WebSocket connections across all server instances using:
//!   - DashMap for O(1) concurrent local lookups (no Mutex/RwLock contention)
//!   - Redis Pub/Sub for cross-instance message routing
//!     (horizontal scaling: multiple server pods behind a load balancer)
//!
//! Message flow:
//!   Client A → WS → Server 1 → Redis pub → Server 2 → WS → Client B
//!                   (if B is on same server: direct send, skip Redis)

use dashmap::DashMap;
use redis::{aio::ConnectionManager, AsyncCommands};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::errors::AppError;

/// An outbound message sender for a WebSocket connection
pub type WsTx = mpsc::UnboundedSender<String>;

#[derive(Clone)]
pub struct SignalingHub {
    /// user_id → WsTx (local connections only)
    connections: Arc<DashMap<Uuid, WsTx>>,
    redis: ConnectionManager,
    /// Channel name for Redis pub/sub
    pub channel: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct HubMessage {
    pub to: Uuid,
    pub payload: String, // JSON-encoded signaling message
}

impl SignalingHub {
    pub fn new(redis: ConnectionManager) -> Self {
        Self {
            connections: Arc::new(DashMap::new()),
            redis,
            channel: "signaling:messages".into(),
        }
    }

    /// Register a new WebSocket connection
    pub fn register(&self, user_id: Uuid, tx: WsTx) {
        // Close existing connection if any (session replacement)
        if let Some(old) = self.connections.get(&user_id) {
            let _ = old.send(r#"{"type":"session-replaced"}"#.into());
        }
        self.connections.insert(user_id, tx);
        metrics::gauge!("ws.connected_clients").set(self.connections.len() as f64);
        tracing::debug!(user_id = %user_id, "WS registered");
    }

    /// Deregister on disconnect
    pub fn deregister(&self, user_id: &Uuid) {
        self.connections.remove(user_id);
        metrics::gauge!("ws.connected_clients").set(self.connections.len() as f64);
        tracing::debug!(user_id = %user_id, "WS deregistered");
    }

    pub fn is_connected(&self, user_id: &Uuid) -> bool {
        self.connections.contains_key(user_id)
    }

    /// Send a message to a user — local first, Redis pub/sub fallback
    pub async fn send_to(&self, to: &Uuid, message: String) -> Result<(), AppError> {
        if let Some(tx) = self.connections.get(to) {
            // Local delivery — zero latency
            let _ = tx.send(message.clone());
            return Ok(());
        }

        // Remote delivery via Redis pub/sub (other server instance handles it)
        let hub_msg = HubMessage {
            to: *to,
            payload: message,
        };
        let serialized =
            serde_json::to_string(&hub_msg).map_err(|e| AppError::Internal(e.into()))?;
        let mut conn = self.redis.clone();
        conn.publish::<_, _, ()>(&self.channel, serialized)
            .await
            .map_err(AppError::Redis)?;
        Ok(())
    }

    /// Spawn a Redis subscriber task that delivers messages from other instances
    pub fn spawn_redis_subscriber(&self, mut sub_conn: redis::aio::PubSub) {
        let connections = self.connections.clone();
        let _channel = self.channel.clone();

        tokio::spawn(async move {
            loop {
                if let Some(msg) = sub_conn.on_message().next().await {
                    let payload: String = match msg.get_payload() {
                        Ok(p) => p,
                        Err(_) => continue,
                    };
                    if let Ok(hub_msg) = serde_json::from_str::<HubMessage>(&payload) {
                        if let Some(tx) = connections.get(&hub_msg.to) {
                            let _ = tx.send(hub_msg.payload);
                        }
                        // If not on this instance, ignore (another instance will pick it up)
                    }
                }
            }
        });
    }
}

// We need this import for the subscriber spawn
use futures_util::StreamExt;
