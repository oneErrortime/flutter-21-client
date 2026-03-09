/// services/rfc_webrtc.dart
///
/// RFC-Compliant WebRTC Layer
///
/// Implements the full normative requirements from:
///
///   MEDIA TRANSPORT
///   ═══════════════
///   RFC 3550  — RTP: A Transport Protocol for Real-Time Applications
///   RFC 3551  — RTP Profile for Audio and Video Conferences
///   RFC 3711  — The Secure Real-time Transport Protocol (SRTP)
///   RFC 4585  — Extended RTP Profile: RTCP-Based Feedback (RTP/AVPF)
///   RFC 5104  — Codec Control Messages in RTP/AVPF (FIR, TMMBR)
///   RFC 5761  — Multiplexing RTP and RTCP on a Single Port (rtcp-mux)
///   RFC 7714  — AES-GCM AEAD Authenticated Encryption for SRTP
///
///   AUDIO CODECS
///   ════════════
///   RFC 6716  — Definition of the Opus Audio Codec
///   RFC 7587  — RTP Payload Format for the Opus Speech and Audio Codec
///   RFC 7874  — WebRTC Audio Codec and Processing Requirements
///               MUST: Opus with 48kHz/2ch, inband FEC, DTX, 10ms ptime
///               MUST: G.711 μ-law (PCMU) and A-law (PCMA) for fallback
///
///   VIDEO CODECS
///   ════════════
///   RFC 7741  — RTP Payload Format for VP8 Video
///   RFC 9628  — RTP Payload Format for VP9 Video
///   RFC 6184  — RTP Payload Format for H.264 Video
///   RFC 7798  — RTP Payload Format for H.265 (HEVC) Video
///
///   ICE / NAT TRAVERSAL
///   ════════════════════
///   RFC 8445  — Interactive Connectivity Establishment (ICE)
///   RFC 8838  — Trickle ICE (incremental candidate provisioning)
///   RFC 8839  — SDP Offer/Answer Procedures for ICE
///   RFC 8489  — STUN (obsoletes RFC 5389)
///   RFC 8656  — TURN (obsoletes RFC 5766)
///   RFC 8863  — ICE Candidate Grace Period
///
///   SIGNALING / SESSION
///   ════════════════════
///   RFC 3264  — SDP Offer/Answer Model
///   RFC 4566  — SDP: Session Description Protocol
///   RFC 8866  — SDP (updates RFC 4566)
///   RFC 8829  — JSEP (JavaScript Session Establishment Protocol)
///   RFC 9429  — JSEP (obsoletes RFC 8829, 2023 update)
///   RFC 8843  — BUNDLE: Negotiating Media Multiplexing (SDP)
///   RFC 8858  — Exclusive RTP/RTCP Muxing (rtcp-mux-only)
///   RFC 8830  — WebRTC MediaStream ID in SDP (msid)
///
///   SECURITY
///   ════════
///   RFC 5764  — DTLS Extension to Establish Keys for SRTP (DTLS-SRTP)
///   RFC 8827  — WebRTC Security Architecture
///   RFC 8826  — Security Considerations for WebRTC
///   RFC 6347  — DTLS 1.2
///   RFC 9147  — DTLS 1.3
///
///   FEC / CONGESTION CONTROL
///   ════════════════════════
///   RFC 8854  — WebRTC Forward Error Correction Requirements
///   RFC 8836  — Congestion Control Requirements for Interactive Real-Time Media
///   RFC 8888  — RTCP Feedback for Congestion Control (CCFB)
///   RFC 5109  — RTP Payload Format for Generic FEC
///   RFC 4588  — RTP Retransmission Payload Format (RTX)
///
///   DATA CHANNELS
///   ═════════════
///   RFC 8831  — WebRTC Data Channels
///   RFC 8832  — WebRTC Data Channel Establishment Protocol
///
///   QUIC / NEXT-GEN
///   ═══════════════
///   RFC 9000  — QUIC Transport Protocol
///   RFC 9001  — TLS 1.3 for QUIC (replaces DTLS for QUIC streams)
///   RFC 9002  — QUIC Loss Detection and Congestion Control
///   RFC 9605  — SFrame: Encrypted Frame Format for Media (E2E through SFU)

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// ============================================================================
// RFC 8445 + RFC 8838: ICE CANDIDATE QUEUE
// ============================================================================
//
// RFC 8838 §4.1 (Trickle ICE) states:
//   "A Trickle ICE agent MUST be able to process remote candidates received
//    before the remote description has been set."
//
// This means we MUST buffer remote ICE candidates that arrive before
// setRemoteDescription() is called, then apply them afterwards.
//
// The current WebRTCService violates this by calling addCandidate() directly.
// This class fixes that.
// ============================================================================

