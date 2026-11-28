import Foundation
import Photos

/// Albums in the Photos library (iCloud syncs them to the user's other devices). Ids are PhotoKit local identifiers,
/// for albums and for photos (what photo_manager uses as an asset's id). Runs off the main thread: the changes wait.
enum Albums {
  struct Failure: LocalizedError {
    let errorDescription: String?
  }

  private static func album(_ id: String) -> PHAssetCollection? {
    PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
  }

  /// The album [known] when it still exists (renamed to [title] if it differs); else the user's album already called
  /// [title]; else a new one. Returns its id.
  static func ensure(title: String, known: String?) throws -> String {
    if let k = known, let c = album(k) {
      if c.localizedTitle != title {
        try PHPhotoLibrary.shared().performChangesAndWait {
          PHAssetCollectionChangeRequest(for: c)?.title = title
        }
      }
      return c.localIdentifier
    }
    let byTitle = PHFetchOptions()
    byTitle.predicate = NSPredicate(format: "title = %@", title)
    if let c = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: byTitle).firstObject {
      return c.localIdentifier
    }
    var made: String?
    try PHPhotoLibrary.shared().performChangesAndWait {
      made = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
        .placeholderForCreatedAssetCollection.localIdentifier
    }
    guard let id = made else { throw Failure(errorDescription: "could not make the album \(title)") }
    return id
  }

  /// The user's own albums: id, title, and when the first and last photo in each was taken (epoch ms, absent if empty).
  static func list() -> [[String: Any]] {
    var out: [[String: Any]] = []
    let all = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
    all.enumerateObjects { c, _, _ in
      guard let title = c.localizedTitle, !title.isEmpty else { return }
      var a: [String: Any] = ["id": c.localIdentifier, "title": title]
      for (key, ascending) in [("start", true), ("end", false)] {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
        o.fetchLimit = 1
        if let d = PHAsset.fetchAssets(in: c, options: o).firstObject?.creationDate {
          a[key] = Int(d.timeIntervalSince1970 * 1000)
        }
      }
      out.append(a)
    }
    return out
  }

  /// Adds photos to (or removes them from) an album. Photos no longer in the library are skipped.
  static func change(_ albumId: String, _ assets: [String], add: Bool) throws {
    guard let c = album(albumId) else {
      if add { throw Failure(errorDescription: "the album is gone from Photos") }
      return
    }
    let found = PHAsset.fetchAssets(withLocalIdentifiers: assets, options: nil)
    if found.count == 0 { return }
    try PHPhotoLibrary.shared().performChangesAndWait {
      guard let r = PHAssetCollectionChangeRequest(for: c) else { return }
      if add { r.addAssets(found) } else { r.removeAssets(found) }
    }
  }

  /// Whether the photo is still in the library (not deleted).
  static func exists(_ id: String) -> Bool {
    PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count > 0
  }
}
