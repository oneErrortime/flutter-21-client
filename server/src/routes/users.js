const express = require('express');
const router = express.Router();
const User = require('../models/User');
const { authenticate } = require('../middleware/auth');

/**
 * GET /api/users/:userId
 * Look up user by their unique userId (for calling by ID)
 */
router.get('/:userId', authenticate, async (req, res) => {
  try {
    const user = await User.findOne({ userId: req.params.userId, isActive: true });
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    res.json({ user: user.toPublicJSON() });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

/**
 * GET /api/users/search?q=username
 * Search users by username (for adding contacts)
 */
router.get('/search', authenticate, async (req, res) => {
  try {
    const { q } = req.query;
    if (!q || q.length < 2) {
      return res.status(400).json({ error: 'Search query must be at least 2 characters' });
    }

    const users = await User.find({
      username: { $regex: q, $options: 'i' },
      isActive: true,
      userId: { $ne: req.user.userId } // exclude self
    }).limit(20);

    res.json({ users: users.map(u => u.toPublicJSON()) });
  } catch (err) {
    res.status(500).json({ error: 'Server error' });
  }
});

module.exports = router;