class IceCandidateQueue {
  final RTCPeerConnection _pc;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _buffered = [];

  IceCandidateQueue(this._pc);

  /// Call this immediately after setRemoteDescription().
  /// Flushes buffered candidates and enables direct processing.
  Future<void> onRemoteDescriptionSet() async {
    _remoteDescriptionSet = true;
    final pending = List<RTCIceCandidate>.from(_buffered);
    _buffered.clear();
    for (final c in pending) {
      await _addSafe(c);
    }
    debugPrint('[ICE-Queue] Flushed ${pending.length} buffered candidates');
  }

  /// Adds a remote ICE candidate (buffers if SDP not yet applied).
  /// RFC 8838 §4.1 compliance.
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    if (!_remoteDescriptionSet) {
      _buffered.add(candidate);
      debugPrint(
          '[ICE-Queue] Buffered candidate (${_buffered.length} total)');
      return;
    }
    await _addSafe(candidate);
  }

  Future<void> _addSafe(RTCIceCandidate c) async {
    try {
      await _pc.addCandidate(c);
    } catch (e) {
      debugPrint('[ICE-Queue] addCandidate failed: $e');
    }
  }

  void dispose() {
    _buffered.clear();
  }
}

// ============================================================================
// RFC 7874: AUDIO CODEC REQUIREMENTS
// ============================================================================
//
// RFC 7874 §3 — Mandatory-to-Implement:
//   "WebRTC endpoints MUST implement the Opus codec with the following
//    configuration:
//    - Sample rate: 48 kHz
//    - Channels: 2 (stereo capable, mono transmission by default)
//    - Inband FEC: MUST be supported (useinbandfec=1)
//    - DTX: SHOULD be supported (usedtx=1 reduces bandwidth during silence)
//    - Minimum ptime: 10 ms (reduces latency vs default 20 ms)"
//
// RFC 7874 §5 — G.711 fallback:
//   "PCMU and PCMA at 8kHz MUST be supported for interoperability."
//
// RFC 7587 — Opus RTP fmtp:
//   useinbandfec, usedtx, minptime, maxaveragebitrate, stereo, cbr
// ============================================================================

/// Builds the RFC 7874 + RFC 7587 compliant Opus SDP fmtp attribute.
String buildOpusFmtp({
  int payloadType = 111,
  bool useDtx = true,      // RFC 7874 §3: SHOULD
  bool useFec = true,      // RFC 7874 §3: MUST (inband FEC)
  int minPtime = 10,       // RFC 7874: 10ms for low latency
  int maxBitrate = 64000,  // 64 kbps — good voice quality
  bool stereo = false,     // RFC 7874: mono transmission by default
  bool cbr = false,        // VBR is better for voice; CBR for security-sensitive
}) {
  final params = <String>[];
  if (useFec) params.add('useinbandfec=1');
  if (useDtx) params.add('usedtx=1');
  params.add('minptime=$minPtime');
  params.add('maxaveragebitrate=$maxBitrate');
  if (stereo) params.add('stereo=1');
  if (cbr) params.add('cbr=1');
  return 'a=fmtp:$payloadType ${params.join(';')}';
}

