//! VoiceCall Signaling Server — Rust / Axum / Tokio
//!
//! Features:
//!   - Multi-threaded Tokio runtime (1 thread per CPU core)
//!   - Axum web framework with native WebSocket support
//!   - PostgreSQL via sqlx (async, connection pool)
//!   - Redis pub/sub for horizontal scaling
//!   - AES-256-GCM encrypted signaling payloads
//!   - Argon2id password hashing
//!   - JWT with refresh token rotation + reuse detection
//!   - DashMap (lock-free concurrent HashMap for WS connections)
//!   - Tower rate limiting per IP (token bucket)
//!   - Prometheus metrics at /metrics
//!   - Graceful shutdown (SIGTERM/SIGINT)
//!   - Structured JSON logging (tracing + tracing-subscriber)

use std::{net::SocketAddr, sync::Arc, time::Duration};

use axum::{
    extract::State,
    http::{HeaderValue, Method, StatusCode},
    middleware,
    response::Json,
    routing::{get, post},
    Router,
};
use sqlx::postgres::PgPoolOptions;
use tower_http::{
    compression::CompressionLayer,
    cors::{Any, CorsLayer},
    limit::RequestBodyLimitLayer,
    timeout::TimeoutLayer,
    trace::TraceLayer,
};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

mod auth;
mod config;
mod crypto;
mod db;
mod errors;
mod metrics;
mod routes;
mod signaling;

use auth::{require_auth, JwtService};
use config::Config;
use crypto::SignalingCrypto;
use db::{redis_store::RedisStore, Database};
use signaling::{hub::SignalingHub, ws_handler};

/// Global application state — cloned cheaply (all fields are Arc<> or Clone)
#[derive(Clone)]
pub struct AppState {
    pub db: Database,
    pub redis: RedisStore,
    pub jwt: Arc<JwtService>,
    pub hub: SignalingHub,
    pub crypto: Arc<SignalingCrypto>,
    pub config: Arc<Config>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // ── Structured logging ─────────────────────────────────────────────────
    tracing_subscriber::registry()
        .with(EnvFilter::try_from_default_env().unwrap_or_else(|_| {
            "voicecall_server=debug,tower_http=info,axum=info".into()
        }))
        .with(
            tracing_subscriber::fmt::layer()
                .json()
                .with_current_span(true)
                .with_target(true),
        )
        .init();

    // ── Config ─────────────────────────────────────────────────────────────
    let config = Arc::new(Config::from_env()?);
    tracing::info!(port = config.port, "Starting VoiceCall server");

    // ── Prometheus metrics ─────────────────────────────────────────────────
    let _prom_handle = metrics::install();

    // ── Database (PostgreSQL connection pool) ──────────────────────────────
    let pool = PgPoolOptions::new()
        .max_connections(32)          // pool of 32 connections
        .min_connections(4)           // keep 4 warm at all times
        .acquire_timeout(Duration::from_secs(5))
        .idle_timeout(Duration::from_secs(600))
        .connect(&config.database_url)
        .await?;

    // Run migrations inline
    sqlx::query(db::MIGRATIONS).execute(&pool).await?;
    tracing::info!("PostgreSQL connected & migrated");

    let database = Database::new(pool);

    // ── Redis ──────────────────────────────────────────────────────────────
    let redis = RedisStore::new(&config.redis_url).await?;
    tracing::info!("Redis connected");

    // ── Redis pub/sub for cross-instance signaling ─────────────────────────
    let redis_client = redis::Client::open(config.redis_url.clone())?;
    let mut pubsub_conn = redis_client.get_async_pubsub().await?;

    // ── Signaling Hub ──────────────────────────────────────────────────────
    let hub = SignalingHub::new(redis.conn.clone());
    pubsub_conn
        .subscribe(&hub.channel)
        .await?;
    hub.spawn_redis_subscriber(pubsub_conn);

    // ── Signaling Crypto (AES-256-GCM) ────────────────────────────────────
    let key_bytes: [u8; 32] = config
        .signaling_secret
        .as_slice()
        .try_into()
        .expect("Signaling secret must be 32 bytes");
    let crypto = Arc::new(SignalingCrypto::new(&key_bytes));

    // ── JWT ────────────────────────────────────────────────────────────────
    let jwt = Arc::new(JwtService::new(
        &config.jwt_access_secret,
        &config.jwt_refresh_secret,
        config.jwt_access_exp_secs,
        config.jwt_refresh_exp_secs,
    ));

