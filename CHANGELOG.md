## 0.7.0 — 2026-09-01

Build-system modernisation and a full Swift rewrite of the iOS implementation.
No public Dart API, method-channel name, or method signature changed — existing
code keeps working. Toolchain minimums went up.

### 🍎 iOS — rewritten in Swift

- The iOS implementation is now **Swift** (`VideoThumbnailPlugin.swift`), replacing the
  Objective-C `VideoThumbnailPlugin.{h,m}`. Every method — `data`, `dataList`, `file`,
  `metadata`, `clearCache` — keeps its existing arguments, results, and error codes.
- On iOS 16+ the port uses the current AVFoundation APIs
  (`generateCGImageAsynchronously(for:)`, `AVAsset.load(_:)`, `loadTracks(withMediaType:)`),
  falling back to the older synchronous accessors on iOS 13–15. This keeps the plugin free of
  deprecation warnings for apps targeting recent iOS versions.
- Results are now returned as `FlutterStandardTypedData`, the type Flutter documents as mapping
  to Dart's `Uint8List`. The previous code returned raw `NSData`, which worked only through an
  undocumented convenience in the codec.
- A malformed `video` string now fails with an `UNSUPPORTED_FORMAT` `FlutterError` instead of
  passing a null URL into `AVURLAsset`.
- The `thumbnailCache` property is no longer exposed. It was declared in the Objective-C header
  but is an implementation detail; the cache itself behaves exactly as before (40 MB `NSCache`).

#### WebP now works under Swift Package Manager too

Apple ships no WebP *encoder* in ImageIO on any platform, so WebP output requires the libwebp
C library, which a Swift target cannot link directly. libwebp therefore lives behind a small
Objective-C bridge, `VTGWebPEncoder`, in its own `video_thumbnail_gen_webp` target.