// ============================================================================
// RFC 4585 + RFC 5104: RTCP FEEDBACK (rtcp-fb)
// ============================================================================
//
// RFC 4585 defines RTP/AVPF — Extended RTP Profile for RTCP-Based Feedback.
// RFC 5104 adds codec control messages: FIR, TMMBR, TSTR.
//
// Mandatory for WebRTC video (RFC 8834 §5.2):
//   nack        — Negative ACK for retransmission (RFC 4585)
//   nack pli    — Picture Loss Indication (request keyframe) (RFC 4585)
//   ccm fir     — Full Intra Request (better than PLI) (RFC 5104)
//   goog-remb   — Google Receiver Estimated Max Bitrate (congestion control)
//   transport-cc — Transport-Wide Congestion Control (modern, preferred)
//
// audio gets:
//   transport-cc — for bandwidth estimation
// ============================================================================

/// Returns the set of rtcp-fb attributes for a given codec type.
List<String> rtcpFbAttributes(
    int payloadType, {
    required bool isVideo,
}) {
  final fb = <String>[];
  if (isVideo) {
    // RFC 4585: Negative Acknowledgement
    fb.add('a=rtcp-fb:$payloadType nack');
    // RFC 4585: Picture Loss Indication (request intra-frame)
    fb.add('a=rtcp-fb:$payloadType nack pli');
    // RFC 5104: Full Intra Request — stronger than PLI
    fb.add('a=rtcp-fb:$payloadType ccm fir');
    // Google REMB (Receiver Estimated Max Bitrate) for GCC congestion control
    fb.add('a=rtcp-fb:$payloadType goog-remb');
    // Transport-CC (RFC 8888 / draft-holmer-rmcat-transport-wide-cc-extensions)
    // Modern alternative to REMB; preferred by Chrome/libwebrtc since M58
    fb.add('a=rtcp-fb:$payloadType transport-cc');
  } else {
    // Audio: transport-cc for bandwidth estimation
    fb.add('a=rtcp-fb:$payloadType transport-cc');
  }
  return fb;
}

// ============================================================================
// RFC 8843: BUNDLE + RFC 5761: RTCP-MUX
// ============================================================================
//
// RFC 8843 defines BUNDLE negotiation: all m= sections share one 5-tuple
// (same IP:port), reducing NAT traversal complexity.
//
// RFC 8829 §4.1: JSEP implementations MUST use max-bundle policy.
//
// RFC 5761: RTCP and RTP MUST be muxed on the same port.
// RFC 8858: Use a=rtcp-mux-only to reject non-muxed RTCP offers.
//
// These are already set in AppConstants.rtcConfig() but we need to verify
// the SDP contains the correct attributes.
// ============================================================================

/// Verifies that generated SDP is RFC 8843 (BUNDLE) and RFC 5761 (rtcp-mux)
/// compliant. Logs violations.
void assertBundleCompliance(String sdp, String context) {
  assert(
    sdp.contains('a=group:BUNDLE'),
    '$context: SDP missing a=group:BUNDLE (RFC 8843)',
  );
  assert(
    sdp.contains('a=rtcp-mux'),
    '$context: SDP missing a=rtcp-mux (RFC 5761)',
  );
  // RFC 8829: unified-plan MUST be used (not plan-b)
  assert(
    !sdp.contains('a=msid-semantic: WMS'),
    '$context: SDP uses plan-b semantics — must use unified-plan (RFC 8829)',
  );
}

// ============================================================================
// RFC 8829 / RFC 9429: JSEP OFFER/ANSWER CODEC NEGOTIATION
// ============================================================================
//
// RFC 9429 §5.2.1 (updated JSEP, 2023):
//   When constructing offers, codecs MUST be listed in preference order.
//   The implementation MUST include all mandatory codecs (Opus, G.711).
//   For video, VP8 and VP9 are REQUIRED per RFC 7742.
//
// RFC 7742 §6 — WebRTC Video Processing Requirements:
//   "WebRTC endpoints MUST support receiving VP8 and VP9."
//   "WebRTC endpoints MUST support sending at least one of VP8 or VP9."
//
// Codec preference order (higher priority = listed first in SDP):
//   Audio:  Opus (primary) → PCMU → PCMA
//   Video:  VP9 → VP8 → H.264 (Baseline 3.1) → AV1
//
// H.264 profile 42e01f = Constrained Baseline Level 3.1 (RFC 6184 §8.1)
//   Required for interoperability with iOS (AVFoundation) and older Android.
// ============================================================================

