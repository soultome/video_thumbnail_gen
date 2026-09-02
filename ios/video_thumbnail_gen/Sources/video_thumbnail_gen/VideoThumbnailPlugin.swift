//
//  VideoThumbnailPlugin.swift
//  video_thumbnail_gen
//
//  Author : Hadi <hadi7786x@gmail.com>
//  GitHub : https://github.com/Itsxhadi/video_thumbnail_gen
//  License: MIT
//
//  Supports: data, dataList, file, metadata, clearCache.
//

import AVFoundation
import Flutter
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

// Under Swift Package Manager the libwebp bridge is a separate target and must
// be imported. Under CocoaPods everything lands in one module, so the type is
// already visible and importing it would fail.
#if SWIFT_PACKAGE
import video_thumbnail_gen_webp
#endif

public final class VideoThumbnailPlugin: NSObject, FlutterPlugin {

    // MARK: - Contract

    private static let channelName = "plugins.itsxhadi.com/video_thumbnail_gen"

    /// Error codes shared with the Android implementation and the Dart layer.
    private enum ErrorCode {
        static let fileNotFound = "FILE_NOT_FOUND"
        static let unsupported = "UNSUPPORTED_FORMAT"
        static let corrupted = "CORRUPTED_VIDEO"
        static let io = "IO_ERROR"
        static let unknown = "UNKNOWN"
    }

    /// Mirrors `ImageFormat` on the Dart side.
    private enum ImageFormat: Int {
        case jpeg = 0
        case png = 1
        case webp = 2
        case heic = 3

