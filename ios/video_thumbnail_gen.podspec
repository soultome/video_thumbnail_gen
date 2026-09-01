#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
Pod::Spec.new do |s|
  s.name             = 'video_thumbnail_gen'
  s.version          = '0.7.0'
  s.summary          = 'Flutter plugin for generating video thumbnails on Android and iOS.'
  s.description      = <<-DESC
A production-grade Flutter plugin for generating video thumbnails.
Supports JPEG, PNG, WebP, and HEIC formats with batch extraction,
video metadata, in-memory caching, and typed error handling.
                       DESC
  s.homepage         = 'https://github.com/Itsxhadi/video_thumbnail_gen'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Hadi' => 'hadi7786x@gmail.com' }
  s.source           = { :path => '.' }
  # The Swift plugin plus the Objective-C libwebp bridge. Under CocoaPods both
  # compile into a single module, so the Swift code sees VTGWebPEncoder through
  # the generated umbrella header without an explicit import.
  s.source_files = [
    'video_thumbnail_gen/Sources/video_thumbnail_gen/**/*.swift',
    'video_thumbnail_gen/Sources/video_thumbnail_gen_webp/**/*.{h,m}'
  ]
  s.public_header_files = 'video_thumbnail_gen/Sources/video_thumbnail_gen_webp/include/**/*.h'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'USER_HEADER_SEARCH_PATHS' => '$(inherited) ${PODS_ROOT}/libwebp/**'
  }
  s.dependency 'Flutter'
  s.dependency 'libwebp', '~> 1.6'

  s.ios.deployment_target = '13.0'
  s.swift_version = '5.9'
end