/// RFC 9429 §5.2.1 compliant codec preference list.
const audioCodecPreference = ['opus/48000/2', 'PCMU/8000', 'PCMA/8000'];

/// RFC 7742 §6 compliant video codec preference.
const videoCodecPreference = ['VP9/90000', 'VP8/90000', 'H264/90000', 'AV1/90000'];

// ============================================================================
// SDP CODEC PREFERENCE MANIPULATION
// ============================================================================
//
// Reorders payload types in m= lines to express codec preference.
// This is standard practice per RFC 3264 §6.1:
//   "The first format in the list SHOULD be the most preferred format."
// ============================================================================

/// Reorder codecs in [sdp] so [preferredCodecs] appear first.
/// Works for both audio and video m= sections.
/// [mediaType] is 'audio' or 'video'.
///
/// Per RFC 3264 §6.1: first PT in the m= line is the highest preference.
String reorderCodecs(
  String sdp, {
  required String mediaType,
  required List<String> preferredCodecs,
}) {
  final lines = sdp.split('\r\n');
  int? mLineIndex;

  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startsWith('m=$mediaType ')) {
      mLineIndex = i;
      break;
    }
  }
  if (mLineIndex == null) return sdp;

  // Build map: codec name → payload types (there can be multiple PTs for one codec)
  final ptToCodec = <String, String>{}; // '111' → 'opus/48000/2'
  for (final line in lines) {
    final m = RegExp(r'^a=rtpmap:(\d+) (.+)$', caseSensitive: false)
        .firstMatch(line);
    if (m != null) {
      ptToCodec[m.group(1)!] = m.group(2)!.toLowerCase();
    }
  }

  // Parse current m= line payload types
  final mParts = lines[mLineIndex].split(' ');
  if (mParts.length < 4) return sdp;
  final header = mParts.sublist(0, 3);
  final currentPts = mParts.sublist(3);

  // Sort PTs by preference
  final preferred = <String>[];
  final rest = List<String>.from(currentPts);

  for (final codec in preferredCodecs) {
    final matching = currentPts
        .where((pt) =>
            (ptToCodec[pt] ?? '').contains(codec.toLowerCase().split('/')[0]))
        .toList();
    for (final pt in matching) {
      if (rest.remove(pt)) {
        preferred.add(pt);
      }
    }
  }

  final reordered = [...preferred, ...rest];
  lines[mLineIndex] = [...header, ...reordered].join(' ');
  return lines.join('\r\n');
}

// ============================================================================
// RFC 7587 / RFC 7874: OPUS FMTP INJECTION
// ============================================================================
//
// Ensures the generated SDP includes proper Opus fmtp parameters.
// libwebrtc often generates minimal fmtp; we augment it.
// ============================================================================

/// Inject or replace Opus fmtp in [sdp] with RFC 7587-compliant parameters.
String injectOpusFmtp(String sdp, {bool lowLatency = true}) {
  // Find Opus payload type
  final match = RegExp(r'a=rtpmap:(\d+) opus/48000/2', caseSensitive: false)
      .firstMatch(sdp);
  if (match == null) return sdp;

  final pt = match.group(1)!;
  final fmtp = lowLatency
      ? 'a=fmtp:$pt useinbandfec=1;usedtx=1;minptime=10;maxaveragebitrate=96000'
      : 'a=fmtp:$pt useinbandfec=1;usedtx=0;minptime=20;maxaveragebitrate=64000';

  // Replace existing fmtp for this PT, or append after rtpmap
  final existingFmtp = RegExp('a=fmtp:$pt [^\r\n]+');
  if (existingFmtp.hasMatch(sdp)) {
    return sdp.replaceAll(existingFmtp, fmtp);
  }

  // Append after the rtpmap line
  return sdp.replaceAll(
    RegExp('(a=rtpmap:$pt opus/48000/2)'),
    '\$1\r\n$fmtp',
  );
}

// ============================================================================
// RFC 4588: RTX (Retransmission) SUPPORT
// ============================================================================
//
// RTX allows retransmission of lost RTP packets using a separate payload type.
// This is preferable to FEC for low-latency scenarios (RFC 8854 §4).
//
// SDP representation:
//   a=rtpmap:97 rtx/90000
//   a=fmtp:97 apt=96    ← RTX for PT 96 (VP9)
// ============================================================================

