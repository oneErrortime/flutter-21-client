const express = require('express');
const router = express.Router();
const Room = require('../models/Room');
const { authenticate } = require('../middleware/auth');
const logger = require('../utils/logger');

/**
 * POST /api/rooms
 * Create a new call room link
 */
router.post('/', authenticate, async (req, res) => {
  try {
    const room = new Room({ createdBy: req.user.userId });
    await room.save();

    const link = `${process.env.APP_BASE_URL || 'https://yourapp.com'}/join/${room.roomId}`;
    logger.info(`Room created: ${room.roomId} by ${req.user.userId}`);

    res.status(201).json({
      roomId: room.roomId,
      link,
      expiresAt: room.expiresAt
    });
  } catch (err) {
    logger.error('Create room error:', err);
    res.status(500).json({ error: 'Failed to create room' });
  }
});

/**
 * GET /api/rooms/:roomId
 * Validate room exists and is active (for deep link handling)
 */
router.get('/:roomId', authenticate, async (req, res) => {
  try {
    const room = await Room.findOne({ roomId: req.params.roomId, isActive: true });
    if (!room || room.expiresAt < new Date()) {
      return res.status(404).json({ error: 'Room not found or expired' });
    }

    const creator = await require('../models/User').findOne({ userId: room.createdBy });

    res.json({
      roomId: room.roomId,
      createdBy: creator ? creator.toPublicJSON() : null,
      expiresAt: room.expiresAt
    });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

module.exports = router;
