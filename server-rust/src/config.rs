use anyhow::{Context, Result};
use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    pub port: u16,
    pub database_url: String,
    pub redis_url: String,

    // JWT
    pub jwt_access_secret: Vec<u8>,
    pub jwt_refresh_secret: Vec<u8>,
    pub jwt_access_exp_secs: u64,
    pub jwt_refresh_exp_secs: u64,

    // Signaling message encryption key (AES-256-GCM, 32 bytes)
    pub signaling_secret: Vec<u8>,

    // App
    pub app_base_url: String,
    pub allowed_origins: Vec<String>,

    // Rate limiting
    pub auth_rate_per_minute: u32,
    pub api_rate_per_minute: u32,

    // TURN
    pub turn_urls: Option<String>,
    pub turn_username: Option<String>,
    pub turn_credential: Option<String>,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        dotenvy::dotenv().ok();

        let jwt_access_secret = env::var("JWT_ACCESS_SECRET")
            .context("JWT_ACCESS_SECRET not set")?
            .into_bytes();
        let jwt_refresh_secret = env::var("JWT_REFRESH_SECRET")
            .context("JWT_REFRESH_SECRET not set")?
            .into_bytes();

        let signaling_secret_hex = env::var("SIGNALING_SECRET")
            .context("SIGNALING_SECRET not set (generate: openssl rand -hex 32)")?;
        let signaling_secret = hex::decode(&signaling_secret_hex)
            .context("SIGNALING_SECRET must be 64-char hex string")?;
        anyhow::ensure!(signaling_secret.len() == 32, "SIGNALING_SECRET must be 32 bytes (64 hex chars)");

        Ok(Config {
            port: env::var("PORT")
                .unwrap_or_else(|_| "3000".into())
                .parse()?,
            database_url: env::var("DATABASE_URL")
                .context("DATABASE_URL not set")?,
            redis_url: env::var("REDIS_URL")
                .unwrap_or_else(|_| "redis://127.0.0.1:6379".into()),

            jwt_access_secret,
            jwt_refresh_secret,
            jwt_access_exp_secs: env::var("JWT_ACCESS_EXP_SECS")
                .unwrap_or_else(|_| "900".into())
                .parse()?,
            jwt_refresh_exp_secs: env::var("JWT_REFRESH_EXP_SECS")
                .unwrap_or_else(|_| "2592000".into())
                .parse()?,

            signaling_secret,

            app_base_url: env::var("APP_BASE_URL")
                .unwrap_or_else(|_| "https://yourapp.com".into()),
            allowed_origins: env::var("ALLOWED_ORIGINS")
                .unwrap_or_else(|_| "http://localhost:3000".into())
                .split(',')
                .map(|s| s.trim().to_string())
                .collect(),

            auth_rate_per_minute: env::var("AUTH_RATE_PER_MINUTE")
                .unwrap_or_else(|_| "10".into())
                .parse()?,
            api_rate_per_minute: env::var("API_RATE_PER_MINUTE")
                .unwrap_or_else(|_| "120".into())
                .parse()?,

            turn_urls: env::var("TURN_URLS").ok(),
            turn_username: env::var("TURN_USERNAME").ok(),
            turn_credential: env::var("TURN_CREDENTIAL").ok(),
        })
    }
}