    // ── App State ──────────────────────────────────────────────────────────
    let state = AppState {
        db: database,
        redis,
        jwt,
        hub,
        crypto,
        config: config.clone(),
    };

    // ── CORS ───────────────────────────────────────────────────────────────
    let cors = CorsLayer::new()
        .allow_origin(
            config
                .allowed_origins
                .iter()
                .map(|o| o.parse::<HeaderValue>().unwrap())
                .collect::<Vec<_>>(),
        )
        .allow_methods([Method::GET, Method::POST, Method::DELETE, Method::OPTIONS])
        .allow_headers(Any)
        .allow_credentials(true);

    // ── Router ─────────────────────────────────────────────────────────────
    let auth_routes = Router::new()
        .route("/register", post(routes::auth::register))
        .route("/login", post(routes::auth::login))
        .route("/refresh", post(routes::auth::refresh))
        .route(
            "/logout",
            post(routes::auth::logout)
                .route_layer(middleware::from_fn_with_state(state.clone(), require_auth)),
        )
        .route(
            "/me",
            get(routes::auth::me)
                .route_layer(middleware::from_fn_with_state(state.clone(), require_auth)),
        );

    // user_routes — search must be declared before the :user_id catch-all
    let user_routes = Router::new()
        .route("/search", get(routes::search_users))
        .route("/:user_id", get(routes::get_user))
        .route_layer(middleware::from_fn_with_state(state.clone(), require_auth));

    let room_routes = Router::new()
        .route("/", post(routes::create_room))
        .route("/:room_id", get(routes::get_room))
        .route_layer(middleware::from_fn_with_state(state.clone(), require_auth));

    let app = Router::new()
        // WebSocket signaling
        .route("/ws", get(ws_handler))
        // REST API
        .nest("/api/auth", auth_routes)
        .nest("/api/users", user_routes)
        .nest("/api/rooms", room_routes)
        // Health check
        .route("/health", get(health_handler))
        // TURN credentials (served to authenticated clients)
        .route(
            "/api/ice-config",
            get(ice_config_handler)
                .route_layer(middleware::from_fn_with_state(state.clone(), require_auth)),
        )
        // Prometheus metrics (internal — protect with firewall/auth in production)
        .route("/metrics", get(metrics::metrics_handler))
        // Shared state
        .with_state(state)
        // Global middleware stack — applied outermost-first via chained .layer()
        // tower-http 0.5 + axum 0.7: chained .layer() avoids the
        // `ResponseBody<Body>: Default` bound that ServiceBuilder triggers.
        .layer(TraceLayer::new_for_http())
        .layer(CompressionLayer::new())
        .layer(TimeoutLayer::new(Duration::from_secs(30)))
        .layer(RequestBodyLimitLayer::new(64 * 1024)) // 64 KB max body
        .layer(cors)
        // Fallback
        .fallback(|| async { (StatusCode::NOT_FOUND, Json(serde_json::json!({"error":"Not found"}))) });

    // ── Bind & Serve ───────────────────────────────────────────────────────
    let addr: SocketAddr = format!("0.0.0.0:{}", config.port).parse()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(addr = %addr, "Listening");

    // Graceful shutdown on SIGTERM or Ctrl-C
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    tracing::info!("Server shut down gracefully");
    Ok(())
}

async fn health_handler() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
        "timestamp": chrono::Utc::now().to_rfc3339()
    }))
}

async fn ice_config_handler(
    State(state): State<AppState>,
) -> Json<serde_json::Value> {
    let mut ice_servers = vec![
        serde_json::json!({"urls": "stun:stun.l.google.com:19302"}),
        serde_json::json!({"urls": "stun:stun1.l.google.com:19302"}),
    ];

    if let (Some(urls), Some(user), Some(cred)) = (
        &state.config.turn_urls,
        &state.config.turn_username,
        &state.config.turn_credential,
    ) {
        ice_servers.push(serde_json::json!({
            "urls": urls,
            "username": user,
            "credential": cred
        }));
    }

    Json(serde_json::json!({ "iceServers": ice_servers }))
}

async fn shutdown_signal() {
    use tokio::signal;

    let ctrl_c = async {
        signal::ctrl_c().await.expect("failed to listen for Ctrl-C");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => tracing::info!("Ctrl-C received"),
        _ = terminate => tracing::info!("SIGTERM received"),
    }
}
