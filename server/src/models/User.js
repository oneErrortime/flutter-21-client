const mongoose = require('mongoose');
const bcrypt = require('bcryptjs');
const { v4: uuidv4 } = require('uuid');

const userSchema = new mongoose.Schema(
  {
    userId: {
      type: String,
      default: () => uuidv4(),
      unique: true,
      index: true
    },
    username: {
      type: String,
      required: [true, 'Username is required'],
      unique: true,
      trim: true,
      minlength: [3, 'Username must be at least 3 characters'],
      maxlength: [30, 'Username must not exceed 30 characters'],
      match: [/^[a-zA-Z0-9_.-]+$/, 'Username can only contain letters, numbers, underscores, dots, and hyphens']
    },
    email: {
      type: String,
      required: [true, 'Email is required'],
      unique: true,
      lowercase: true,
      trim: true,
      match: [/^\S+@\S+\.\S+$/, 'Please provide a valid email']
    },
    displayName: {
      type: String,
      required: [true, 'Display name is required'],
      trim: true,
      maxlength: [50, 'Display name must not exceed 50 characters']
    },
    passwordHash: {
      type: String,
      required: true,
      select: false // Never return password in queries by default
    },
    avatarUrl: {
      type: String,
      default: null
    },
    refreshTokens: {
      type: [String],
      select: false,
      default: []
    },
    isActive: {
      type: Boolean,
      default: true
    },
    lastSeen: {
      type: Date,
      default: Date.now
    }
  },
  {
    timestamps: true
  }
);

// Hash password before saving
userSchema.pre('save', async function (next) {
  if (!this.isModified('passwordHash')) return next();
  const salt = await bcrypt.genSalt(12);
  this.passwordHash = await bcrypt.hash(this.passwordHash, salt);
  next();
});

// Compare password
userSchema.methods.comparePassword = async function (candidatePassword) {
  return bcrypt.compare(candidatePassword, this.passwordHash);
};

// Safe user object (no sensitive fields)
userSchema.methods.toPublicJSON = function () {
  return {
    userId: this.userId,
    username: this.username,
    displayName: this.displayName,
    avatarUrl: this.avatarUrl,
    lastSeen: this.lastSeen
  };
};

module.exports = mongoose.model('User', userSchema);
