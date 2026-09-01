# video_thumbnail_gen

<p align="center">
  <a href="https://pub.dev/packages/video_thumbnail_gen"><img src="https://img.shields.io/pub/v/video_thumbnail_gen.svg?logo=dart&style=flat-square" alt="pub package"></a>
  <img src="https://img.shields.io/badge/license-MIT-brightgreen?style=flat-square" alt="license">
  <img src="https://img.shields.io/badge/platform-android%20%7C%20ios-lightgrey?style=flat-square" alt="platform">
  <img src="https://img.shields.io/badge/dart-%3E%3D3.12.0-00B4AB?style=flat-square" alt="dart">
  <img src="https://img.shields.io/badge/flutter-%3E%3D3.44.0-02569B?style=flat-square" alt="flutter">
</p>

<p align="center">
  A production-grade Flutter plugin to <strong>generate video thumbnails</strong> and <strong>get thumbnails from video URLs</strong> on <strong>Android</strong> and <strong>iOS</strong>.<br>
  Easily convert <strong>video to image</strong>, extract <strong>YouTube video thumbnails</strong> natively, capture video frames, and read video metadata with high performance.
</p>

<p align="center">
  <a href="https://www.paypal.com/donate/?hosted_button_id=VV3WVVCZDF6TC">
    <img src="https://pics.paypal.com/00/s/M2M2MDJkODUtMmFiOS00OGFmLWE2MDQtMDgyYzQ2ZGNkMzc4/file.PNG" alt="Donate with PayPal button" height="35" />
  </a>
</p>

---

## 📸 Screenshots

<p align="center">
  <table align="center">
    <tr>
      <td align="center"><img src="https://raw.githubusercontent.com/Itsxhadi/video_thumbnail_gen/main/example_video_thumnail.png" width="250" alt="Screenshot 1"/><br/><sub>Onboarding Screen</sub></td>
      <td align="center"><img src="https://raw.githubusercontent.com/Itsxhadi/video_thumbnail_gen/main/example_video_thumnail2.png" width="250" alt="Screenshot 2"/><br/><sub>Main App Interface</sub></td>
      <td align="center"><img src="https://raw.githubusercontent.com/Itsxhadi/video_thumbnail_gen/main/example_video_thumnail3.png" width="250" alt="Screenshot 3"/><br/><sub>Thumbnail Extraction</sub></td>
    </tr>
    <tr>
      <td align="center"><img src="https://raw.githubusercontent.com/Itsxhadi/video_thumbnail_gen/main/example_video_thumnail4.png" width="250" alt="Screenshot 4"/><br/><sub>Image Settings</sub></td>
      <td align="center"><img src="https://raw.githubusercontent.com/Itsxhadi/video_thumbnail_gen/main/example_video_thumnail5.png" width="250" alt="Screenshot 5"/><br/><sub>Generated Thumbnail & Path</sub></td>
      <td align="center"><img src="https://raw.githubusercontent.com/Itsxhadi/video_thumbnail_gen/main/example_video_thumnail6.png" width="250" alt="Screenshot 6"/><br/><sub>Settings (Alternative View)</sub></td>
    </tr>
  </table>
</p>

---

## ✨ Features

| Feature | Android | iOS |
|---------|:-------:|:---:|
| JPEG / PNG thumbnails | ✅ | ✅ |
| WebP thumbnails | ✅ | ✅ |
| HEIC thumbnails | ✅ API 30+ | ✅ iOS 13+ |
| Batch frame extraction (single codec open) | ✅ | ✅ |
| Media metadata (date, camera, GPS, size, duration) | ✅ | ✅ |
| In-memory LRU / NSCache | ✅ | ✅ |
| `content://` (SAF) URI support | ✅ | — |
| HTTP(S) remote video URL | ✅ | ✅ |
| Custom output filename | ✅ | ✅ |
| Swift Package Manager (SPM) | — | ✅ |
| Typed error codes | ✅ | ✅ |
| Native language | Kotlin | Swift |

---

## ✅ Requirements

| | Minimum |
|---|---|
| Flutter SDK | **3.44.0** |
| Dart SDK | **3.12.0** |
| iOS deployment target | **13.0** |
| Android Gradle Plugin | **9.0.0** (built-in Kotlin) |
| Gradle | **9.0** |
| Java / JVM target | **17** |
| Swift | **5.9** |

---

## 📦 Installation

Run this command with Flutter:

```bash
flutter pub add video_thumbnail_gen
```

This will add a line like this to your package's `pubspec.yaml` (and run an implicit `flutter pub get`):

```yaml
dependencies:
  video_thumbnail_gen: ^0.7.0
```

---

## 🚀 Quick Start

```dart
import 'package:video_thumbnail_gen/video_thumbnail_gen.dart';
```

### Generate thumbnail in memory

```dart
final Uint8List? bytes = await VideoThumbnail.thumbnailData(
  video: '/path/to/video.mp4',
  imageFormat: ImageFormat.JPEG,
  maxWidth: 256,
  quality: 75,
);
// Use with Image.memory(bytes!)
```