**`ImageFormat.WEBP` previously produced real WebP only under CocoaPods and silently fell back
to JPEG under Swift Package Manager.** That gap is now closed: the Swift package depends on
[SDWebImage/libwebp-Xcode](https://github.com/SDWebImage/libwebp-Xcode) 1.6.0, which builds the
same upstream libwebp sources as the CocoaPods `libwebp` pod. WebP output is now byte-identical
under both integrations.

**Fixed:** when the WebP encoder was unavailable and the plugin fell back to JPEG,
`thumbnailFile` still named the output `*.webp` — writing JPEG bytes under a WebP extension.
The encoder now reports the format it actually produced and the filename follows it, so a
fallback yields `*.jpg`. This affected the previous Objective-C implementation as well.

### 🍎 iOS — Swift Package Manager support

- Added `ios/video_thumbnail_gen/Package.swift` (swift-tools-version 5.9), so the plugin
  now integrates via **Swift Package Manager** as well as CocoaPods. Following
  [Flutter's plugin-author guide](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-plugin-authors),
  it declares a `video-thumbnail-gen` library product and depends on the tool-generated
  `FlutterFramework` package.
- Moved the native sources from `ios/Classes/` into
  `ios/video_thumbnail_gen/Sources/`. The package declares two targets: the Swift
  `video_thumbnail_gen` target and the `video_thumbnail_gen_webp` Objective-C bridge it depends
  on. Under CocoaPods both sets of sources compile into the single `video_thumbnail_gen` module.
- **CocoaPods keeps working.** `ios/video_thumbnail_gen.podspec` was retained and its
  `source_files` / `public_header_files` repointed at the new layout; it also now declares its
  MIT license type, `DEFINES_MODULE`, and `swift_version = '5.9'`.
- Pinned the `libwebp` dependency to `~> 1.6` instead of leaving it unbounded.
- Removed the hand-written root `Package.swift`, which used a non-standard layout the Flutter
  tool never picked up.
- Raised the iOS deployment target from 11.0 to **13.0**, matching Flutter 3.44's own minimum.
- Both integrations build warning-free. `pod lib lint` is clean apart from the `source` key
  notice inherent to path-based Flutter podspecs.

### 🤖 Android — Kotlin DSL, built-in Kotlin, AGP 9

Following [Flutter's built-in Kotlin migration guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-plugin-authors):

- Rewrote the native implementation from **Java to Kotlin**
  (`android/src/main/kotlin/com/itsxhadi/video_thumbnail/VideoThumbnailPlugin.kt`). Internal
  change only — the `plugins.itsxhadi.com/video_thumbnail_gen` channel, its methods, arguments,
  and error codes are unchanged.
- Converted every Groovy Gradle file to **Kotlin DSL**: `android/build.gradle{,.kts}`,
  `android/settings.gradle{,.kts}`, and the example's root, `settings`, and `app` build scripts.
- Kotlin now comes from the Android Gradle Plugin itself. The plugin no longer applies
  `kotlin-android`, and `kotlinOptions` was replaced with:
  ```kotlin
  kotlin {
      compilerOptions {
          jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
      }
  }
  ```
- Java/Kotlin compatibility moved from 1.8 to **17** (AGP 9 requires it).
- Example app: **AGP 9.1.0**, **Gradle 9.3.1**, and `android.builtInKotlin=true`.
- Dropped the obsolete `android.enableR8` (removed in AGP 7, now a hard error) and
  `android.enableJetifier` (unused here, and its transform exhausted the build heap) from the
  example's `gradle.properties`, and raised `org.gradle.jvmargs` to the current Flutter default.
- Deleted stale example scaffolding: the empty `xyz.justsoft` `MainActivity` left over from the
  fork, and the checked-in `GeneratedPluginRegistrant.java`. The example's `MainActivity` is now
  Kotlin.
- Regenerated the example's `ios/Podfile`, which was a pre-2020 template that modern Flutter
  refuses to build.

### ⚠️ Raised minimums

| | Was | Now |
|---|---|---|
| Flutter SDK | 3.0.0 | **3.44.0** |
| Dart SDK | 3.0.0 | **3.12.0** |
| iOS deployment target | 11.0 | **13.0** |
| Android Gradle Plugin | 8.11.1 | **9.0.0** |
| Java / JVM target | 1.8 | **17** |

## 0.6.3 — 2026-06-09

- Added PayPal donation button to README.md.
- Added funding link to pubspec.yaml.

## 0.6.2 — 2026-06-03

- Shortened package description in pubspec.yaml to fit within the 60-180 character limit required by pub.dev guidelines.

## 0.6.1 — 2026-06-03

- Update README.md screenshot URLs to use absolute raw GitHub paths to resolve broken images on pub.dev.

## 0.6.0 — 2026-06-03

### 🎉 Initial Release of `video_thumbnail_gen`

First public release of **video_thumbnail_gen**, a modern, production-grade replacement for `video_thumbnail`, maintained by [Hadi](https://github.com/Itsxhadi).
Forked and significantly extended from the original [video_thumbnail](https://pub.dev/packages/video_thumbnail) by justsoft.

#### 🛠️ Fixed Issues & Optimizations
- **iOS WebP Memory Leak**: Fixed a critical memory leak in `VideoThumbnailPlugin.m` where WebP data buffers were not freed. Added `WebPFree(output)` to resolve it.
- **Android File Descriptor Leak**: Wrapped `FileOutputStream` in a try-with-resources statement in `buildThumbnailFile` to prevent unclosed file descriptors.
- **Android Bitmap Memory Leak**: Fixed a memory leak where the original high-resolution bitmap was not recycled after calling `createScaledBitmap`. Introduced a `scaleAndRecycle()` helper.
- **Example App Settings bug**: Resolved duplicate settings widget instantiations in the UI by rebuilding settings dynamically from the Drawer rather than caching stale widgets.
- **Example App UI Cleanliness**: Cleared out the previous thumbnail when a new URL or source is selected, preventing the UI from showing outdated images.
- **Example App Storage & Toast bug**: Fixed storage write issues on Android by requesting appropriate permissions and saving to the correct external storage directory. The app now displays a success toast containing the full file path.
- **Image Format Overflow**: Corrected overflow issues in the format selection menu of the example app.

#### 📣 Community & GitHub Notice
If you run into any issues, have feature requests, or want to contribute optimizations, please **open an issue or pull request** on our GitHub repository: [github.com/Itsxhadi/video_thumbnail_gen](https://github.com/Itsxhadi/video_thumbnail_gen).
I will be regularly maintaining, updating, and reviewing contributions for this package!

#### Core Features
- Generate video thumbnails in memory (`thumbnailData`) or as files (`thumbnailFile`)
- Supports **JPEG**, **PNG**, **WebP**, and **HEIC** output formats
- Custom max width/height with aspect-ratio-preserving scaling
- Capture frame at any timestamp (`timeMs`)
- HTTP(S) remote video URL support with custom headers
- **First-Class YouTube URL Support**: Direct extraction and downloading of thumbnails from the YouTube CDN (uses robust `maxresdefault` ➜ `hqdefault` ➜ `0.jpg` fallback strategy)
- Custom output filename override (pass a full file path to `thumbnailPath`)
- `content://` (SAF) URI support on Android

#### Performance
- **Android**: `LruCache` — 1/8 of heap, keyed by `video+params`
- **iOS**: `NSCache` — 40 MB cap, thread-safe, auto-evicting
- **Batch extraction** (`thumbnailDataList`) — opens codec once, seeks N times
- Thread pool capped to `min(4, availableProcessors)` on Android

#### New APIs
- `VideoThumbnail.getVideoMetadata()` — duration, dimensions, rotation, MIME type
- `VideoThumbnail.thumbnailDataList()` — batch frame extraction
- `VideoThumbnail.clearCache()` — programmatic cache eviction
- `ThumbnailException` + `ThumbnailErrorCode` — typed, machine-readable errors
- `VideoMetadata` — strongly-typed metadata model

#### Native Quality
- iOS: all callbacks dispatched on main thread (no random crashes)
- iOS: `CGBitmapContext` draw approach — handles all `CGImageAlphaInfo` colorspaces
- iOS: `WebPFree(output)` — WebP buffer properly freed after encoding
- Android: `FileOutputStream` in try-with-resources — no FD leaks
- Android: original bitmap recycled immediately after `createScaledBitmap`

#### Platform & Build
- Dart SDK `>=3.0.0`
- Flutter `>=3.0.0`
- Android: Gradle 8+, namespace `com.itsxhadi.video_thumbnail`, `mavenCentral()`
- iOS: deployment target iOS 11+, CocoaPods + **Swift Package Manager** support
- MethodChannel: `plugins.itsxhadi.com/video_thumbnail_gen`
