import AVFoundation
import Cocoa
import FlutterMacOS
import ImageIO

/// Winnow's macOS calls: photo/video metadata and thumbnails (ImageIO and AVFoundation decode HEIC, RAW and every
/// video format the Mac plays, which Flutter's own decoders don't), and moving files to the Trash.
public class WinnowNativePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "winnow_native", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(WinnowNativePlugin(), channel: channel)
  }

  private let work = DispatchQueue(label: "winnow_native", qos: .userInitiated, attributes: .concurrent)

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "probe":
      let paths = args["paths"] as? [String] ?? []
      run(result) { paths.map { path -> Any in
        if let info = Self.probe(path) { return info }
        return NSNull()
      } }
    case "thumb":
      let path = args["path"] as? String ?? ""
      let size = args["size"] as? Int ?? 512
      run(result) {
        if let data = Self.thumb(path, size) { return FlutterStandardTypedData(bytes: data) }
        return NSNull()
      }
    case "trash":
      let paths = args["paths"] as? [String] ?? []
      run(result) {
        paths.filter { (try? FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil)) != nil }
      }
    case "openUrl":
      if let s = args["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func run(_ result: @escaping FlutterResult, _ f: @escaping () -> Any) {
    work.async {
      let v = f()
      DispatchQueue.main.async { result(v) }
    }
  }

  private static let videoTypes: Set<String> = ["mp4", "mov", "m4v", "3gp", "avi", "mkv", "mts", "m2ts", "webm"]

  private static func isVideo(_ path: String) -> Bool { videoTypes.contains((path as NSString).pathExtension.lowercased()) }

  /// Width and height as displayed, when it was taken (epoch ms, from EXIF or the video's creation date) and a video's
  /// length in seconds. Nil when the file can't be read.
  static func probe(_ path: String) -> [String: Any]? {
    let url = URL(fileURLWithPath: path)
    if isVideo(path) {
      let asset = AVURLAsset(url: url)
      let secs = CMTimeGetSeconds(asset.duration)
      var out: [String: Any] = ["dur": secs.isFinite ? Int(secs.rounded()) : 0]
      if let track = asset.tracks(withMediaType: .video).first {
        let size = track.naturalSize.applying(track.preferredTransform)
        out["w"] = Int(abs(size.width))
        out["h"] = Int(abs(size.height))
      }
      if let date = asset.creationDate?.dateValue { out["taken"] = date.timeIntervalSince1970 * 1000 }
      return out
    }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    else { return nil }
    var w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    var h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
    var out: [String: Any] = ["w": w, "h": h, "dur": 0]
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
      ?? tiff[kCGImagePropertyTIFFDateTime] as? String
    if let raw = raw, let date = exifDate(raw, offset: exif["OffsetTimeOriginal" as CFString] as? String) {
      out["taken"] = date.timeIntervalSince1970 * 1000
    }
    return out
  }

  /// EXIF "2024:10:05 12:34:56", in the camera's own offset when it recorded one, else the Mac's time zone.
  private static func exifDate(_ s: String, offset: String?) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    if let o = offset, let tz = TimeZone(identifier: "GMT" + o.replacingOccurrences(of: ":", with: "")) { f.timeZone = tz }
    return f.date(from: String(s.prefix(19)))
  }

  /// A JPEG at most [size] px on its long side, upright.
  static func thumb(_ path: String, _ size: Int) -> Data? {
    let url = URL(fileURLWithPath: path)
    var img: CGImage?
    if isVideo(path) {
      let asset = AVURLAsset(url: url)
      let gen = AVAssetImageGenerator(asset: asset)
      gen.appliesPreferredTrackTransform = true
      gen.maximumSize = CGSize(width: size, height: size)
      let dur = CMTimeGetSeconds(asset.duration)
      let at = CMTime(seconds: dur.isFinite && dur > 2 ? 1 : 0, preferredTimescale: 600)
      img = try? gen.copyCGImage(at: at, actualTime: nil)
    } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
      let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: size,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
    guard let image = img else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
  }
}