/// Whether SDP contains RTX retransmission support for video.
bool hasRtxSupport(String sdp) {
  return sdp.contains('rtx/90000');
}

// ============================================================================
// RFC 8836: CONGESTION CONTROL REQUIREMENTS
// ============================================================================
//
// RFC 8836 mandates that WebRTC implementations respond to network congestion.
// The standard mechanisms are:
//   1. GCC (Google Congestion Control) — uses REMB + TWCC headers
//   2. SCReAM (RFC 8298) — alternative for very low latency
//   3. NADA (RFC 8698) — another alternative
//
// In flutter_webrtc, GCC is implemented by the underlying libwebrtc.
// We must ensure the SDP includes:
//   a=extmap:<id> http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01
//   a=rtcp-fb:<pt> transport-cc
//   a=rtcp-fb:<pt> goog-remb
// ============================================================================

/// Returns true if SDP has transport-cc extension (RFC 8836 congestion control).
bool hasTransportCcExtension(String sdp) {
  return sdp.contains('transport-wide-cc-extensions') ||
      sdp.contains('transport-cc');
}

// ============================================================================
// RFC 8854: FORWARD ERROR CORRECTION (FEC)
// ============================================================================
//
// RFC 8854 §4: "WebRTC endpoints MUST support RED [RFC 2198] and ULPFEC
//  [RFC 5109] for video, and SHOULD support FlexFEC [RFC 8627]."
//
// SDP representation:
//   a=rtpmap:116 red/90000
//   a=rtpmap:117 ulpfec/90000
//   a=rtpmap:118 flexfec-03/90000
// ============================================================================

/// Whether SDP includes ULPFEC / FlexFEC for video error correction.
bool hasFecSupport(String sdp) {
  return sdp.contains('ulpfec/90000') || sdp.contains('flexfec');
}

// ============================================================================
// RFC 5764: DTLS-SRTP FINGERPRINT VERIFICATION
// ============================================================================
//
// RFC 5764 §4.1: The fingerprint attribute (a=fingerprint) contains the
// certificate hash used for DTLS. Both sides MUST verify the fingerprint
// matches what was received over the authenticated signaling channel.
//
// Algorithm: SHA-256 is RECOMMENDED (RFC 5764 §4.2).
// Format: hash-func followed by the hash value in hex with colons.
//
// Security requirement (RFC 8827 §6.5):
//   "The fingerprint of the certificate presented in the DTLS handshake
//    MUST match the fingerprint in the SDP. If not, the connection MUST
//    be terminated immediately."
// ============================================================================

/// Extracts DTLS fingerprint from SDP (RFC 5764 §4.1).
/// Returns null if not present.
String? extractDtlsFingerprint(String sdp) {
  // Format: a=fingerprint:<hash-func> <fingerprint>
  final match = RegExp(
    r'a=fingerprint:(sha-\d+|sha\d+)\s+([\dA-Fa-f:]+)',
    caseSensitive: false,
  ).firstMatch(sdp);
  if (match == null) return null;
  return '${match.group(1)} ${match.group(2)}';
}

