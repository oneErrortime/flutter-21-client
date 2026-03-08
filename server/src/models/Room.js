const mongoose = require('mongoose');
const { v4: uuidv4 } = require('uuid');

const roomSchema = new mongoose.Schema(
  {
    roomId: {
      type: String,
      default: () => uuidv4(),
      unique: true,
      index: true
    },
    createdBy: {
      type: String, // userId
      required: true
    },
    expiresAt: {
      type: Date,
      default: () => new Date(Date.now() + 24 * 60 * 60 * 1000), // 24 hours
      index: { expireAfterSeconds: 0 }
    },
    isActive: {
      type: Boolean,
      default: true
    },
    participants: [
      {
        userId: String,
        joinedAt: Date
      }
    ]
  },
  { timestamps: true }
);

module.exports = mongoose.model('Room', roomSchema);
