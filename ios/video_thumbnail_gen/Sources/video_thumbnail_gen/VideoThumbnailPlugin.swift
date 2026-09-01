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

    private static func handleMetadata(
        url: URL,
        headers: [String: String]?,
        result: @escaping FlutterResult
    ) {
        let asset = makeAsset(url: url, headers: headers)

        if #available(iOS 16.0, *) {
            Task.detached(priority: .userInitiated) {
                let metadata = await loadMetadata(from: asset)
                reply(result, with: metadata)
            }
        } else {
            workQueue.async {
                reply(result, with: loadMetadataLegacy(from: asset))
            }
        }
    }

    @available(iOS 16.0, *)
    private static func loadMetadata(from asset: AVURLAsset) async -> [String: Any] {
        var durationMs: Int64 = 0
        var width = 0
        var height = 0
        var rotation = 0
        var mimeType: Any = NSNull()

        if let duration = try? await asset.load(.duration) {
            durationMs = Int64(CMTimeGetSeconds(duration) * 1000.0)
        }

        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            rotation = self.rotation(from: transform)
            (width, height) = orient(size: size, rotation: rotation)

            if let descriptions = try? await track.load(.formatDescriptions),
               let first = descriptions.first,
               CMFormatDescriptionGetMediaType(first) == kCMMediaType_Video {
                mimeType = "video/mp4"
            }
        }

        return [
            "durationMs": durationMs,
            "width": width,
            "height": height,
            "rotation": rotation,
            "mimeType": mimeType,
        ]
    }

    private static func loadMetadataLegacy(from asset: AVURLAsset) -> [String: Any] {
        var width = 0
        var height = 0
        var rotation = 0
        var mimeType: Any = NSNull()

        let durationMs = Int64(CMTimeGetSeconds(asset.duration) * 1000.0)

        if let track = asset.tracks(withMediaType: .video).first {
            rotation = self.rotation(from: track.preferredTransform)
            (width, height) = orient(size: track.naturalSize, rotation: rotation)

            // The legacy accessor is typed [Any], but only ever holds CMFormatDescription.
            if let first = track.formatDescriptions.first,
               CMFormatDescriptionGetMediaType(first as! CMFormatDescription) == kCMMediaType_Video {
                mimeType = "video/mp4"
            }
        }

        return [
            "durationMs": durationMs,
            "width": width,
            "height": height,
            "rotation": rotation,
            "mimeType": mimeType,
        ]
    }

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
