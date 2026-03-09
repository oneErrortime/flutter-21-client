/// signaling/sfu_relay.rs
///
/// Server-side WebRTC SFU (Selective Forwarding Unit) relay.
///
/// Architecture:
///   - Each SFU room has exactly one "media relay task" running on the server.
///   - The server terminates DTLS/ICE with each participant and re-forwards
///     RTP packets between them (no transcoding — pure relay).
///   - This avoids client NAT traversal issues entirely: clients connect to
///     the server, the server bridges them.
///
/// When to use SFU relay instead of pure P2P:
///   - Symmetric NAT / corporate firewalls (TURN is expensive; SFU is cheaper)
///   - Server-side recording (server has plaintext audio/video)
///   - Group calls > 2 participants (each sender uploads once; server fans out)
///   - Analytics / content moderation
///
/// Protocol:
///   Client → Server: call-sfu   {type, roomId, offer}
///   Server → Client: sfu-offer  {type, roomId, offer}   (to other participant)
///   Client → Server: sfu-answer {type, roomId, answer}
///   Client → Server: sfu-ice    {type, roomId, candidate}
///   Server → Client: sfu-ice    {type, roomId, candidate}
///   Client → Server: sfu-leave  {type, roomId}
///
/// NOTE: This file implements the signaling coordination layer.
/// Actual DTLS/ICE/RTP relay requires a dedicated media server process
/// (e.g. mediasoup, Janus, or a custom Tokio task with webrtc-rs).
/// The placeholders below show where to call out to that process.
///
/// For a production deployment, integrate one of:
///   a) mediasoup (Node.js, battle-tested) — call via REST API from Rust
///   b) livekit-server (Go) — call LiveKit SDK from Flutter client directly
///   c) Janus Gateway (C) — WebRTC gateway
///   d) webrtc-rs (Rust, alpha) — embed directly in this binary

use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc, time::Instant};
use tokio::sync::{Mutex, RwLock};
use uuid::Uuid;

use crate::{errors::AppError, signaling::hub::SignalingHub};

// ---------------------------------------------------------------------------
// SFU Room
// ---------------------------------------------------------------------------

/// Participant in an SFU relay room.
#[derive(Debug, Clone)]
pub struct SfuParticipant {
    pub user_id: Uuid,
    pub display_name: String,
    pub joined_at: Instant,
    /// Whether the participant has completed ICE/DTLS setup with the server.
    pub media_ready: bool,
}

/// An SFU relay room.
#[derive(Debug)]
pub struct SfuRoom {
    pub room_id: String,
    pub created_at: Instant,
    pub participants: HashMap<Uuid, SfuParticipant>,
    /// Maximum allowed participants (prevents abuse).
    pub max_participants: usize,
}

impl SfuRoom {
    pub fn new(room_id: String) -> Self {
        Self {
            room_id,
            created_at: Instant::now(),
            participants: HashMap::new(),
            max_participants: 16, // Sane default; adjust per plan
        }
    }

    pub fn add_participant(&mut self, p: SfuParticipant) -> Result<(), AppError> {
        if self.participants.len() >= self.max_participants {
            return Err(AppError::BadRequest("Room is full".into()));
        }
        self.participants.insert(p.user_id, p);
        Ok(())
    }

    pub fn remove_participant(&mut self, user_id: &Uuid) -> bool {
        self.participants.remove(user_id).is_some()
    }

    pub fn is_empty(&self) -> bool {
        self.participants.is_empty()
    }

    pub fn other_participants(&self, exclude: &Uuid) -> Vec<&SfuParticipant> {
        self.participants
            .values()
            .filter(|p| &p.user_id != exclude)
            .collect()
    }
}

// ---------------------------------------------------------------------------
// SFU Room Registry
// ---------------------------------------------------------------------------

/// Thread-safe registry of all active SFU rooms.
#[derive(Clone, Default)]
pub struct SfuRegistry {
    rooms: Arc<RwLock<HashMap<String, SfuRoom>>>,
}