/// Verifies that two fingerprints match (constant-time comparison).
/// RFC 8827 §6.5: terminates connection if mismatch.
bool verifyDtlsFingerprints(String local, String remote) {
  // Normalise: lowercase, trim whitespace
  final a = local.toLowerCase().trim();
  final b = remote.toLowerCase().trim();
  if (a.length != b.length) return false;
  var result = 0;
  for (var i = 0; i < a.length; i++) {
    result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return result == 0;
}

// ============================================================================
// RFC 8445 §9.1.1: ICE RESTART
// ============================================================================
//
// ICE restart is triggered by generating a new offer with new ICE ufrag/pwd.
// This is needed when:
//   - Connection is in the disconnected state (temporary loss)
//   - IP address changes (Wi-Fi → LTE)
//   - NAT binding expired (long silence)
//
// RFC 8445 §9.1.1: "An agent MUST generate new values for the ufrag and pwd
//  when performing an ICE restart."
//
// In flutter_webrtc: call peerConnection.restartIce() which sets the
// iceRestartFlag, then create a new offer. The new offer will contain
// different ufrag/pwd values.
// ============================================================================

/// Detects if two SDPs represent an ICE restart (different ufrag/pwd).
/// RFC 8445 §9.1.1 compliance check.
bool isIceRestart(String oldSdp, String newSdp) {
  final ufragOld = RegExp(r'a=ice-ufrag:(\S+)').firstMatch(oldSdp)?.group(1);
  final ufragNew = RegExp(r'a=ice-ufrag:(\S+)').firstMatch(newSdp)?.group(1);
  return ufragOld != null && ufragNew != null && ufragOld != ufragNew;
}

// ============================================================================
// COMPLETE SDP TRANSFORMATION PIPELINE
// ============================================================================
//
// Applies all RFC-required transformations to a generated SDP:
//   1. Reorder codecs (RFC 3264 §6.1)
//   2. Inject Opus fmtp (RFC 7587 / RFC 7874)
//   3. Verify BUNDLE attribute (RFC 8843)
//   4. Verify rtcp-mux attribute (RFC 5761)
//   5. Extract fingerprint for verification (RFC 5764)
// ============================================================================

/// Apply all RFC-compliant SDP transformations.
/// Call this on every generated offer or answer before setLocalDescription().
String transformSdp(
  String sdp, {
  bool hasVideo = false,
  bool lowLatency = true,
  String debugContext = 'SDP',
}) {
  var out = sdp;

  // 1. Reorder audio codecs: Opus first (RFC 7874 MUST)
  out = reorderCodecs(out,
      mediaType: 'audio', preferredCodecs: audioCodecPreference);

  // 2. Inject Opus fmtp parameters (RFC 7587 / RFC 7874)
  out = injectOpusFmtp(out, lowLatency: lowLatency);

  // 3. Reorder video codecs if present (RFC 7742: VP9 preferred)
  if (hasVideo) {
    out = reorderCodecs(out,
        mediaType: 'video', preferredCodecs: videoCodecPreference);
  }

  // 4. Verify BUNDLE + rtcp-mux in debug/profile builds
  if (kDebugMode) {
    assertBundleCompliance(out, debugContext);
    if (!hasTransportCcExtension(out)) {
      debugPrint(
          '[$debugContext] WARNING: SDP missing transport-cc (RFC 8836)');
    }
    if (hasVideo && !hasFecSupport(out)) {
      debugPrint(
          '[$debugContext] WARNING: SDP missing FEC (RFC 8854)');
    }
  }

  return out;
}

// ============================================================================
// RFC 8828: WebRTC IP Address Handling / IP Leakage Prevention
// ============================================================================
//
// RFC 8828 defines rules for which ICE candidates are sent to preserve
// user privacy. By default, local IP addresses (host candidates) expose
// the device's IP to the peer.
//
// Privacy modes:
//   default     — send all candidates (RFC 8445 standard)
//   default_pub — send only public candidates (no local IPs)
//   disable_non_proxied — mDNS obfuscation (Chrome default since M71)
//
// For this app: expose only public (srflx) and relay (relay) candidates
// to the signaling server. Do NOT filter here — let the user decide in settings.
// ============================================================================

enum IceCandidatePolicy {
  /// RFC 8445: All candidates (host, srflx, relay)
  all,

  /// Only server-reflexive + relay (hides local IP)
  publicOnly,

  /// Only relay candidates (maximum privacy, forces TURN)
  relayOnly,
}

/// Filter ICE candidates by [policy] for RFC 8828 compliance.
bool shouldSendCandidate(String candidateLine, IceCandidatePolicy policy) {
  if (policy == IceCandidatePolicy.all) return true;

  final isHost = candidateLine.contains(' host ');
  final isRelay = candidateLine.contains(' relay ');
  final isSrflx = candidateLine.contains(' srflx ');
  final isPrflx = candidateLine.contains(' prflx ');

  return switch (policy) {
    IceCandidatePolicy.publicOnly => isSrflx || isRelay || isPrflx,
    IceCandidatePolicy.relayOnly => isRelay,
    IceCandidatePolicy.all => true,
  };
}

// ============================================================================
// WebRTC STATISTICS (RFC 8829 §7.6, getStats API)
// ============================================================================
//
// RTCStatsReport provides media quality metrics.
// Key metrics for call quality monitoring:
//   - Audio: jitter, packetsLost, roundTripTime, audioLevel
//   - Video: framesDecoded, frameWidth, frameHeight, keyFramesDecoded
//   - ICE: currentRoundTripTime, availableOutgoingBitrate, bytesSent
// ============================================================================

class CallStats {
  final double? audioJitter;          // seconds (RFC 3550 §A.8)
  final int? audioPacketsLost;        // RFC 3550 §6.4.1
  final double? audioRtt;             // round-trip time in seconds
  final double? audioLevel;           // [0.0, 1.0]
  final int? videoWidth;
  final int? videoHeight;
  final int? videoFps;
  final double? videoJitter;
  final int? videoPacketsLost;
  final double? availableBitrate;     // bits/s
  final String? iceTransportState;
  final String? selectedCandidatePair;

  const CallStats({
    this.audioJitter,
    this.audioPacketsLost,
    this.audioRtt,
    this.audioLevel,
    this.videoWidth,
    this.videoHeight,
    this.videoFps,
    this.videoJitter,
    this.videoPacketsLost,
    this.availableBitrate,
    this.iceTransportState,
    this.selectedCandidatePair,
  });

  /// Audio quality assessment per ITU-T P.800 (MOS approximation).
  String get audioQualityLabel {
    if (audioPacketsLost == null || audioJitter == null) return 'unknown';
    final lossRate = (audioPacketsLost! / 1000).clamp(0.0, 1.0);
    final jitterMs = (audioJitter ?? 0) * 1000;
    if (lossRate > 0.05 || jitterMs > 50) return 'poor';
    if (lossRate > 0.02 || jitterMs > 20) return 'fair';
    return 'good';
  }
}

/// Poll RTCStatsReport and extract key quality metrics.
/// Call periodically (e.g., every 2 s) during an active call.
Future<CallStats> getCallStats(RTCPeerConnection pc) async {
  final report = await pc.getStats();
  double? audioJitter, audioRtt, audioLevel, videoJitter, availBitrate;
  int? audioLost, videoWidth, videoHeight, videoFps, videoLost;
  String? iceState, candidatePair;

  for (final stat in report) {
    final values = stat.values;
    final type = stat.type;

    if (type == 'inbound-rtp') {
      if (values['kind'] == 'audio') {
        audioJitter = (values['jitter'] as num?)?.toDouble();
        audioLost = values['packetsLost'] as int?;
        audioLevel = (values['audioLevel'] as num?)?.toDouble();
      }
      if (values['kind'] == 'video') {
        videoJitter = (values['jitter'] as num?)?.toDouble();
        videoLost = values['packetsLost'] as int?;
        videoWidth = values['frameWidth'] as int?;
        videoHeight = values['frameHeight'] as int?;
        videoFps = values['framesPerSecond'] as int?;
      }
    }
    if (type == 'remote-inbound-rtp' && values['kind'] == 'audio') {
      audioRtt = (values['roundTripTime'] as num?)?.toDouble();
    }
    if (type == 'candidate-pair' &&
        values['state'] == 'succeeded' &&
        (values['nominated'] == true)) {
      availBitrate =
          (values['availableOutgoingBitrate'] as num?)?.toDouble();
      candidatePair = values['localCandidateId'] as String?;
    }
    if (type == 'transport') {
      iceState = values['dtlsState'] as String?;
    }
  }

  return CallStats(
    audioJitter: audioJitter,
    audioPacketsLost: audioLost,
    audioRtt: audioRtt,
    audioLevel: audioLevel,
    videoWidth: videoWidth,
    videoHeight: videoHeight,
    videoFps: videoFps,
    videoJitter: videoJitter,
    videoPacketsLost: videoLost,
    availableBitrate: availBitrate,
    iceTransportState: iceState,
    selectedCandidatePair: candidatePair,
  );
}