### Generate thumbnail as a file

```dart
final String? filePath = await VideoThumbnail.thumbnailFile(
  video: 'https://example.com/video.mp4',
  thumbnailPath: (await getTemporaryDirectory()).path,
  imageFormat: ImageFormat.PNG,
  maxHeight: 128,
  quality: 80,
);
```

### Batch frame extraction

```dart
final List<Uint8List?> frames = await VideoThumbnail.thumbnailDataList(
  video: '/path/to/video.mp4',
  timesMs: [0, 2000, 5000, 10000], // extract 4 frames
  imageFormat: ImageFormat.JPEG,
  maxWidth: 320,
  quality: 75,
);
```

### Get video (or image) metadata

Works for videos **and** still images, for file paths and — on Android — `content://` URIs.

```dart
final VideoMetadata? meta = await VideoThumbnail.getVideoMetadata(
  video: '/path/to/video.mp4',
);
print('Size: ${meta?.width}×${meta?.height}');   // display dimensions
print('Rotation: ${meta?.rotation}°');
print('MIME: ${meta?.mimeType}');                // "video/mp4", "image/heic", …
print('Duration: ${meta?.duration}');            // null for images
print('Captured: ${meta?.capturedAt}');          // when it was shot
print('Modified: ${meta?.modifiedAt}');          // file mtime
print('Camera: ${meta?.cameraMake} ${meta?.cameraModel}');

// gps is null as a whole when the file has no location — never 0, 0.
final gps = meta?.gps;
if (gps != null) {
  print('Location: ${gps.lat}, ${gps.lon} @ ${gps.alt ?? 'unknown'}m');
}
```

> **Every field can be `null`.** What comes back depends entirely on what the source
> file records and on the platform — see the table below before relying on any of them.

### Clear the in-memory cache

```dart
await VideoThumbnail.clearCache();
```

---

## 📖 API Reference

### `VideoThumbnail.thumbnailData`

```dart
static Future<Uint8List?> thumbnailData({
  required String video,
  Map<String, String>? headers,
  ImageFormat imageFormat = ImageFormat.PNG,
  int maxHeight = 0,    // 0 = original
  int maxWidth  = 0,    // 0 = original
  int timeMs    = 0,    // ms from start
  int quality   = 10,   // 0-100, ignored for PNG
})
```

### `VideoThumbnail.thumbnailFile`

```dart
static Future<String?> thumbnailFile({
  required String video,
  Map<String, String>? headers,
  String? thumbnailPath,           // directory OR full file path
  ImageFormat imageFormat = ImageFormat.PNG,
  int maxHeight = 0,
  int maxWidth  = 0,
  int timeMs    = 0,
  int quality   = 10,
})
```

### `VideoThumbnail.thumbnailDataList`

```dart
static Future<List<Uint8List?>> thumbnailDataList({
  required String video,
  Map<String, String>? headers,
  required List<int> timesMs,
  ImageFormat imageFormat = ImageFormat.JPEG,
  int maxHeight = 0,
  int maxWidth  = 0,
  int quality   = 75,
})
```

### `VideoThumbnail.getVideoMetadata`

```dart
static Future<VideoMetadata?> getVideoMetadata({
  required String video,
  Map<String, String>? headers,
})
```

Accepts a video **or** an image. Returns a `VideoMetadata` object:

| Field | Type | Description |
|-------|------|-------------|
| `width` | `int` | Display width (after rotation) |
| `height` | `int` | Display height (after rotation) |
| `rotation` | `int` | Clockwise rotation: 0, 90, 180, 270 |
| `mimeType` | `String?` | e.g. `"video/mp4"`, `"image/heic"` |
| `duration` | `Duration?` | `null` for images and when unknown |
| `durationMs` | `int` | Duration in milliseconds; `0` when there is none |
| `capturedAt` | `DateTime?` | When the photo/video was taken |
| `modifiedAt` | `DateTime?` | Last file modification time |
| `cameraMake` | `String?` | e.g. `"Apple"` |
| `cameraModel` | `String?` | e.g. `"iPhone 15 Pro"` |
| `gps` | `GpsCoordinates?` | `null` as a group when there is no location |

`GpsCoordinates` exposes `lat` and `lon` (both `double`) plus `alt` (`double?`, `null`
when no altitude was recorded).

#### Nullability

**Any field above other than `width`, `height`, `rotation` and `durationMs` may be `null`**,
independently of the others — a file with EXIF GPS but no camera model returns the location
and a `null` `cameraModel`. Nothing throws because one tag is missing.

`durationMs` is kept non-nullable for backwards compatibility and reports `0` when there is
no duration; use `duration` to tell "no duration" apart from "zero".

#### What each platform can supply

| Field | Android | iOS |
|-------|---------|-----|
| `capturedAt` | images: EXIF · videos: container date | images: EXIF · videos: creation date |
| `cameraMake` / `cameraModel` | images only (EXIF) | images (EXIF) and videos (asset metadata) |
| `gps` | images: EXIF · videos: ISO-6709 tag | images: EXIF · videos: ISO-6709 tag |
| `modifiedAt` | file paths and `content://` | file paths |

