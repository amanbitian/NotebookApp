import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Stable per-install device identifier used to stamp `PageMeta.deviceID` and journal
/// rows. Not the same as `identifierForVendor`, which can change on reinstall — this
/// value is generated once and persisted so conflict detection and journal provenance
/// stay meaningful across reinstalls within the same iCloud account's synced defaults.
enum DeviceIdentity {
    private static let key = "com.amancisodia.NotebookApp.deviceID"

    static var current: String = {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()
}
