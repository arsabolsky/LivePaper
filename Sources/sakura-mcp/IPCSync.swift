import Foundation

enum IPCSync {
    private static let center = DistributedNotificationCenter.default()
    private static let stateChangedName = "SakuraWallpaperStateChanged"

    /// Post a notification that state has changed (GUI app picks this up to refresh UI)
    static func notifyStateChanged(screenID: String? = nil, field: String? = nil) {
        var info: [String: String] = [:]
        if let id = screenID { info["screenID"] = id }
        if let f = field { info["field"] = f }
        center.postNotificationName(NSNotification.Name(stateChangedName),
                                     object: nil,
                                     userInfo: info.isEmpty ? nil : info,
                                     deliverImmediately: true)
    }

    /// Observe state changes from the GUI app
    static func observeStateChanges(handler: @escaping ([String: String]?) -> Void) {
        center.addObserver(forName: NSNotification.Name(stateChangedName),
                            object: nil,
                            queue: .main) { notification in
            handler(notification.userInfo as? [String: String])
        }
    }
}