impl SfuRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Remove empty rooms to free memory (call periodically).
    pub async fn reap_empty(&self) {
        let mut rooms: tokio::sync::RwLockWriteGuard<'_, HashMap<String, SfuRoom>> =
            self.rooms.write().await;
        rooms.retain(|_, room: &mut SfuRoom| !room.is_empty());
    }

    /// Get participant count for a room.
    pub async fn participant_count(&self, room_id: &str) -> usize {
        let rooms: tokio::sync::RwLockReadGuard<'_, HashMap<String, SfuRoom>> =
            self.rooms.read().await;
        rooms
            .get(room_id)
            .map(|r| r.participants.len())
            .unwrap_or(0)
    }
}

// ---------------------------------------------------------------------------
// SFU Signaling Dispatcher
// ---------------------------------------------------------------------------
//
// This is called from signaling/server.rs dispatch_message() when
// msg_type is one of: call-sfu, sfu-answer, sfu-ice, sfu-leave
// ---------------------------------------------------------------------------

/// Handle SFU signaling messages.
///
/// This function coordinates the SFU session setup:
///   1. Caller sends call-sfu → server creates/joins SFU room
///   2. Server forwards sfu-offer to other participants
///   3. Each participant sends sfu-answer → server sets up relay
///   4. ICE candidates flow via sfu-ice
///   5. sfu-leave cleans up
pub async fn handle_sfu_message(
    hub: &SignalingHub,
    sfu_rooms: &SfuRoomStore,
    from: Uuid,
    display_name: &str,
    msg_type: &str,
    parsed: &Value,
) -> Result<(), AppError> {
    match msg_type {
        "call-sfu" => handle_sfu_join(hub, sfu_rooms, from, display_name, parsed).await,
        "sfu-answer" => handle_sfu_answer(hub, sfu_rooms, from, parsed).await,
        "sfu-ice" => handle_sfu_ice(hub, sfu_rooms, from, parsed).await,
        "sfu-leave" => handle_sfu_leave(hub, sfu_rooms, from, parsed).await,
        _ => Ok(()),
    }
}

// ── Join / create SFU room ───────────────────────────────────────────────────

async fn handle_sfu_join(
    hub: &SignalingHub,
    store: &SfuRoomStore,
    from: Uuid,
    display_name: &str,
    parsed: &Value,
) -> Result<(), AppError> {
    let room_id = parsed
        .get("roomId")
        .and_then(Value::as_str)
        .ok_or_else(|| AppError::BadRequest("Missing roomId".into()))?
        .to_string();

    let offer = parsed
        .get("offer")
        .cloned()
        .ok_or_else(|| AppError::BadRequest("Missing offer".into()))?;

    let mut rooms = store.lock().await;
    let room = rooms
        .entry(room_id.clone())
        .or_insert_with(|| SfuRoom::new(room_id.clone()));

    // Check capacity
    if room.participants.len() >= room.max_participants {
        drop(rooms);
        hub.send_to(
            &from,
            json!({"type": "sfu-error", "roomId": room_id, "reason": "room_full"}).to_string(),
        )
        .await?;
        return Ok(());
    }

    // Add participant
    let participant = SfuParticipant {
        user_id: from,
        display_name: display_name.to_string(),
        joined_at: Instant::now(),
        media_ready: false,
    };

    let other_ids: Vec<Uuid> = room
        .other_participants(&from)
        .iter()
        .map(|p| p.user_id)
        .collect();

    room.add_participant(participant)?;

    // Notify existing participants of new joiner
    // In a real SFU: trigger the media server to create a new subscriber for
    // each existing participant's stream.
    for &other_id in &other_ids {
        let _ = hub
            .send_to(
                &other_id,
                json!({
                    "type": "sfu-peer-joined",
                    "roomId": room_id,
                    "peerId": from,
                    "displayName": display_name,
                })
                .to_string(),
            )
            .await;
    }

    drop(rooms);

    // ── Media server integration point ───────────────────────────────────────
    // In a production SFU, we would:
    //   1. Forward the offer to the media server (via REST or Unix socket)
    //   2. Receive an answer from the media server
    //   3. Send the answer back to the client
    //   4. Start ICE candidate exchange between client and media server
    //
    // Pseudocode:
    //   let answer = media_server.create_subscriber(room_id, from, offer).await?;
    //   hub.send_to(&from, json!({"type":"sfu-answer","roomId":room_id,"answer":answer})).await?;
    //
    // For now: echo the offer back as an ack and document the integration point.
    // ---------------------------------------------------------------------------

    // Acknowledge join
    hub.send_to(
        &from,
        json!({
            "type": "sfu-joined",
            "roomId": room_id,
            "peerCount": other_ids.len(),
            // In production: "answer": <media_server_answer>
        })
        .to_string(),
    )
    .await?;

    tracing::info!(
        user_id = %from,
        room_id = %room_id,
        peers = other_ids.len(),
        "User joined SFU room"
    );
    metrics::counter!("sfu.room_join").increment(1);

    Ok(())
}

