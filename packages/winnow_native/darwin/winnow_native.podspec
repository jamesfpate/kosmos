#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint winnow_native.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'winnow_native'
  s.version          = '0.0.1'
  s.summary          = 'Winnow's Apple bits: photo metadata, thumbnails, Trash (macOS); Photos albums (iOS and macOS).'
  s.description      = <<-DESC
Winnow's Apple bits: photo metadata, thumbnails, Trash (macOS); Photos albums (iOS and macOS).
                       DESC
  s.homepage         = 'https://github.com/jamesfpate/winnow'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'James Pate' => 'james@jamespate.net' }

  s.source           = { :path => '.' }
  s.source_files = 'winnow_native/Sources/winnow_native/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'winnow_native_privacy' => ['winnow_native/Sources/winnow_native/PrivacyInfo.xcprivacy']}

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.frameworks = 'AVFoundation', 'ImageIO', 'CoreGraphics', 'Photos'
  s.swift_version = '5.0'
end
