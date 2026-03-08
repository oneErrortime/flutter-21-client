'use strict';
/**
 * WebRTC Signaling Server
 *
 * Implements RFC 8825 (WebRTC Overview), RFC 8829 (JSEP),
 * RFC 8445 (ICE), RFC 5764 (DTLS-SRTP), RFC 4566 (SDP)
 *
 * Signaling modes:
 *   1. P2P Direct  — STUN only (same network / simple NAT)
 *   2. P2P TURN    — STUN + TURN relay (symmetric NAT / strict firewalls)
 *   3. Room Link   — Share roomId, 2 participants meet via signaling
 */

const { validateWsToken } = require('../middleware/auth');
const Room = require('../models/Room');
const User = require('../models/User');
const logger = require('../utils/logger');

// userId -> WebSocket client map (in-memory, use Redis in multi-node)
const onlineClients = new Map();

// roomId -> { caller: ws, callee: ws | null, offer: ... }
const activeRooms = new Map();

// callId -> { caller, callee } for tracking active calls
const activeCalls = new Map();

function send(ws, data) {
  if (ws && ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(data));
  }
}

function createSignalingServer(wss) {
  wss.on('connection', (ws, req) => {
    ws.isAlive = true;
    ws.userId = null;
    ws.authenticated = false;

    ws.on('pong', () => { ws.isAlive = true; });

    ws.on('message', async (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        return send(ws, { type: 'error', message: 'Invalid JSON' });
      }

      // ── AUTH ──────────────────────────────────────────────────────────────
      if (msg.type === 'auth') {
        try {
          const user = await validateWsToken(msg.token);
          ws.userId = user.userId;
          ws.displayName = user.displayName;
          ws.authenticated = true;

          // Replace old connection for same user
          const old = onlineClients.get(user.userId);
          if (old && old !== ws) {
            send(old, { type: 'session-replaced' });
            old.terminate();
          }
          onlineClients.set(user.userId, ws);

          // Update lastSeen
          User.updateOne({ userId: user.userId }, { lastSeen: new Date() }).exec();

          send(ws, { type: 'auth-success', userId: user.userId, displayName: user.displayName });
          logger.debug(`WS authenticated: ${user.userId}`);
        } catch (err) {
          send(ws, { type: 'auth-error', message: 'Invalid token' });
          ws.terminate();
        }
        return;
      }

      if (!ws.authenticated) {
        return send(ws, { type: 'error', message: 'Not authenticated' });
      }

      // ── CALL BY USER ID ───────────────────────────────────────────────────
      if (msg.type === 'call') {
        const { to, offer } = msg;
        if (!to || !offer) return send(ws, { type: 'error', message: 'Missing to/offer' });
        if (to === ws.userId) return send(ws, { type: 'error', message: 'Cannot call yourself' });

        const targetWs = onlineClients.get(to);
        if (!targetWs) {
          return send(ws, { type: 'user-offline', targetId: to });
        }

        // Check if target is busy
        const busyCheck = [...activeCalls.values()].find(
          c => c.caller === to || c.callee === to
        );
        if (busyCheck) {
          return send(ws, { type: 'user-busy', targetId: to });
        }

        const callId = `${ws.userId}-${to}-${Date.now()}`;
        activeCalls.set(callId, { caller: ws.userId, callee: to, callId });

        ws.currentCallId = callId;
        targetWs.currentCallId = callId;

        send(targetWs, {
          type: 'call-incoming',
          from: ws.userId,
          callerName: ws.displayName,
          offer,
          callId
        });
        logger.info(`Call initiated: ${ws.userId} → ${to} [${callId}]`);
        return;
      }

      // ── ANSWER CALL ───────────────────────────────────────────────────────
      if (msg.type === 'answer') {
        const { to, answer } = msg;
        if (!to || !answer) return send(ws, { type: 'error', message: 'Missing to/answer' });

        const targetWs = onlineClients.get(to);
        send(targetWs, { type: 'call-answered', answer });
        logger.info(`Call answered: ${ws.userId} ← ${to}`);
        return;
      }

      // ── ICE CANDIDATE (RFC 8445) ──────────────────────────────────────────
      if (msg.type === 'ice') {
        const { to, candidate } = msg;
        if (!to || !candidate) return;

        const targetWs = onlineClients.get(to);
        if (targetWs) {
          send(targetWs, { type: 'ice', candidate, from: ws.userId });
        }
        return;
      }

      // ── DECLINE CALL ──────────────────────────────────────────────────────
      if (msg.type === 'decline') {
        const { to, reason } = msg;
        const targetWs = onlineClients.get(to);
        if (targetWs) {
          send(targetWs, { type: 'call-declined', reason: reason || 'busy' });
        }
        // Clean up call record
        if (ws.currentCallId) {
          activeCalls.delete(ws.currentCallId);
          ws.currentCallId = null;
        }
        return;
      }

      // ── HANGUP ────────────────────────────────────────────────────────────
      if (msg.type === 'hangup') {
        const { to } = msg;
        const targetWs = onlineClients.get(to);
        if (targetWs) {
          send(targetWs, { type: 'hangup' });
          targetWs.currentCallId = null;
        }
        if (ws.currentCallId) {
          activeCalls.delete(ws.currentCallId);
          ws.currentCallId = null;
        }
        logger.info(`Call ended: ${ws.userId} ↔ ${to}`);
        return;
      }

      // ── CREATE ROOM LINK ──────────────────────────────────────────────────
      if (msg.type === 'create-room') {
        try {
          const room = new Room({ createdBy: ws.userId });
          await room.save();

          activeRooms.set(room.roomId, {
            caller: ws,
            callee: null,
            offer: null,
            createdAt: Date.now()
          });

          const link = `${process.env.APP_BASE_URL || 'https://yourapp.com'}/join/${room.roomId}`;
          send(ws, { type: 'room-created', roomId: room.roomId, link });
          logger.info(`Room created via WS: ${room.roomId}`);
        } catch (err) {
          send(ws, { type: 'error', message: 'Failed to create room' });
        }
        return;
      }

      // ── JOIN ROOM (callee side, sends offer) ──────────────────────────────
      if (msg.type === 'join-room') {
        const { roomId, offer } = msg;
        if (!roomId || !offer) return send(ws, { type: 'error', message: 'Missing roomId/offer' });

        const dbRoom = await Room.findOne({ roomId, isActive: true });
        if (!dbRoom || dbRoom.expiresAt < new Date()) {
          return send(ws, { type: 'error', message: 'Room not found or expired' });
        }

        let roomState = activeRooms.get(roomId);
        if (!roomState) {
          // Room creator not yet connected via WS — queue offer
          activeRooms.set(roomId, { caller: null, callee: ws, offer, callerUserId: dbRoom.createdBy });
          send(ws, { type: 'room-waiting', message: 'Waiting for room creator' });
        } else if (!roomState.callee) {
          // Notify room creator
          roomState.callee = ws;
          roomState.offer = offer;
          if (roomState.caller && roomState.caller.readyState === roomState.caller.OPEN) {
            send(roomState.caller, {
              type: 'room-joined',
              offer,
              joinerId: ws.userId,
              joinerName: ws.displayName
            });
          } else {
            send(ws, { type: 'room-waiting', message: 'Creator offline' });
          }
        } else {
          send(ws, { type: 'error', message: 'Room is full' });
        }
        return;
      }

      // ── ROOM CREATOR: WAITING, NOW CONNECTED ─────────────────────────────
      if (msg.type === 'room-host') {
        const { roomId } = msg;
        if (!roomId) return;
        let roomState = activeRooms.get(roomId);
        if (!roomState) {
          activeRooms.set(roomId, { caller: ws, callee: null, offer: null });
        } else {
          roomState.caller = ws;
          // If callee already waiting, notify creator
          if (roomState.callee && roomState.offer) {
            send(ws, {
              type: 'room-joined',
              offer: roomState.offer,
              joinerId: roomState.callee.userId,
              joinerName: roomState.callee.displayName
            });
          }
        }
        return;
      }

      // ── ROOM ANSWER ───────────────────────────────────────────────────────
      if (msg.type === 'room-answer') {
        const { roomId, answer } = msg;
        if (!roomId || !answer) return;
        const roomState = activeRooms.get(roomId);
        if (roomState && roomState.callee) {
          send(roomState.callee, { type: 'room-answered', answer });
        }
        return;
      }

      // ── ROOM ICE ──────────────────────────────────────────────────────────
      if (msg.type === 'room-ice') {
        const { roomId, candidate, role } = msg; // role: 'caller' | 'callee'
        const roomState = activeRooms.get(roomId);
        if (!roomState) return;
        if (role === 'caller' && roomState.callee) {
          send(roomState.callee, { type: 'room-ice', candidate });
        } else if (role === 'callee' && roomState.caller) {
          send(roomState.caller, { type: 'room-ice', candidate });
        }
        return;
      }

      // ── HEARTBEAT ─────────────────────────────────────────────────────────
      if (msg.type === 'heartbeat') {
        send(ws, { type: 'heartbeat-ack' });
        return;
      }

      send(ws, { type: 'error', message: `Unknown message type: ${msg.type}` });
    });

    ws.on('close', () => {
      if (ws.userId) {
        onlineClients.delete(ws.userId);
        User.updateOne({ userId: ws.userId }, { lastSeen: new Date() }).exec();

        // Notify call peer if in a call
        if (ws.currentCallId) {
          const call = activeCalls.get(ws.currentCallId);
          if (call) {
            const peerId = call.caller === ws.userId ? call.callee : call.caller;
            const peerWs = onlineClients.get(peerId);
            if (peerWs) send(peerWs, { type: 'hangup', reason: 'peer-disconnected' });
            activeCalls.delete(ws.currentCallId);
          }
        }
        logger.debug(`WS disconnected: ${ws.userId}`);
      }
    });

    ws.on('error', (err) => {
      logger.error('WS error:', err.message);
    });
  });

  // Heartbeat to detect dead connections (RFC recommends keepalive)
  const interval = setInterval(() => {
    wss.clients.forEach(ws => {
      if (!ws.isAlive) {
        if (ws.userId) onlineClients.delete(ws.userId);
        return ws.terminate();
      }
      ws.isAlive = false;
      ws.ping();
    });

    // Clean up expired rooms
    activeRooms.forEach((room, roomId) => {
      if (Date.now() - room.createdAt > 24 * 60 * 60 * 1000) {
        activeRooms.delete(roomId);
      }
    });
  }, 30000);

  wss.on('close', () => clearInterval(interval));

  logger.info('WebRTC Signaling Server ready');
  return wss;
}

module.exports = { createSignalingServer };