// ── SFU answer ───────────────────────────────────────────────────────────────

async fn handle_sfu_answer(
    hub: &SignalingHub,
    store: &SfuRoomStore,
    from: Uuid,
    parsed: &Value,
) -> Result<(), AppError> {
    let room_id = parsed
        .get("roomId")
        .and_then(Value::as_str)
        .ok_or_else(|| AppError::BadRequest("Missing roomId".into()))?;

    let _answer = parsed
        .get("answer")
        .cloned()
        .ok_or_else(|| AppError::BadRequest("Missing answer".into()))?;

    // ── Media server integration point ───────────────────────────────────────
    // Forward answer to media server:
    //   media_server.set_remote_description(room_id, from, answer).await?;
    // Then mark participant as media-ready.
    // ---------------------------------------------------------------------------

    let mut rooms = store.lock().await;
    if let Some(room) = rooms.get_mut(room_id) {
        if let Some(p) = room.participants.get_mut(&from) {
            p.media_ready = true;
            tracing::debug!(
                user_id = %from,
                room_id = %room_id,
                "SFU participant media ready"
            );
        }
    }

    Ok(())
}

// ── SFU ICE candidate ─────────────────────────────────────────────────────────

async fn handle_sfu_ice(
    hub: &SignalingHub,
    store: &SfuRoomStore,
    from: Uuid,
    parsed: &Value,
) -> Result<(), AppError> {
    let room_id = parsed
        .get("roomId")
        .and_then(Value::as_str)
        .ok_or_else(|| AppError::BadRequest("Missing roomId".into()))?;

    let candidate = parsed
        .get("candidate")
        .cloned()
        .ok_or_else(|| AppError::BadRequest("Missing candidate".into()))?;

    // ── Media server integration point ───────────────────────────────────────
    // Forward ICE candidate to media server:
    //   media_server.add_ice_candidate(room_id, from, candidate).await?;
    // The media server will respond with its own candidates via a callback
    // that calls hub.send_to() with type "sfu-ice".
    // ---------------------------------------------------------------------------

    tracing::debug!(
        user_id = %from,
        room_id = %room_id,
        "SFU ICE candidate received"
    );
    metrics::counter!("sfu.ice_candidates").increment(1);

    Ok(())
}

// ── SFU leave ────────────────────────────────────────────────────────────────

