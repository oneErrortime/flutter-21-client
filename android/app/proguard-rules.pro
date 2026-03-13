# Flutter / WebRTC ProGuard rules
# ─────────────────────────────────────────────────────────────────────────────
# Flutter engine — must not be obfuscated or stripped.
-keep class io.flutter.** { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }

# WebRTC native library symbols referenced via JNI
-keep class org.webrtc.** { *; }
-keepclassmembers class org.webrtc.** { *; }

# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**

# flutter_secure_storage
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# Kotlin
-keep class kotlin.** { *; }
-dontwarn kotlin.**

# Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# Serialization
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# General Android
-keepattributes SourceFile, LineNumberTable
-renamesourcefileattribute SourceFile

# Play Core — Flutter references these for deferred components but the library
# is not a direct dependency. R8 fails on missing classes at release build.
# Since this app does not use deferred components, we simply suppress warnings.
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }
