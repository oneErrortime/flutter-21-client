//! Cryptography module
//!
//! 1. Password hashing: Argon2id (OWASP PHC winner, memory-hard)
//! 2. Signaling message encryption: AES-256-GCM (AEAD)
//!    - SDP offer/answer and ICE candidates are encrypted so even if
//!      the signaling channel is somehow compromised, payloads are unreadable
//! 3. HKDF (RFC 5869) for deriving per-session keys
//! 4. Secure random token generation

use aes_gcm::{
    aead::{Aead, AeadCore, KeyInit, OsRng},
    Aes256Gcm, Key, Nonce,
};
use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2, Params, Version,
};
use hkdf::Hkdf;
use rand::Rng;
use sha2::Sha256;

use crate::errors::AppError;

// ── Password Hashing (Argon2id) ───────────────────────────────────────────────

pub fn hash_password(password: &str) -> Result<String, AppError> {
    // OWASP minimum parameters for Argon2id (2024):
    //   m=19456 KiB, t=2, p=1
    let params = Params::new(
        19_456,  // memory: ~19 MiB
        2,       // iterations
        1,       // parallelism
        None,
    )
    .map_err(|e| AppError::Crypto(e.to_string()))?;

    let argon2 = Argon2::new(argon2::Algorithm::Argon2id, Version::V0x13, params);
    let salt = SaltString::generate(&mut OsRng);

    argon2
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| AppError::Crypto(e.to_string()))
}

pub fn verify_password(password: &str, hash: &str) -> Result<bool, AppError> {
    let parsed = PasswordHash::new(hash)
        .map_err(|e| AppError::Crypto(e.to_string()))?;
    Ok(Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok())
}

// ── AES-256-GCM Signaling Encryption ─────────────────────────────────────────

pub struct SignalingCrypto {
    cipher: Aes256Gcm,
}

impl SignalingCrypto {
    /// Initialize with a 32-byte master key from config
    pub fn new(key_bytes: &[u8; 32]) -> Self {
        let key = Key::<Aes256Gcm>::from_slice(key_bytes);
        Self {
            cipher: Aes256Gcm::new(key),
        }
    }

    /// Encrypt a signaling payload (SDP/ICE) — returns `nonce_hex:ciphertext_hex`
    pub fn encrypt(&self, plaintext: &str) -> Result<String, AppError> {
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let ciphertext = self
            .cipher
            .encrypt(&nonce, plaintext.as_bytes())
            .map_err(|e| AppError::Crypto(e.to_string()))?;

        Ok(format!("{}:{}", hex::encode(nonce), hex::encode(ciphertext)))
    }

    /// Decrypt a signaling payload
    pub fn decrypt(&self, data: &str) -> Result<String, AppError> {
        let (nonce_hex, ct_hex) = data
            .split_once(':')
            .ok_or_else(|| AppError::Crypto("Invalid encrypted format".into()))?;

        let nonce_bytes = hex::decode(nonce_hex)
            .map_err(|e| AppError::Crypto(e.to_string()))?;
        let ct_bytes = hex::decode(ct_hex)
            .map_err(|e| AppError::Crypto(e.to_string()))?;

        let nonce = Nonce::from_slice(&nonce_bytes);
        let plaintext = self
            .cipher
            .decrypt(nonce, ct_bytes.as_ref())
            .map_err(|_| AppError::Crypto("Decryption failed — tampered payload?".into()))?;

        String::from_utf8(plaintext).map_err(|e| AppError::Crypto(e.to_string()))
    }
}

// ── HKDF Per-Session Key Derivation (RFC 5869) ─────────────────────────────

/// Derive a 32-byte session key from a master key + unique info string
/// Used for per-user or per-room derived keys
#[allow(dead_code)]
pub fn derive_key(master: &[u8], info: &[u8]) -> [u8; 32] {
    let hk = Hkdf::<Sha256>::new(None, master);
    let mut okm = [0u8; 32];
    hk.expand(info, &mut okm).expect("HKDF expand never fails for 32 bytes");
    okm
}

// ── Secure Random Tokens ──────────────────────────────────────────────────────

#[allow(dead_code)]
pub fn generate_token_id() -> String {
    let bytes: [u8; 32] = rand::thread_rng().gen();
    hex::encode(bytes)
}

#[allow(dead_code)]
pub fn generate_room_id() -> String {
    uuid::Uuid::new_v4().to_string()
}
