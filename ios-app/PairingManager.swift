import Foundation

/// Drives the "Pairing" tab — the standalone equivalent of iLoader's "Manage
/// Pairing files". It can:
///   • generate (extract) the device pairing file via the RPPairing host,
///   • export it (share sheet / Save to Files), and
///   • write it into a chosen installed app (SideStore, StikDebug, Feather, …)
///     over the loopback tunnel, the same way the install flow seeds SideStore.
///
/// All device work is delegated to the shared `Engine` (it owns the connection
/// and serializes it); this type holds only the tab's own UI state, mirroring
/// `CertManager` / `DownloadsManager`.
@MainActor
final class PairingManager: ObservableObject {

    // Pairing file on disk (drives the status line + the Export button).
    @Published private(set) var pairingFileExists = false
    @Published private(set) var pairingFileSize = 0
    @Published private(set) var pairingFileDate: Date?

    // In-flight flags.
    @Published private(set) var isGenerating = false
    @Published private(set) var isScanning = false
    /// `id` (bundle id) of the target currently being written, if any.
    @Published private(set) var installingTargetID: String?

    // Results.
    @Published private(set) var targets: [InstalledPairingTarget] = []
    /// True once a scan has completed (drives the "no apps found" empty state).
    @Published private(set) var hasScanned = false
    @Published var lastError: String?
    @Published var lastSuccess: String?

    private var engine: Engine { Engine.shared }

    /// Any device/file operation in flight — used to disable the controls.
    var isBusy: Bool { isGenerating || isScanning || installingTargetID != nil }

    /// The pairing file to hand to a share sheet, when one exists on disk.
    var exportURL: URL? {
        guard pairingFileExists else { return nil }
        return URL(fileURLWithPath: PairingController.pairingFilePath())
    }

    // MARK: - Actions

    /// Re-stat the pairing file. Cheap; safe to call each time the tab appears.
    func refresh() {
        let path = PairingController.pairingFilePath()
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        pairingFileExists = FileManager.default.fileExists(atPath: path) && size > 0
        pairingFileSize = size
        pairingFileDate = attrs?[.modificationDate] as? Date
    }

    /// Install an RPPairing plist supplied through Files. This is the pairing
    /// entry point on iOS 17.4-26, where the device cannot initiate Pairable
    /// Host pairing itself. The source is validated as a non-empty plist and
    /// copied atomically into the app's private store.
    func importPairingFile(from source: URL) {
        guard !isBusy else { return }
        lastError = nil
        lastSuccess = nil

        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: source)
            guard !data.isEmpty else {
                throw ImportError.empty
            }
            guard (try PropertyListSerialization.propertyList(from: data, options: [], format: nil)) is [String: Any] else {
                throw ImportError.invalidPlist
            }

            let destination = URL(fileURLWithPath: PairingController.pairingFilePath())
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".pairing-import-\(UUID().uuidString).plist")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }

            engine.pairingFilePath = destination.path
            engine.connection.disconnect()
            targets = []
            hasScanned = false
            lastSuccess = L("Pairing file imported. Turn on the loopback VPN, then scan or install.")
        } catch {
            lastError = message(error)
        }
        refresh()
    }

    /// Run the RPPairing host to extract a fresh pairing file. Surfaces the PIN
    /// through `Engine.pairingPIN` (shown by the tab) while the user pairs in
    /// Settings. A re-pair invalidates any open device link, so drop it.
    func generate() {
        guard !isBusy else { return }
        lastError = nil
        lastSuccess = nil
        isGenerating = true
        Task {
            do {
                _ = try await PairingController.shared.startAndWait()
                engine.connection.disconnect()
                targets = []
                hasScanned = false
                lastSuccess = L("Pairing file ready. You can export it or install it into an app below.")
            } catch is CancellationError {
                // User backed out — no error banner.
            } catch {
                lastError = message(error)
            }
            refresh()
            isGenerating = false
        }
    }

    /// Connect over the loopback tunnel and list the supported apps on device.
    func scan() {
        guard !isBusy else { return }
        lastError = nil
        isScanning = true
        Task {
            do {
                targets = try await engine.installedPairingTargets()
                hasScanned = true
            } catch {
                lastError = message(error)
            }
            isScanning = false
        }
    }

    /// Write the pairing file into one installed target app.
    func install(into target: InstalledPairingTarget) {
        guard !isBusy else { return }
        lastError = nil
        lastSuccess = nil
        installingTargetID = target.id
        Task {
            do {
                try await engine.installPairing(into: target)
                lastSuccess = L("Pairing file installed into %@.", target.name)
            } catch {
                lastError = message(error)
            }
            installingTargetID = nil
        }
    }

    // MARK: - Helpers

    /// Human-readable pairing-file size, e.g. "2 KB".
    var pairingFileSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(pairingFileSize), countStyle: .file)
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private enum ImportError: LocalizedError {
        case empty
        case invalidPlist

        var errorDescription: String? {
            switch self {
            case .empty: return L("The selected pairing file is empty.")
            case .invalidPlist: return L("The selected file is not a valid RPPairing property list.")
            }
        }
    }
}