        init(argument: Int) {
            self = ImageFormat(rawValue: argument) ?? .jpeg
        }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .webp: return "webp"
            case .heic: return "heic"
            }
        }
    }

    /// NSCache cost cap, in bytes.
    private static let cacheByteLimit = 40 * 1024 * 1024  // 40 MB

    /// How long the batch generator may run before we give up on a corrupt video.
    private static let batchTimeout: DispatchTimeInterval = .seconds(30)

    private let thumbnailCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = VideoThumbnailPlugin.cacheByteLimit
        return cache
    }()

    private static let workQueue = DispatchQueue(
        label: "com.itsxhadi.video_thumbnail_gen.work",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Plugin registration

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(VideoThumbnailPlugin(), channel: channel)
    }

    // MARK: - Method dispatch

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if call.method == "clearCache" {
            thumbnailCache.removeAllObjects()
            Self.reply(result, with: nil)
            return
        }

        guard let args = call.arguments as? [String: Any],
              let video = args["video"] as? String
        else {
            Self.reply(result, with: FlutterError(
                code: ErrorCode.unsupported,
                message: "Missing or malformed arguments",
                details: nil
            ))
            return
        }

        guard let url = Self.makeURL(from: video) else {
            Self.reply(result, with: FlutterError(
                code: ErrorCode.unsupported,
                message: "Not a usable video location: \(video)",
                details: nil
            ))
            return
        }

        let headers = args["headers"] as? [String: String]
        let format = ImageFormat(argument: args["format"] as? Int ?? 0)
        let maxHeight = args["maxh"] as? Int ?? 0
        let maxWidth = args["maxw"] as? Int ?? 0
        let timeMs = args["timeMs"] as? Int ?? 0
        let quality = args["quality"] as? Int ?? 0
        let isLocalFile = video.hasPrefix("file://") || video.hasPrefix("/")

        switch call.method {
        case "data":
            let cacheKey = "\(video)_\(timeMs)_\(format.rawValue)_\(maxHeight)_\(maxWidth)_\(quality)"
            handleData(
                url: url, headers: headers, format: format, maxHeight: maxHeight,
                maxWidth: maxWidth, timeMs: timeMs, quality: quality,
                cacheKey: cacheKey, result: result
            )

        case "dataList":
            handleDataList(
                url: url, headers: headers, format: format, maxHeight: maxHeight,
                maxWidth: maxWidth, quality: quality,
                timesMs: args["timesMs"] as? [Int], result: result
            )

        case "file":
            handleFile(
                url: url, headers: headers, format: format, maxHeight: maxHeight,
                maxWidth: maxWidth, timeMs: timeMs, quality: quality,
                path: args["path"] as? String, isLocalFile: isLocalFile, result: result
            )

        case "metadata":
            Self.handleMetadata(url: url, headers: headers, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - data (single frame → memory)

    private func handleData(
        url: URL,
        headers: [String: String]?,
        format: ImageFormat,
        maxHeight: Int,
        maxWidth: Int,
        timeMs: Int,
        quality: Int,
        cacheKey: String,
        result: @escaping FlutterResult
    ) {
        Self.workQueue.async { [thumbnailCache] in
            if let cached = thumbnailCache.object(forKey: cacheKey as NSString) {
                Self.reply(result, with: FlutterStandardTypedData(bytes: cached as Data))
                return
            }

            let data = Self.generateThumbnail(
                url: url, headers: headers, format: format,
                maxHeight: maxHeight, maxWidth: maxWidth,
                timeMs: timeMs, quality: quality
            )?.data

            if let data {
                thumbnailCache.setObject(data as NSData, forKey: cacheKey as NSString, cost: data.count)
                Self.reply(result, with: FlutterStandardTypedData(bytes: data))
            } else {
                Self.reply(result, with: nil)
            }
        }
    }

    // MARK: - dataList (batch frames → memory)

    private func handleDataList(
        url: URL,
        headers: [String: String]?,
        format: ImageFormat,
        maxHeight: Int,
        maxWidth: Int,
        quality: Int,
        timesMs: [Int]?,
        result: @escaping FlutterResult
    ) {
        guard let timesMs, !timesMs.isEmpty else {
            Self.reply(result, with: [])
            return
        }

        Self.workQueue.async {
            let generator = Self.makeGenerator(
                url: url, headers: headers,
                maxHeight: maxHeight, maxWidth: maxWidth, alwaysConstrainSize: true
            )

            let requestedTimes = timesMs.map { NSValue(time: CMTimeMake(value: Int64($0), timescale: 1000)) }

            // Match completions back to their slot by requested time, which avoids
            // the rounding drift a float comparison would introduce.
            var indexMap: [Int: Int] = [:]
            for (index, ms) in timesMs.enumerated() {
                indexMap[ms] = index
            }

            let collector = BatchCollector(count: timesMs.count)
            let semaphore = DispatchSemaphore(value: 0)

            generator.generateCGImagesAsynchronously(forTimes: requestedTimes) {
                requestedTime, cgImage, _, generatorResult, _ in
                let callIdx = Int((CMTimeGetSeconds(requestedTime) * 1000.0).rounded())
                if let slot = indexMap[callIdx],
                   generatorResult == .succeeded,
                   let cgImage,
                   let encoded = Self.encode(image: cgImage, format: format, quality: quality) {
                    collector.set(encoded.data, at: slot)
                }
                if collector.completeOne() {
                    semaphore.signal()
                }
            }

            // Bail out rather than hang forever on a corrupt video.
            _ = semaphore.wait(timeout: .now() + Self.batchTimeout)

            Self.reply(result, with: collector.ordered())
        }
    }

    // MARK: - file (single frame → disk)

    private func handleFile(
        url: URL,
        headers: [String: String]?,
        format: ImageFormat,
        maxHeight: Int,
        maxWidth: Int,
        timeMs: Int,
        quality: Int,
        path: String?,
        isLocalFile: Bool,
        result: @escaping FlutterResult
    ) {
        var destinationPath = path
        if destinationPath == nil && !isLocalFile {
            destinationPath = NSSearchPathForDirectoriesInDomains(
                .cachesDirectory, .userDomainMask, true
            ).last
        }
        let requestedPath = destinationPath

        Self.workQueue.async {
            guard let encoded = Self.generateThumbnail(
                url: url, headers: headers, format: format,
                maxHeight: maxHeight, maxWidth: maxWidth,
                timeMs: timeMs, quality: quality
            ) else {
                Self.reply(result, with: FlutterError(
                    code: ErrorCode.corrupted,
                    message: "Failed to generate thumbnail",
                    details: nil
                ))
                return
            }

            // Use the format that was actually produced, so a WebP request that fell
            // back to JPEG is never written under a .webp name.
            var target = url.deletingPathExtension()
                .appendingPathExtension(encoded.format.fileExtension)

            if let requestedPath, !requestedPath.isEmpty {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: requestedPath, isDirectory: &isDirectory)
                if isDirectory.boolValue || requestedPath.hasSuffix("/") {
                    target = URL(fileURLWithPath: requestedPath)
                        .appendingPathComponent(target.lastPathComponent)
                } else {
                    target = URL(fileURLWithPath: requestedPath)
                }
            }

            do {
                try encoded.data.write(to: target, options: .atomic)
            } catch {
                Self.reply(result, with: FlutterError(
                    code: ErrorCode.io,
                    message: error.localizedDescription,
                    details: nil
                ))
                return
            }

            let absolute = target.absoluteString
            let fullPath = absolute.hasPrefix("file://")
                ? String(absolute.dropFirst(7))
                : absolute
            Self.reply(result, with: fullPath)
        }
    }

    // MARK: - metadata

    /// Everything the video path needs to read from AVFoundation. Both the modern
    /// and the legacy loader fill this in, so the payload builder stays shared.
    private struct VideoFacts {
        var durationMs: Int64?
        var width = 0
        var height = 0
        var rotation = 0
        var creationDate: Date?
        var make: String?
        var model: String?
        var isoLocation: String?
    }

    private static func handleMetadata(
        url: URL,
        headers: [String: String]?,
        result: @escaping FlutterResult
    ) {
        // Match Android, which reports a missing file as FILE_NOT_FOUND rather
        // than handing back a metadata map full of zeros.
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            reply(result, with: FlutterError(
                code: ErrorCode.fileNotFound,
                message: "No such file: \(url.path)",
                details: nil
            ))
            return
        }

        if #available(iOS 16.0, *) {
            Task.detached(priority: .userInitiated) {
                if let image = imageMetadata(at: url) {
                    reply(result, with: image)
                    return
                }
                let facts = await videoFacts(from: makeAsset(url: url, headers: headers))
                reply(result, with: payload(from: facts, url: url))
            }
        } else {
            workQueue.async {
                if let image = imageMetadata(at: url) {
                    reply(result, with: image)
                    return
                }
                let facts = videoFactsLegacy(from: makeAsset(url: url, headers: headers))
                reply(result, with: payload(from: facts, url: url))
            }
        }
    }

    // MARK: metadata — video

    @available(iOS 16.0, *)
    private static func videoFacts(from asset: AVURLAsset) async -> VideoFacts {
        var facts = VideoFacts()

        if let duration = try? await asset.load(.duration), duration.isNumeric {
            facts.durationMs = Int64(CMTimeGetSeconds(duration) * 1000.0)
        }

        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            facts.rotation = rotation(from: transform)
            (facts.width, facts.height) = orient(size: size, rotation: facts.rotation)
        }

        if let item = try? await asset.load(.creationDate),
           let value = try? await item.load(.dateValue) {
            facts.creationDate = value
        }

        var items = (try? await asset.load(.commonMetadata)) ?? []
        items += (try? await asset.loadMetadata(for: .quickTimeMetadata)) ?? []
        items += (try? await asset.loadMetadata(for: .quickTimeUserData)) ?? []

        for item in items {
            if facts.make != nil, facts.model != nil, facts.isoLocation != nil { break }
            guard let key = metadataKey(of: item), wants(key: key, given: facts) else { continue }
            guard let text = try? await item.load(.stringValue), !text.isEmpty else { continue }
            apply(key: key, text: text, to: &facts)
        }

        return facts
    }

    private static func videoFactsLegacy(from asset: AVURLAsset) -> VideoFacts {
        var facts = VideoFacts()

        let duration = asset.duration
        if duration.isNumeric {
            facts.durationMs = Int64(CMTimeGetSeconds(duration) * 1000.0)
        }

        if let track = asset.tracks(withMediaType: .video).first {
            facts.rotation = rotation(from: track.preferredTransform)
            (facts.width, facts.height) = orient(size: track.naturalSize, rotation: facts.rotation)
        }

        facts.creationDate = asset.creationDate?.dateValue

        var items = asset.commonMetadata
        items += asset.metadata

        for item in items {
            if facts.make != nil, facts.model != nil, facts.isoLocation != nil { break }
            guard let key = metadataKey(of: item), wants(key: key, given: facts),
                  let text = item.stringValue, !text.isEmpty else { continue }
            apply(key: key, text: text, to: &facts)
        }

        return facts
    }

    /// The metadata key as a plain string, whichever namespace it came from.
    private static func metadataKey(of item: AVMetadataItem) -> String? {
        if let common = item.commonKey?.rawValue { return common }
        if let key = item.key as? String { return key }
        return item.identifier?.rawValue
    }

    /// Whether this key is one we still need — checked before paying for the
    /// item's value, which is an `await` on the modern path.
    private static func wants(key: String, given facts: VideoFacts) -> Bool {
        let normalised = key.lowercased()
        if normalised.hasSuffix("make") { return facts.make == nil }
        if normalised.hasSuffix("model") { return facts.model == nil }
        if normalised.contains("location") { return facts.isoLocation == nil }
        return false
    }

    /// Folds one metadata item into `facts`. Unknown keys are ignored, so a file
    /// carrying only some of these still yields the rest.
    private static func apply(key: String, text: String, to facts: inout VideoFacts) {
        let normalised = key.lowercased()
        if normalised.hasSuffix("make"), facts.make == nil {
            facts.make = text
        } else if normalised.hasSuffix("model"), facts.model == nil {
            facts.model = text
        } else if normalised.contains("location"), facts.isoLocation == nil {
            facts.isoLocation = text
        }
    }

    private static func payload(from facts: VideoFacts, url: URL) -> [String: Any] {
        let coordinates = parseISO6709(facts.isoLocation)
        return [
            "durationMs": facts.durationMs as Any? ?? NSNull(),
            "width": facts.width,
            "height": facts.height,
            "rotation": facts.rotation,
            "mimeType": mimeType(for: url) as Any? ?? NSNull(),
            "capturedAt": epochMs(facts.creationDate) as Any? ?? NSNull(),
            "modifiedAt": fileModifiedAtMs(url) as Any? ?? NSNull(),
            "cameraMake": facts.make as Any? ?? NSNull(),
            "cameraModel": facts.model as Any? ?? NSNull(),
            "gps": coordinates ?? NSNull(),
        ]
    }

    // MARK: metadata — images

    /// Reads still-image metadata via ImageIO. Returns nil when `url` is not a
    /// local image, in which case the caller falls back to the AVFoundation path.
    ///
    /// Restricted to file URLs on purpose: `CGImageSourceCreateWithURL` would
    /// otherwise fetch a remote URL synchronously.
    private static func imageMetadata(at url: URL) -> [String: Any]? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let uti = CGImageSourceGetType(source) as String?,
              isImageType(uti)
        else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        let storedWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let storedHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotationDegrees = rotationForExifOrientation(orientation)
        // Orientations 5–8 are quarter turns, so the stored pixels are transposed
        // relative to how the image displays.
        let quarterTurn = orientation >= 5
        let width = quarterTurn ? storedHeight : storedWidth
        let height = quarterTurn ? storedWidth : storedHeight

        let capturedRaw = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        let offsetRaw = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
            ?? (exif[kCGImagePropertyExifOffsetTime] as? String)

        return [
            // Images have no duration; null is what distinguishes them from a
            // zero-length video.
            "durationMs": NSNull(),
            "width": width,
            "height": height,
            "rotation": rotationDegrees,
            "mimeType": mimeType(forIdentifier: uti) as Any? ?? NSNull(),
            "capturedAt": epochMs(exifDate(capturedRaw, utcOffset: offsetRaw)) as Any? ?? NSNull(),
            "modifiedAt": fileModifiedAtMs(url) as Any? ?? NSNull(),
            "cameraMake": (tiff[kCGImagePropertyTIFFMake] as? String) as Any? ?? NSNull(),
            "cameraModel": (tiff[kCGImagePropertyTIFFModel] as? String) as Any? ?? NSNull(),
            "gps": gpsPayload(from: gps) ?? NSNull(),
        ]
    }

    /// True only for identifiers that actually denote a still image.
    private static func isImageType(_ identifier: String) -> Bool {
        if #available(iOS 14.0, *) {
            return UTType(identifier)?.conforms(to: .image) ?? false
        }
        return (mimeType(forIdentifier: identifier) ?? "").hasPrefix("image/")
    }

    /// Clockwise display rotation implied by an EXIF orientation tag (1–8).
    private static func rotationForExifOrientation(_ orientation: Int) -> Int {
        switch orientation {
        case 3, 4: return 180
        case 5, 6: return 90
        case 7, 8: return 270
        default: return 0
        }
    }

    private static func gpsPayload(from gps: [CFString: Any]) -> [String: Any]? {
        guard let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
        else {
            // No usable fix: report the whole group as absent rather than 0, 0.
            return nil
        }

        let latitudeRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() ?? "N"
        let longitudeRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() ?? "E"

        var payload: [String: Any] = [
            "lat": latitudeRef == "S" ? -latitude : latitude,
            "lon": longitudeRef == "W" ? -longitude : longitude,
        ]

        if let altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue {
            // AltitudeRef 1 means below sea level.
            let belowSeaLevel = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1
            payload["alt"] = belowSeaLevel ? -altitude : altitude
        }
        return payload
    }

    // MARK: metadata — shared helpers

    /// Parses an ISO-6709 location string such as `+37.7749-122.4194+010.500/`.
    private static func parseISO6709(_ raw: String?) -> [String: Any]? {
        guard let raw, !raw.isEmpty else { return nil }
        let pattern = #"([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))
        else {
            return nil
        }

        func group(_ index: Int) -> Double? {
            guard let range = Range(match.range(at: index), in: raw) else { return nil }
            return Double(raw[range])
        }

        guard let latitude = group(1), let longitude = group(2) else { return nil }
        var payload: [String: Any] = ["lat": latitude, "lon": longitude]
        if let altitude = group(3) { payload["alt"] = altitude }
        return payload
    }

    /// Parses an EXIF timestamp (`yyyy:MM:dd HH:mm:ss`). Without an explicit UTC
    /// offset EXIF carries no time zone, so the device's zone is assumed.
    private static func exifDate(_ raw: String?, utcOffset: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let utcOffset, !utcOffset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            if let date = formatter.date(from: raw + utcOffset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: raw)
    }

    private static func epochMs(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000.0)
    }

    private static func fileModifiedAtMs(_ url: URL) -> Int64? {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return epochMs(modified)
    }

    private static func mimeType(for url: URL) -> String? {
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        if #available(iOS 14.0, *) {
            return UTType(filenameExtension: ext)?.preferredMIMEType
        }
        return legacyMimeTypes[ext.lowercased()]
    }

    private static func mimeType(forIdentifier identifier: String) -> String? {
        if #available(iOS 14.0, *) {
            return UTType(identifier)?.preferredMIMEType
        }
        return legacyMimeTypes[identifier.components(separatedBy: ".").last?.lowercased() ?? ""]
    }

    /// Minimal fallback for iOS 13, which predates `UTType`.
    private static let legacyMimeTypes: [String: String] = [
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime",
        "3gp": "video/3gpp", "avi": "video/x-msvideo", "mkv": "video/x-matroska",
        "webm": "video/webm", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "png": "image/png", "gif": "image/gif", "heic": "image/heic",
        "heif": "image/heif", "webp": "image/webp", "tiff": "image/tiff",
    ]


    /// Degrees clockwise, derived from the track's preferred transform.
    private static func rotation(from transform: CGAffineTransform) -> Int {
        var angle = atan2(transform.b, transform.a) * (180.0 / .pi)
        if angle < 0 { angle += 360 }
        return Int(angle.rounded())
    }

    /// Natural size with width/height swapped for quarter-turn rotations.
    private static func orient(size: CGSize, rotation: Int) -> (width: Int, height: Int) {
        rotation == 90 || rotation == 270
            ? (Int(size.height), Int(size.width))
            : (Int(size.width), Int(size.height))
    }

    // MARK: - Frame generation

    private static func makeAsset(url: URL, headers: [String: String]?) -> AVURLAsset {
        let options = headers.map { ["AVURLAssetHTTPHeaderFieldsKey": $0] }
        return AVURLAsset(url: url, options: options)
    }

    private static func makeGenerator(
        url: URL,
        headers: [String: String]?,
        maxHeight: Int,
        maxWidth: Int,
        alwaysConstrainSize: Bool
    ) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: makeAsset(url: url, headers: headers))
        generator.appliesPreferredTrackTransform = true
        if alwaysConstrainSize || maxWidth > 0 || maxHeight > 0 {
            generator.maximumSize = CGSize(width: maxWidth, height: maxHeight)
        }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTimeMake(value: 100, timescale: 1000)
        return generator
    }

    private static func generateThumbnail(
        url: URL,
        headers: [String: String]?,
        format: ImageFormat,
        maxHeight: Int,
        maxWidth: Int,
        timeMs: Int,
        quality: Int
    ) -> (data: Data, format: ImageFormat)? {
        let generator = makeGenerator(
            url: url, headers: headers,
            maxHeight: maxHeight, maxWidth: maxWidth, alwaysConstrainSize: false
        )
        guard let cgImage = copyImage(
            from: generator,
            at: CMTimeMake(value: Int64(timeMs), timescale: 1000)
        ) else {
            return nil
        }
        return encode(image: cgImage, format: format, quality: quality)
    }

    /// Blocking single-frame extraction. Always called off the main thread.
    private static func copyImage(from generator: AVAssetImageGenerator, at time: CMTime) -> CGImage? {
        if #available(iOS 16.0, *) {
            let semaphore = DispatchSemaphore(value: 0)
            let box = ImageBox()
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let error {
                    NSLog("[VideoThumbnailPlugin] generateThumbnail error: \(error)")
                }
                box.image = image
                semaphore.signal()
            }
            semaphore.wait()
            return box.image
        }

        do {
            return try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            NSLog("[VideoThumbnailPlugin] generateThumbnail error: \(error)")
            return nil
        }
    }

    // MARK: - Encoding (JPEG / PNG / WebP / HEIC)

    /// Encodes `image`, reporting the format actually produced. That can differ from
    /// the requested one: a WebP request falls back to JPEG when libwebp is absent,
    /// and the caller needs to know so it does not label the bytes as WebP.
    private static func encode(
        image: CGImage,
        format: ImageFormat,
        quality: Int
    ) -> (data: Data, format: ImageFormat)? {
        let compression = CGFloat(quality) * 0.01

        switch format {
        case .jpeg:
            return UIImage(cgImage: image)
                .jpegData(compressionQuality: compression)
                .map { ($0, .jpeg) }

        case .png:
            return UIImage(cgImage: image).pngData().map { ($0, .png) }

        case .heic:
            let heicData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                heicData, "public.heic" as CFString, 1, nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: compression
            ] as CFDictionary)
            CGImageDestinationFinalize(destination)
            return heicData.length > 0 ? (heicData as Data, .heic) : nil

        case .webp:
            if VTGWebPEncoder.isAvailable,
               let data = VTGWebPEncoder.encodedData(from: image, quality: Int32(quality)) {
                return (data, .webp)
            }
            NSLog("[VideoThumbnailPlugin] WebP not available; falling back to JPEG")
            return UIImage(cgImage: image)
                .jpegData(compressionQuality: compression)
                .map { ($0, .jpeg) }
        }
    }

    // MARK: - Helpers

    private static func makeURL(from video: String) -> URL? {
        if video.hasPrefix("file://") {
            return URL(fileURLWithPath: String(video.dropFirst(7)))
        }
        if video.hasPrefix("/") {
            return URL(fileURLWithPath: video)
        }
        return URL(string: video)
    }

    private static func reply(_ result: @escaping FlutterResult, with value: Any?) {
        DispatchQueue.main.async { result(value) }
    }
}

// MARK: - Batch result collection

/// Ordered, lock-guarded slots for the batch generator, whose completion handler
/// fires concurrently and out of order.
private final class BatchCollector {
    private let lock = NSLock()
    private var slots: [Data?]
    private var remaining: Int

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
        remaining = count
    }

    func set(_ data: Data, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(index) else { return }
        slots[index] = data
    }

    /// Records one completion; returns true once every frame has reported back.
    func completeOne() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        remaining -= 1
        return remaining <= 0
    }

    /// Frames in request order, with NSNull standing in for the ones that failed.
    func ordered() -> [Any] {
        lock.lock()
        defer { lock.unlock() }
        return slots.map { $0.map { FlutterStandardTypedData(bytes: $0) } ?? NSNull() }
    }
}

/// Carries a CGImage out of a completion handler that a semaphore is waiting on.
private final class ImageBox {
    var image: CGImage?
}