`MediaMetadataRetriever` exposes no camera make/model keys, so those are always `null` for
**videos on Android**. On iOS, metadata for images is read only from local files; remote URLs
are handled through AVFoundation.

`capturedAt` is best-effort: EXIF records local time with no UTC offset, so when the file
carries no explicit offset the timestamp is interpreted in the device's current time zone.

### `VideoThumbnail.clearCache`

```dart
static Future<void> clearCache()
```

Evicts all entries from the native in-memory cache. Call this during low-memory events or when the app moves to background.

---

## ⚠️ Error Handling

All methods throw `ThumbnailException` on failure:

```dart
try {
  final bytes = await VideoThumbnail.thumbnailData(video: path);
} on ThumbnailException catch (e) {
  switch (e.code) {
    case ThumbnailErrorCode.fileNotFound:
      print('File does not exist: ${e.message}');
    case ThumbnailErrorCode.unsupportedFormat:
      print('Codec not supported: ${e.message}');
    case ThumbnailErrorCode.ioError:
      print('I/O error: ${e.message}');
    default:
      print('Unknown error: ${e.message}');
  }
}
```

### Error Codes

| Code | Cause |
|------|-------|
| `fileNotFound` | File path does not exist |
| `unsupportedFormat` | Video codec not supported or frame undecodable |
| `corruptedVideo` | Thumbnail could not be generated from the video |
| `ioError` | Disk full, permission denied, or write failure |
| `unknown` | Unexpected native error |

---

## 🖼️ Supported Image Formats

| Enum | Android | iOS | Quality param |
|------|---------|-----|:-------------:|
| `ImageFormat.JPEG` | ✅ All APIs | ✅ All | ✅ |
| `ImageFormat.PNG` | ✅ All APIs | ✅ All | ❌ (lossless) |
| `ImageFormat.WEBP` | ✅ All APIs | ✅ (libwebp) | ✅ |
| `ImageFormat.HEIC` | ✅ API 30+ | ✅ iOS 13+ | ✅ |

> **Note:** HEIC falls back to JPEG on older OS versions.

---

## 🍎 iOS: Swift Package Manager (SPM)

This plugin ships both a Swift package (`ios/video_thumbnail_gen/Package.swift`) and a
CocoaPods podspec (`ios/video_thumbnail_gen.podspec`), so it works with either dependency
manager — no action is needed on your side.

The iOS implementation is written in Swift. Every format behaves identically under both
integrations: Apple provides no WebP encoder, so WebP goes through `libwebp` — supplied by the
`libwebp` pod under CocoaPods, and by the
[SDWebImage/libwebp-Xcode](https://github.com/SDWebImage/libwebp-Xcode) package under Swift
Package Manager. Both build the same upstream libwebp 1.6 sources.

**Swift Package Manager** (opt in per machine):
```bash
flutter config --enable-swift-package-manager
```
Flutter then adds the plugin to your Xcode project under **Package Dependencies**.

**CocoaPods** (default):
```bash
flutter config --no-enable-swift-package-manager
```

---

## 🔍 Keywords & Use Cases

This plugin is designed to support a wide range of video preview and thumbnail extraction use cases, including:
* **Flutter video thumbnail generator**: Convert any local video file, asset, or remote stream into high-quality preview images.
* **Get thumbnail from video URL**: Extract and download thumbnails from remote HTTP/HTTPS video links.
* **Flutter YouTube thumbnail**: Retrieve YouTube video cover images natively via public CDNs with automatic fallback resolutions.
* **Video to image in Flutter**: Capture video frames as raw bytes (`Uint8List`) or save them directly as files (JPEG, PNG, WebP, HEIC).
* **High-speed frame extraction**: Extract multiple video frames at once using batch processing, keeping the native decoder open for efficiency.

---

## 🤝 Contributing

Issues and pull requests are welcome at [github.com/Itsxhadi/video_thumbnail_gen](https://github.com/Itsxhadi/video_thumbnail_gen).

---

## 🏅 Credits & Acknowledgements

This plugin is a fork of the original [**video_thumbnail**](https://pub.dev/packages/video_thumbnail) package by [**justsoft**](https://github.com/justsoft/video_thumbnail), rebranded as **video_thumbnail_gen** for maintenance and improvements.

The foundational idea, original platform channel design, and initial native implementations are the work of the original author.
This fork extends the original with new APIs, a modernised build system, improved error handling, and additional features.

| Role | Person |
|------|--------|
| **Original Author / Idea** | [justsoft](https://github.com/justsoft/video_thumbnail) |
| **Maintainer / Updater** | [Hadi (Itsxhadi)](https://github.com/Itsxhadi) |

---

## 👤 Author

**Hadi**
- 📧 [hadi7786x@gmail.com](mailto:hadi7786x@gmail.com)
- 🐙 [github.com/Itsxhadi](https://github.com/Itsxhadi)

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.
