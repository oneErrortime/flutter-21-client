const jwt = require('jsonwebtoken');

const JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'fallback_access_secret_change_in_prod';
const JWT_REFRESH_SECRET = process.env.JWT_REFRESH_SECRET || 'fallback_refresh_secret_change_in_prod';
const JWT_ACCESS_EXPIRES = process.env.JWT_ACCESS_EXPIRES || '15m';
const JWT_REFRESH_EXPIRES = process.env.JWT_REFRESH_EXPIRES || '30d';

/**
 * Generate access + refresh token pair
 */
function generateTokens(payload) {
  const accessToken = jwt.sign(payload, JWT_ACCESS_SECRET, {
    expiresIn: JWT_ACCESS_EXPIRES,
    algorithm: 'HS256'
  });
  const refreshToken = jwt.sign(payload, JWT_REFRESH_SECRET, {
    expiresIn: JWT_REFRESH_EXPIRES,
    algorithm: 'HS256'
  });
  return { accessToken, refreshToken };
}

/**
 * Verify access token
 */
function verifyAccessToken(token) {
  return jwt.verify(token, JWT_ACCESS_SECRET, { algorithms: ['HS256'] });
}

/**
 * Verify refresh token
 */
function verifyRefreshToken(token) {
  return jwt.verify(token, JWT_REFRESH_SECRET, { algorithms: ['HS256'] });
}

module.exports = { generateTokens, verifyAccessToken, verifyRefreshToken };