async fn handle_sfu_leave(
    hub: &SignalingHub,
    store: &SfuRoomStore,
    from: Uuid,
    parsed: &Value,
) -> Result<(), AppError> {
    let room_id = parsed
        .get("roomId")
        .and_then(Value::as_str)
        .ok_or_else(|| AppError::BadRequest("Missing roomId".into()))?;

    let mut rooms = store.lock().await;
    if let Some(room) = rooms.get_mut(room_id) {
        let removed = room.remove_participant(&from);

        if removed {
            // Notify remaining participants
            let notify: Vec<Uuid> = room.participants.keys().copied().collect();

            for &other_id in &notify {
                let _ = hub
                    .send_to(
                        &other_id,
                        json!({
                            "type": "sfu-peer-left",
                            "roomId": room_id,
                            "peerId": from,
                        })
                        .to_string(),
                    )
                    .await;
            }

            // Clean up empty rooms
            if room.is_empty() {
                rooms.remove(room_id);
                tracing::info!(room_id = %room_id, "SFU room destroyed (empty)");
                metrics::gauge!("sfu.active_rooms").decrement(1.0);
            }

            tracing::info!(
                user_id = %from,
                room_id = %room_id,
                "User left SFU room"
            );
            metrics::counter!("sfu.room_leave").increment(1);
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Type alias for the room store used across handlers
// ---------------------------------------------------------------------------

/// Simple in-process room store.
/// Replace with DashMap<String, Arc<Mutex<SfuRoom>>> for production.
pub type SfuRoomStore = Arc<Mutex<HashMap<String, SfuRoom>>>;

pub fn new_sfu_room_store() -> SfuRoomStore {
    Arc::new(Mutex::new(HashMap::new()))
}

// ---------------------------------------------------------------------------
// Architecture notes: alternatives to WebRTC P2P
// ---------------------------------------------------------------------------
//
// Question: what transport protocols can deliver Zoom-like voice+video,
// very fast, with P2P + E2E encryption?
//
// 1. WebRTC (current)
//    - Standard: RFC 8825 (overview), RFC 8829 (JSEP), RFC 8445 (ICE),
//      RFC 5764 (DTLS-SRTP), RFC 3711 (SRTP)
//    - Pros: Universal browser/mobile support. DTLS-SRTP gives E2E auth.
//    - Latency: ~100–200ms typical; <50ms on LAN.
//    - Used by: WhatsApp, Google Meet (signaling layer), Discord.
//    - Codec: Opus (RFC 6716) for voice; VP8/VP9/AV1/H.264 for video.
//
// 2. QUIC + Noise Protocol (this repo's quic_noise_service.dart)
//    - Standards: RFC 9000 (QUIC), Noise Protocol Framework (Trevor Perrin)
//    - Pros: 0-RTT / 1-RTT handshake (vs 4-6 RTT for ICE+DTLS+SDP).
//      Seamless network migration (connection ID survives IP change).
//      No head-of-line blocking on audio/video streams.
//      ChaCha20-Poly1305 AEAD — as strong as DTLS-SRTP, simpler.
//    - Cons: No stable Dart QUIC library yet (cronet via platform channel
//      works on Android; requires FFI on iOS). Requires NAT traversal
//      (QUIC punching or relay — same problem as WebRTC ICE).
//    - Latency: <30ms on LAN; similar to WebRTC on WAN.
//    - Used by: HTTP/3, QUIC tunnels, some game engines.
//    - Flutter integration: Cronet (Android) or custom Swift (iOS).
//
// 3. SFU relay (this file)
//    - All media flows through server. No P2P NAT traversal.
//    - Pros: Zero client-side complexity; works through any firewall.
//      Enables server-side recording, moderation, simulcast.
//    - Cons: Server bears all bandwidth; no E2E unless SFrame (RFC 9605)
//      is used. Higher latency than direct P2P by ~20ms.
//    - This is what Zoom, Teams use. LiveKit implements this well.
//
// 4. LiveKit (SFU + SFrame E2E)
//    - Combines SFU scalability with E2E encryption via SFrame (RFC 9605).
//    - The SFU forwards encrypted frames without being able to decrypt them.
//    - Flutter SDK: livekit_client (pub.dev).
//    - This repo's livekit_service.dart has the integration skeleton.
//
// 5. Matrix / WebRTC over Matrix federation
//    - Decentralised signaling; media still WebRTC.
//    - Higher setup complexity; better privacy.
//
// 6. Janus / mediasoup (self-hosted SFU)
//    - Like LiveKit but open-source and self-hosted.
//    - mediasoup: Node.js + C++ media engine. Ultra-low latency.
//    - Janus: C gateway, very mature, supports recording.
//
// Recommendation for "very fast, like Zoom":
//   - 2 parties: WebRTC direct P2P (already in this repo, works well)
//     OR QUIC+Noise once the Dart QUIC library stabilises.
//   - 3+ parties: LiveKit SFU + livekit_client Flutter SDK.
//     Enables HD video grid, hand raise, screen share, background blur.
//   - All cases: Opus at 32–128kbps for voice. PLC (packet loss concealment)
//     and FEC (forward error correction) are built into the Opus/WebRTC stack.
//
// The TransportSelector in livekit_service.dart implements exactly this logic.
// ---------------------------------------------------------------------------
