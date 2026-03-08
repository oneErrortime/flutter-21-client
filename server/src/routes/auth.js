const express = require('express');
const router = express.Router();
const User = require('../models/User');
const { generateTokens, verifyRefreshToken } = require('../utils/jwt');
const { authenticate } = require('../middleware/auth');
const logger = require('../utils/logger');

/**
 * POST /api/auth/register
 * Register a new user
 */
router.post('/register', async (req, res) => {
  try {
    const { username, email, password, displayName } = req.body;

    // Validation
    if (!username || !email || !password || !displayName) {
      return res.status(400).json({ error: 'All fields are required' });
    }
    if (password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }
    if (password.length > 128) {
      return res.status(400).json({ error: 'Password too long' });
    }

    // Check existing
    const existing = await User.findOne({ $or: [{ email }, { username }] });
    if (existing) {
      if (existing.email === email.toLowerCase()) {
        return res.status(409).json({ error: 'Email already in use' });
      }
      return res.status(409).json({ error: 'Username already taken' });
    }

    // Create user
    const user = new User({
      username,
      email,
      displayName,
      passwordHash: password // will be hashed in pre-save hook
    });
    await user.save();

    const tokens = generateTokens({ userId: user.userId });

    // Store refresh token
    user.refreshTokens = [tokens.refreshToken];
    await user.save({ validateBeforeSave: false });

    logger.info(`New user registered: ${user.userId}`);
    res.status(201).json({
      user: user.toPublicJSON(),
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken
    });
  } catch (err) {
    logger.error('Register error:', err);
    res.status(500).json({ error: 'Registration failed' });
  }
});

/**
 * POST /api/auth/login
 * Authenticate user
 */
router.post('/login', async (req, res) => {
  try {
    const { identifier, password } = req.body; // identifier = email or username
    if (!identifier || !password) {
      return res.status(400).json({ error: 'Identifier and password are required' });
    }

    const user = await User.findOne({
      $or: [
        { email: identifier.toLowerCase() },
        { username: identifier }
      ],
      isActive: true
    }).select('+passwordHash +refreshTokens');

    if (!user) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const isValid = await user.comparePassword(password);
    if (!isValid) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const tokens = generateTokens({ userId: user.userId });

    // Rotate refresh tokens (max 5 concurrent sessions)
    const refreshTokens = user.refreshTokens || [];
    refreshTokens.push(tokens.refreshToken);
    if (refreshTokens.length > 5) refreshTokens.shift();
    user.refreshTokens = refreshTokens;
    user.lastSeen = new Date();
    await user.save({ validateBeforeSave: false });

    logger.info(`User logged in: ${user.userId}`);
    res.json({
      user: user.toPublicJSON(),
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken
    });
  } catch (err) {
    logger.error('Login error:', err);
    res.status(500).json({ error: 'Login failed' });
  }
});

/**
 * POST /api/auth/refresh
 * Refresh access token
 */
router.post('/refresh', async (req, res) => {
  try {
    const { refreshToken } = req.body;
    if (!refreshToken) {
      return res.status(400).json({ error: 'Refresh token required' });
    }

    let decoded;
    try {
      decoded = verifyRefreshToken(refreshToken);
    } catch (err) {
      return res.status(401).json({ error: 'Invalid or expired refresh token' });
    }

    const user = await User.findOne({ userId: decoded.userId, isActive: true })
      .select('+refreshTokens');

    if (!user || !user.refreshTokens.includes(refreshToken)) {
      // Potential token reuse attack - invalidate all sessions
      if (user) {
        user.refreshTokens = [];
        await user.save({ validateBeforeSave: false });
        logger.warn(`Refresh token reuse detected for user: ${decoded.userId}`);
      }
      return res.status(401).json({ error: 'Refresh token invalid or reused' });
    }

    // Rotate: remove old, add new
    const tokens = generateTokens({ userId: user.userId });
    user.refreshTokens = user.refreshTokens
      .filter(t => t !== refreshToken)
      .concat(tokens.refreshToken)
      .slice(-5);
    await user.save({ validateBeforeSave: false });

    res.json({
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken
    });
  } catch (err) {
    logger.error('Refresh error:', err);
    res.status(500).json({ error: 'Token refresh failed' });
  }
});

/**
 * POST /api/auth/logout
 * Revoke refresh token
 */
router.post('/logout', authenticate, async (req, res) => {
  try {
    const { refreshToken } = req.body;
    const user = await User.findOne({ userId: req.user.userId }).select('+refreshTokens');
    if (user && refreshToken) {
      user.refreshTokens = user.refreshTokens.filter(t => t !== refreshToken);
      await user.save({ validateBeforeSave: false });
    }
    res.json({ message: 'Logged out successfully' });
  } catch (err) {
    logger.error('Logout error:', err);
    res.status(500).json({ error: 'Logout failed' });
  }
});

/**
 * GET /api/auth/me
 * Get current user info
 */
router.get('/me', authenticate, (req, res) => {
  res.json({ user: req.user.toPublicJSON() });
});

module.exports = router;
