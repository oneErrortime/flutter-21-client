/// WebRTC Signaling Server Handler
///
/// Handles WebSocket connections with:
///   - Per-connection async tasks (no shared Mutex per message)
///   - Split read/write channels via mpsc
///   - Encrypted signaling payloads (AES-256-GCM)
///   - RFC 8825 / 8829 / 8445 compliant message types

use axum::{
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    response::Response,
};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::{errors::AppError, AppState};
use super::hub::SignalingHub;

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Response {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut ws_write, mut ws_read) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();

    let mut user_id: Option<Uuid> = None;
    let hub = state.hub.clone();

    // Spawn write task: drains the mpsc channel → WebSocket
    // This means sending to a client never blocks the read loop
    let write_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if ws_write.send(Message::Text(msg)).await.is_err() {
                break;
            }
        }
    });

    // Read loop
    'outer: while let Some(Ok(msg)) = ws_read.next().await {
        let text = match msg {
            Message::Text(t) => t,
            Message::Ping(d) => {
                // auto-handled by axum, but track alive
                continue;
            }
            Message::Close(_) => break,
            _ => continue,
        };

        let parsed: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => {
                let _ = tx.send(json!({"type":"error","message":"Invalid JSON"}).to_string());
                continue;
            }
        };

        let msg_type = match parsed.get("type").and_then(Value::as_str) {
            Some(t) => t.to_string(),
            None => continue,
        };

        // ── AUTH ────────────────────────────────────────────────────────────
        if msg_type == "auth" {
            let token = match parsed.get("token").and_then(Value::as_str) {
                Some(t) => t,
                None => {
                    let _ = tx.send(json!({"type":"auth-error","message":"Missing token"}).to_string());
                    break;
                }
            };

            match state.jwt.verify_access(token) {
                Ok(claims) => {
                    let uid = match Uuid::parse_str(&claims.sub) {
                        Ok(u) => u,
                        Err(_) => break,
                    };
                    // Verify user active
                    match state.db.user_is_active(&uid).await {
                        Ok(true) => {}
                        _ => {
                            let _ = tx.send(json!({"type":"auth-error","message":"User inactive"}).to_string());
                            break;
                        }
                    }

                    user_id = Some(uid);
                    hub.register(uid, tx.clone());
                    let _ = state.redis.set_online(&uid).await;
                    let _ = state.db.update_last_seen(&uid).await;

                    let user = state.db.find_user_by_id(&uid).await.ok().flatten();
                    let display_name = user
                        .as_ref()
                        .map(|u| u.display_name.clone())
                        .unwrap_or_default();

                    let _ = tx.send(json!({
                        "type": "auth-success",
                        "userId": uid,
                        "displayName": display_name
                    }).to_string());

                    tracing::info!(user_id = %uid, "WS authenticated");
                    metrics::counter!("ws.auth.success").increment(1);
                }
                Err(_) => {
                    let _ = tx.send(json!({"type":"auth-error","message":"Invalid token"}).to_string());
                    break;
                }
            }
            continue;
        }

        // All subsequent messages require authentication
        let uid = match user_id {
            Some(id) => id,
            None => {
                let _ = tx.send(json!({"type":"error","message":"Not authenticated"}).to_string());
                continue;
            }
        };

        // ── PROCESS SIGNALING MESSAGES ───────────────────────────────────────
        if let Err(e) = dispatch_message(&state, &hub, uid, &msg_type, &parsed).await {
            tracing::warn!(user_id = %uid, error = %e, msg_type = %msg_type, "Signaling error");
            let _ = tx.send(json!({"type":"error","message": e.to_string()}).to_string());
        }
    }

    // Cleanup
    if let Some(uid) = user_id {
        hub.deregister(&uid);
        let _ = state.redis.set_offline(&uid).await;
        let _ = state.redis.clear_busy(&uid).await;
        let _ = state.db.update_last_seen(&uid).await;
        tracing::info!(user_id = %uid, "WS disconnected");
    }

    write_task.abort();
}

