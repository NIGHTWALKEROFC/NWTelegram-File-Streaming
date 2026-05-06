// android/app/src/main/kotlin/com/nightwalker/telegram_streamer/MainActivity.kt
//
// FIX: This file was completely missing from the project.
// AndroidManifest.xml declares android:name=".MainActivity" but the class
// didn't exist anywhere, so Android couldn't find the activity entry point
// and the app froze on the splash screen immediately.
//
// FlutterActivity is Flutter's standard host activity — it handles the
// Flutter engine lifecycle, plugin registration, and the native splash
// screen transition. Without it the app cannot start.

package com.nightwalker.telegram_streamer

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity()
