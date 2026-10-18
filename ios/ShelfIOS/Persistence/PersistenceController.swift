import CoreData
import MachO

/// Manages the Core Data stack for the audiobook library.
/// Uses NSPersistentCloudKitContainer to automatically sync all entities to iCloud.
struct PersistenceController {
    static let shared = PersistenceController(inMemory: usesScreenshotStore)
    static var loadError: String?

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "AudiobookModel")

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        // Configure the persistent store for CloudKit sync
        if let description = container.persistentStoreDescriptions.first {
            // Enable lightweight migration
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)

            // Enable persistent history tracking (required for CloudKit sync)
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            // Set the CloudKit container identifier.
            // Only when the running build carries the iCloud entitlement: without it,
            // CloudKit traps during store setup and the app crashes at launch.
            if !inMemory {
                if Self.hasCloudKitEntitlement {
                    description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                        containerIdentifier: "iCloud.com.madebysan.ShelfIOS"
                    )
                } else {
                    print("CloudKit sync disabled: this build has no iCloud entitlement. Library data stays on device.")
                }
            }
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                let message = "Core Data store failed to load: \(error), \(error.userInfo)"
                print(message)
                PersistenceController.loadError = message
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Whether the running binary carries the CloudKit entitlement.
    ///
    /// Simulator builds made with code signing disabled (for example `CODE_SIGNING_ALLOWED=NO`
    /// on CI) ship without entitlements, and `NSPersistentCloudKitContainer` traps as soon as
    /// it touches CloudKit. Xcode embeds a simulator build's entitlements in the main
    /// executable's `__TEXT,__entitlements` section, so read it from there. On device, code
    /// signing enforces entitlements and an unentitled build cannot be installed.
    static var hasCloudKitEntitlement: Bool {
        #if targetEnvironment(simulator)
        guard let header = _dyld_get_image_header(0) else { return false }
        var size: UInt = 0
        let plistBytes = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
            getsectiondata($0, "__TEXT", "__entitlements", &size)
        }
        guard let plistBytes, size > 0 else { return false }
        let data = Data(bytes: plistBytes, count: Int(size))
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let services = plist["com.apple.developer.icloud-services"] as? [String] else {
            return false
        }
        return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
        #else
        return true
        #endif
    }

    /// The Debug-only App Store screenshot mode seeds demo books into a throwaway store,
    /// so it never reads or writes the real library.
    private static var usesScreenshotStore: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--app-store-screenshot")
        #else
        false
        #endif
    }

    /// Save the view context if there are changes
    func save() {
        let context = container.viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            print("Core Data save error: \(error.localizedDescription)")
        }
    }
}
