// SecurityScopedResourceManager.swift — reference-counting wrapper for security-scoped resources.
// Copied verbatim from Phosphene/SecurityScopedResourceManager.swift.
// Used by MediaDeploymentService when accessing user-selected video files via bookmarks.
//
// Must balance startAccessingSecurityScopedResource with stopAccessingSecurityScopedResource
// or the write to the extension container will be denied by the sandbox.

import Foundation

@MainActor
final class SecurityScopedResourceManager {
    static let shared = SecurityScopedResourceManager()

    private var activeResources: [URL: Int] = [:]

    private init() {}

    /// Request access to a security-scoped resource.
    /// If the resource is already open, increments the reference count and returns true.
    func requestAccess(to url: URL) -> Bool {
        if let count = activeResources[url] {
            activeResources[url] = count + 1
            return true
        }
        let granted = url.startAccessingSecurityScopedResource()
        if granted { activeResources[url] = 1 }
        return granted
    }

    /// Release one reference to a security-scoped resource.
    /// Calls stopAccessingSecurityScopedResource when the reference count reaches zero.
    func releaseAccess(to url: URL) {
        guard let count = activeResources[url] else { return }
        if count > 1 {
            activeResources[url] = count - 1
        } else {
            url.stopAccessingSecurityScopedResource()
            activeResources.removeValue(forKey: url)
        }
    }

    /// Perform an operation with guaranteed security-scoped access, then release.
    func withAccess<T>(to url: URL, perform operation: () throws -> T) rethrows -> T {
        let granted = requestAccess(to: url)
        defer { if granted { releaseAccess(to: url) } }
        return try operation()
    }

    func withAccess<T>(to url: URL, perform operation: () async throws -> T) async rethrows -> T {
        let granted = requestAccess(to: url)
        defer { if granted { releaseAccess(to: url) } }
        return try await operation()
    }
}