async fn dispatch_message(
    state: &AppState,
    hub: &SignalingHub,
    from: Uuid,
    msg_type: &str,
    msg: &Value,
) -> Result<(), AppError> {
    match msg_type {
        // ── DIRECT CALL BY USER ID ─────────────────────────────────────────
        "call" => {
            let to = parse_uuid(msg, "to")?;
            let offer = require_field(msg, "offer")?;

            if to == from {
                return Err(AppError::BadRequest("Cannot call yourself".into()));
            }
            if !hub.is_connected(&to) {
                hub.send_to(&from, json!({"type":"user-offline","targetId": to}).to_string()).await?;
                return Ok(());
            }
            if state.redis.is_busy(&to).await? {
                hub.send_to(&from, json!({"type":"user-busy","targetId": to}).to_string()).await?;
                return Ok(());
            }

            // Mark both busy
            let call_id = format!("{}-{}-{}", from, to, chrono::Utc::now().timestamp_millis());
            state.redis.set_busy(&from, &call_id).await?;
            state.redis.set_busy(&to, &call_id).await?;

            // Encrypt the SDP offer payload
            let encrypted_offer = state.crypto.encrypt(&offer.to_string())?;

            let caller_info = state.db.find_user_by_id(&from).await?.map(|u| u.display_name).unwrap_or_default();
            hub.send_to(&to, json!({
                "type": "call-incoming",
                "from": from,
                "callerName": caller_info,
                "offer": encrypted_offer,
                "callId": call_id
            }).to_string()).await?;

            tracing::info!(from = %from, to = %to, call_id = %call_id, "Call initiated");
            metrics::counter!("calls.initiated").increment(1);
        }

        // ── ANSWER ─────────────────────────────────────────────────────────
        "answer" => {
            let to = parse_uuid(msg, "to")?;
            let answer = require_field(msg, "answer")?;
            let encrypted_answer = state.crypto.encrypt(&answer.to_string())?;
            hub.send_to(&to, json!({
                "type": "call-answered",
                "answer": encrypted_answer
            }).to_string()).await?;
        }

        // ── ICE CANDIDATE (RFC 8445) ────────────────────────────────────────
        "ice" => {
            let to = parse_uuid(msg, "to")?;
            let candidate = require_field(msg, "candidate")?;
            // Encrypt ICE candidates too (contain IP addresses)
            let encrypted = state.crypto.encrypt(&candidate.to_string())?;
            hub.send_to(&to, json!({
                "type": "ice",
                "candidate": encrypted,
                "from": from
            }).to_string()).await?;
        }

        // ── DECLINE ─────────────────────────────────────────────────────────
        "decline" => {
            let to = parse_uuid(msg, "to")?;
            let reason = msg.get("reason").and_then(Value::as_str).unwrap_or("declined");
            hub.send_to(&to, json!({
                "type": "call-declined",
                "reason": reason
            }).to_string()).await?;
            state.redis.clear_busy(&from).await?;
            state.redis.clear_busy(&to).await?;
        }

        // ── HANGUP ──────────────────────────────────────────────────────────
        "hangup" => {
            let to = parse_uuid(msg, "to")?;
            hub.send_to(&to, json!({"type": "hangup"}).to_string()).await?;
            state.redis.clear_busy(&from).await?;
            state.redis.clear_busy(&to).await?;
            metrics::counter!("calls.ended").increment(1);
            tracing::info!(from = %from, to = %to, "Call hung up");
        }

        // ── ROOM: CREATE ────────────────────────────────────────────────────
        "create-room" => {
            let room = state.db.create_room(&from).await?;
            let link = format!("{}/join/{}", state.config.app_base_url, room.room_id);
            hub.send_to(&from, json!({
                "type": "room-created",
                "roomId": room.room_id,
                "link": link
            }).to_string()).await?;
        }

        // ── ROOM: HOST (creator comes online after creating link) ───────────
        "room-host" => {
            let room_id_str = msg.get("roomId").and_then(Value::as_str)
                .ok_or(AppError::BadRequest("Missing roomId".into()))?;
            hub.send_to(&from, json!({"type":"room-host-ack","roomId": room_id_str}).to_string()).await?;
            // Store host mapping in Redis
            let mut conn = state.redis.conn.clone();
            let _ = redis::cmd("SETEX")
                .arg(format!("room_host:{room_id_str}"))
                .arg(86400u64)
                .arg(from.to_string())
                .query_async::<()>(&mut conn)
                .await;
        }

        // ── ROOM: JOIN (joiner sends offer) ─────────────────────────────────
        "join-room" => {
            let room_id_str = msg.get("roomId").and_then(Value::as_str)
                .ok_or(AppError::BadRequest("Missing roomId".into()))?;
            let room_id = Uuid::parse_str(room_id_str)
                .map_err(|_| AppError::BadRequest("Invalid roomId".into()))?;

            let room = state.db.find_room(&room_id).await?
                .ok_or(AppError::NotFound("Room not found or expired".into()))?;

            let offer = require_field(msg, "offer")?;
            let encrypted_offer = state.crypto.encrypt(&offer.to_string())?;

            let joiner_info = state.db.find_user_by_id(&from).await?.map(|u| u.display_name).unwrap_or_default();

            // FIX: Store joiner ID in Redis so room-ice can route back to them
            let mut conn = state.redis.conn.clone();
            let joiner_key = format!("room_joiner:{room_id_str}");
            let _ = redis::cmd("SETEX")
                .arg(&joiner_key)
                .arg(86400u64)
                .arg(from.to_string())
                .query_async::<()>(&mut conn)
                .await;

            // Notify host
            hub.send_to(&room.created_by, json!({
                "type": "room-joined",
                "offer": encrypted_offer,
                "joinerId": from,  // FIX: pass joinerId so host can include it in room-answer
                "joinerName": joiner_info,
                "roomId": room_id_str
            }).to_string()).await?;
        }

        // ── ROOM: ANSWER (host answers joiner) ──────────────────────────────
        "room-answer" => {
            let room_id_str = msg.get("roomId").and_then(Value::as_str)
                .ok_or(AppError::BadRequest("Missing roomId".into()))?;
            let answer = require_field(msg, "answer")?;
            let encrypted_answer = state.crypto.encrypt(&answer.to_string())?;

            // FIX: Flutter now sends joinerId in room-answer (fixed on client side).
            // Fallback: look up joiner from Redis if joinerId missing (backward compat).
            let joiner_id = if let Some(jid_str) = msg.get("joinerId").and_then(Value::as_str) {
                Uuid::parse_str(jid_str)
                    .map_err(|_| AppError::BadRequest("Invalid joinerId".into()))?
            } else {
                let mut conn = state.redis.conn.clone();
                let joiner_key = format!("room_joiner:{room_id_str}");
                let jid_str: String = redis::cmd("GET")
                    .arg(&joiner_key)
                    .query_async(&mut conn)
                    .await
                    .map_err(|_| AppError::NotFound("Joiner not found for room".into()))?;
                Uuid::parse_str(&jid_str)
                    .map_err(|_| AppError::Internal(anyhow::anyhow!("Invalid stored joiner id")))?
            };

            hub.send_to(&joiner_id, json!({
                "type": "room-answered",
                "answer": encrypted_answer,
                "roomId": room_id_str
            }).to_string()).await?;
        }

        // ── ROOM: ICE ────────────────────────────────────────────────────────
        "room-ice" => {
            // FIX: Flutter sends 'roomId', not 'to'
            let room_id_str = msg.get("roomId").and_then(Value::as_str)
                .ok_or(AppError::BadRequest("Missing roomId".into()))?;
            let room_id = Uuid::parse_str(room_id_str)
                .map_err(|_| AppError::BadRequest("Invalid roomId".into()))?;
            let role = msg.get("role").and_then(Value::as_str).unwrap_or("caller");
            let candidate = require_field(msg, "candidate")?;
            let encrypted = state.crypto.encrypt(&candidate.to_string())?;

            // Route based on role: 'caller' sent by host → forward to joiner, and vice versa
            // Lookup room to find the other participant
            let room = state.db.find_room(&room_id).await?
                .ok_or(AppError::NotFound("Room not found".into()))?;

            // The host is room.created_by; joiner is the other party
            // Role indicates who sent this ICE candidate (their position in the call)
            let mut conn = state.redis.conn.clone();
            let joiner_key = format!("room_joiner:{room_id_str}");
            let joiner_id_str: Option<String> = redis::cmd("GET")
                .arg(&joiner_key)
                .query_async(&mut conn)
                .await
                .ok();

            let target = if role == "caller" {
                // host sent → forward to joiner
                joiner_id_str.and_then(|s| Uuid::parse_str(&s).ok())
            } else {
                // joiner sent → forward to host
                Some(room.created_by)
            };

            if let Some(target_id) = target {
                hub.send_to(&target_id, json!({
                    "type": "room-ice",
                    "candidate": encrypted,
                    "from": from
                }).to_string()).await?;
            }
        }

        // ── HEARTBEAT ────────────────────────────────────────────────────────
        "heartbeat" => {
            // Refresh online TTL in Redis
            let _ = state.redis.set_online(&from).await;
            hub.send_to(&from, json!({"type":"heartbeat-ack"}).to_string()).await?;
        }

        other => {
            tracing::warn!(user_id = %from, msg_type = %other, "Unknown message type");
        }
    }
    Ok(())
}

fn parse_uuid(msg: &Value, field: &str) -> Result<Uuid, AppError> {
    msg.get(field)
        .and_then(Value::as_str)
        .ok_or_else(|| AppError::BadRequest(format!("Missing field: {field}")))?
        .parse::<Uuid>()
        .map_err(|_| AppError::BadRequest(format!("Invalid UUID in field: {field}")))
}

fn require_field<'a>(msg: &'a Value, field: &str) -> Result<&'a Value, AppError> {
    msg.get(field)
        .ok_or_else(|| AppError::BadRequest(format!("Missing field: {field}")))
}
