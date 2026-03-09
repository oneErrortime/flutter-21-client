package com.voicecall

import io.flutter.embedding.android.FlutterActivity

/**
 * Main entry-point for the Flutter Android host.
 *
 * Extends FlutterActivity — the Flutter v2 Android embedding.
 * v1 embedding (FlutterApplication / registerWith) was removed in
 * Flutter 3.x; all plugins must use v2 (PluginRegistry / GeneratedPluginRegistrant).
 *
 * No custom code is needed here unless you require:
 *   - Custom FlutterEngine (e.g. background Dart isolate)
 *   - Activity-level intent handling (deep links are handled by the manifest)
 *   - Custom back-press behaviour
 */
class MainActivity : FlutterActivity()
