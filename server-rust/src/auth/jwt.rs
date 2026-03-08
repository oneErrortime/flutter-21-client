use chrono::{Duration, Utc};
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::errors::AppError;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Claims {
    pub sub: String,     // userId
    pub jti: String,     // unique token ID (for revocation)
    pub exp: i64,
    pub iat: i64,
    pub nbf: i64,
}

pub struct JwtService {
    access_encoding: EncodingKey,
    access_decoding: DecodingKey,
    refresh_encoding: EncodingKey,
    refresh_decoding: DecodingKey,
    access_exp_secs: u64,
    refresh_exp_secs: u64,
}

impl JwtService {
    pub fn new(
        access_secret: &[u8],
        refresh_secret: &[u8],
        access_exp_secs: u64,
        refresh_exp_secs: u64,
    ) -> Self {
        Self {
            access_encoding: EncodingKey::from_secret(access_secret),
            access_decoding: DecodingKey::from_secret(access_secret),
            refresh_encoding: EncodingKey::from_secret(refresh_secret),
            refresh_decoding: DecodingKey::from_secret(refresh_secret),
            access_exp_secs,
            refresh_exp_secs,
        }
    }

    pub fn generate_access_token(&self, user_id: &Uuid) -> Result<String, AppError> {
        self.sign(&self.access_encoding, user_id, self.access_exp_secs)
    }

    pub fn generate_refresh_token(&self, user_id: &Uuid) -> Result<String, AppError> {
        self.sign(&self.refresh_encoding, user_id, self.refresh_exp_secs)
    }

    fn sign(&self, key: &EncodingKey, user_id: &Uuid, exp_secs: u64) -> Result<String, AppError> {
        let now = Utc::now();
        let claims = Claims {
            sub: user_id.to_string(),
            jti: Uuid::new_v4().to_string(),
            iat: now.timestamp(),
            nbf: now.timestamp(),
            exp: (now + Duration::seconds(exp_secs as i64)).timestamp(),
        };
        encode(&Header::new(Algorithm::HS256), &claims, key)
            .map_err(|e| AppError::Unauthorized(e.to_string()))
    }

    pub fn verify_access(&self, token: &str) -> Result<Claims, AppError> {
        self.verify(token, &self.access_decoding)
    }

    pub fn verify_refresh(&self, token: &str) -> Result<Claims, AppError> {
        self.verify(token, &self.refresh_decoding)
    }

    fn verify(&self, token: &str, key: &DecodingKey) -> Result<Claims, AppError> {
        let mut validation = Validation::new(Algorithm::HS256);
        validation.validate_exp = true;
        validation.validate_nbf = true;
        decode::<Claims>(token, key, &validation)
            .map(|data| data.claims)
            .map_err(|e| {
                use jsonwebtoken::errors::ErrorKind;
                match e.kind() {
                    ErrorKind::ExpiredSignature => AppError::Unauthorized("TOKEN_EXPIRED".into()),
                    _ => AppError::Unauthorized(format!("Invalid token: {e}")),
                }
            })
    }
}
