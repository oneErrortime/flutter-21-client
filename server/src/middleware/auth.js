const { verifyAccessToken } = require('../utils/jwt');
const User = require('../models/User');
const logger = require('../utils/logger');

/**
 * HTTP request authentication middleware
 */
async function authenticate(req, res, next) {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'No token provided' });
    }

    const token = authHeader.slice(7);
    const decoded = verifyAccessToken(token);

    const user = await User.findOne({ userId: decoded.userId, isActive: true });
    if (!user) {
      return res.status(401).json({ error: 'User not found or inactive' });
    }

    req.user = user;
    next();
  } catch (err) {
    if (err.name === 'TokenExpiredError') {
      return res.status(401).json({ error: 'Token expired', code: 'TOKEN_EXPIRED' });
    }
    if (err.name === 'JsonWebTokenError') {
      return res.status(401).json({ error: 'Invalid token' });
    }
    logger.error('Auth middleware error:', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
}

/**
 * Validate WebSocket JWT token
 * Returns decoded payload or throws
 */
async function validateWsToken(token) {
  const decoded = verifyAccessToken(token);
  const user = await User.findOne({ userId: decoded.userId, isActive: true });
  if (!user) throw new Error('User not found');
  return user;
}

module.exports = { authenticate, validateWsToken };
