// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// video_thumbnail_gen — Swift Package Manager manifest
// Author : Hadi <hadi7786x@gmail.com>
// GitHub : https://github.com/Itsxhadi/video_thumbnail_gen
//
// Apple ships no WebP encoder in ImageIO on any platform, so WebP output needs
// libwebp. CocoaPods gets it from the `libwebp` pod; Swift Package Manager gets
// it from the package dependency declared below. Both build the same upstream
// libwebp 1.6 sources, so every format behaves identically under either
// integration.

import PackageDescription

let package = Package(
    name: "video_thumbnail_gen",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "video-thumbnail-gen", targets: ["video_thumbnail_gen"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        // Upstream libwebp, packaged for SwiftPM by the same maintainers as the
        // `libwebp` CocoaPod, and built from the same sources.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.6.0"),
    ],
    targets: [
        // Objective-C bridge to libwebp. Swift cannot link a C library directly
        // from a Swift target, so the WebP encoder lives in its own target.
        .target(
            name: "video_thumbnail_gen_webp",
            dependencies: [
                .product(name: "libwebp", package: "libwebp-Xcode")
            ]
        ),
        .target(
            name: "video_thumbnail_gen",
            dependencies: [
                "video_thumbnail_gen_webp",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            resources: [
                // This plugin bundles no resources. If your fork requires a privacy
                // manifest, add a PrivacyInfo.xcprivacy alongside the sources and
                // uncomment the line below. For more information, see
                // https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
                // .process("PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("UIKit"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
    ]
)
