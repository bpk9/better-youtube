import Foundation
import SwiftUI
import CryptoKit
import Security
import BackgroundTasks

struct ChannelRule: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var enabled: Bool = false
    var error: String? = nil
}

struct DownloadRecord: Codable, Identifiable {
    var id: String { video.id }
    var video: Video
    var state: String
    var progress: Double = 0
    var bytes: Int64 = 0
    var error: String?
    var automatic = false
}

struct ServerJob: Decodable {
    let video: Video
    let state: String
    let bytes: Int64
    let error: String?
    let automatic: Bool
}

struct CompanionConnection {
    let url: URL
    let token: String
    let certificateSHA256: String
    static func load() -> CompanionConnection? {
        guard let path = Bundle.main.url(forResource: "Connection", withExtension: "plist"),
              let data = try? Data(contentsOf: path),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let raw = values["ServerURL"], let url = URL(string: raw), url.scheme == "https",
              let token = values["ServerToken"], token.count >= 32,
              let pin = values["CertificateSHA256"], pin.count == 64 else { return nil }
        // The build bootstrap is private; subsequent access uses the device Keychain.
        if SecureStore.read("companion-token") != token { SecureStore.save(token, key: "companion-token") }
        return CompanionConnection(url: url, token: SecureStore.read("companion-token") ?? token, certificateSHA256: pin.lowercased())
    }
}

enum SecureStore {
    static func save(_ value: String, key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "BetterYouTube", kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
    static func read(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "BetterYouTube", kSecAttrAccount as String: key, kSecReturnData as String: true]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func remove(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "BetterYouTube", kSecAttrAccount as String: key] as CFDictionary)
    }
}

class PinnedSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let connection: CompanionConnection?
    init(_ connection: CompanionConnection?) { self.connection = connection }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else { completionHandler(.performDefaultHandling, nil); return }
        guard let connection, challenge.protectionSpace.host == connection.url.host,
              challenge.protectionSpace.port == (connection.url.port ?? 443),
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let hash = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == connection.certificateSHA256 else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

@MainActor final class OfflineLibrary: NSObject, ObservableObject {
    static let shared = OfflineLibrary()
    static let refreshID = (Bundle.main.bundleIdentifier ?? "com.example.betteryoutube") + ".refresh"
    nonisolated static let directory: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values)
        return root
    }()
    @Published var records: [DownloadRecord] = []
    @Published var channels: [ChannelRule] = []
    @Published var error: String?
    @Published var connected = false
    @Published var syncing = false
    @Published var wifiOnly = UserDefaults.standard.object(forKey: "downloadWiFiOnly") as? Bool ?? true
    @Published var lastSync: Date?
    let connection: CompanionConnection?
    var isConfigured: Bool { connection != nil }
    var backgroundCompletion: (() -> Void)?
    var storageBytes: Int64 { records.filter { $0.state == "ready" }.reduce(0) { $0 + $1.bytes } }
    let storageLimit: Int64 = 2 * 1024 * 1024 * 1024
    private let delegate: TransferDelegate
    private let apiDelegate: PinnedSessionDelegate
    private var api: URLSession!
    private var transfers: URLSession!
    private var activeIDs = Set<String>()
    private var ignored: Set<String> = []
    private var polling: Task<Void, Never>?
    private var manifest: URL { Self.directory.appendingPathComponent("downloads.json") }

    override init() {
        let config = CompanionConnection.load(); connection = config
        delegate = TransferDelegate(config)
        apiDelegate = PinnedSessionDelegate(config)
        super.init()
        delegate.owner = self
        if let data = try? Data(contentsOf: manifest), let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) { records = saved }
        ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredDownloads") ?? [])
        if let data = UserDefaults.standard.data(forKey: "channelRules"), let rules = try? JSONDecoder().decode([ChannelRule].self, from: data) { channels = rules }
        let apiConfig = URLSessionConfiguration.ephemeral
        apiConfig.timeoutIntervalForRequest = 25
        api = URLSession(configuration: apiConfig, delegate: apiDelegate, delegateQueue: nil)
        let transferConfig = URLSessionConfiguration.background(withIdentifier: (Bundle.main.bundleIdentifier ?? "com.example.betteryoutube") + ".offline")
        transferConfig.sessionSendsLaunchEvents = true
        transferConfig.isDiscretionary = false
        transferConfig.waitsForConnectivity = true
        transferConfig.httpMaximumConnectionsPerHost = 1
        transfers = URLSession(configuration: transferConfig, delegate: delegate, delegateQueue: nil)
        for index in records.indices where records[index].state == "ready" && !FileManager.default.fileExists(atPath: Self.file(records[index].id).path) { records[index].state = "failed"; records[index].error = "The local file is missing. Download it again." }
        Task {
            let tasks = await transfers.allTasks
            activeIDs = Set(tasks.compactMap(\.taskDescription))
            for i in records.indices where records[i].state == "downloading" && !activeIDs.contains(records[i].id) {
                records[i].state = FileManager.default.fileExists(atPath: Self.file(records[i].id).path) ? "ready" : "waiting"
            }
            persist()
        }
    }

    nonisolated static func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".mp4") }
    func localURL(_ id: String) -> URL? { records.contains(where: { $0.id == id && $0.state == "ready" }) && FileManager.default.fileExists(atPath: Self.file(id).path) ? Self.file(id) : nil }
    func record(_ id: String) -> DownloadRecord? { records.first { $0.id == id } }
    func persist() { if let data = try? JSONEncoder().encode(records) { try? data.write(to: manifest, options: .atomic) } }

    func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let connection else { throw URLError(.cannotFindHost, userInfo: [NSLocalizedDescriptionKey: "The companion server hasn’t been connected yet."]) }
        var request = URLRequest(url: connection.url.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + connection.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    func call(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let (data, response) = try await api.data(for: request(path, method: method, body: body))
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw NSError(domain: "Companion", code: 1, userInfo: [NSLocalizedDescriptionKey: detail ?? "The companion could not complete that request."])
        }
        return data
    }
    func download(_ video: Video) {
        guard localURL(video.id) == nil else { return }
        ignored.remove(video.id); UserDefaults.standard.set(Array(ignored), forKey: "ignoredDownloads")
        if let i = records.firstIndex(where: { $0.id == video.id }) { records[i].state = "requesting"; records[i].error = nil }
        else { records.insert(DownloadRecord(video: video, state: "requesting"), at: 0) }
        persist()
        Task {
            do {
                _ = try await call("v1/jobs", method: "POST", body: JSONEncoder().encode(video))
                await sync()
            } catch { fail(video.id, error.localizedDescription) }
        }
    }
    func sync() async {
        guard isConfigured, !syncing else { return }
        syncing = true; defer { syncing = false }
        do {
            let jobs = try JSONDecoder().decode([ServerJob].self, from: await call("v1/jobs"))
            let rules = try JSONDecoder().decode([ChannelRule].self, from: await call("v1/channels"))
            channels = rules; UserDefaults.standard.set(try? JSONEncoder().encode(channels), forKey: "channelRules")
            connected = true; error = nil; lastSync = Date()
            for job in jobs where !ignored.contains(job.video.id) {
                if record(job.video.id) == nil {
                    guard job.automatic else { continue }
                    records.insert(DownloadRecord(video: job.video, state: "waiting", automatic: true), at: 0)
                }
                guard let i = records.firstIndex(where: { $0.id == job.video.id }), records[i].state != "ready", !activeIDs.contains(job.video.id) else { continue }
                records[i].state = job.state == "ready" ? "waiting" : job.state
                records[i].error = job.error
                if job.state == "ready" { beginTransfer(job) }
            }
            persist()
        } catch {
            connected = false
            self.error = "Can’t reach the companion. Downloads already on this iPhone still work. \(error.localizedDescription)"
        }
    }
    private func beginTransfer(_ job: ServerJob) {
        // Reserve space for both existing files and in-flight files, across every sync.
        let reserved = records.filter { activeIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
        guard job.bytes > 0, job.bytes <= 500 * 1024 * 1024, storageBytes + reserved + job.bytes <= storageLimit else { fail(job.video.id, "The 2 GB offline limit is full, or this video is too large. Remove a download and retry."); return }
        let available = (try? Self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        guard available > job.bytes + 256 * 1024 * 1024 else { fail(job.video.id, "This iPhone needs more free storage."); return }
        do {
            var req = try request("v1/media/" + job.video.id)
            req.allowsCellularAccess = !wifiOnly
            req.allowsExpensiveNetworkAccess = !wifiOnly
            req.allowsConstrainedNetworkAccess = !wifiOnly
            let task = transfers.downloadTask(with: req); task.taskDescription = job.video.id
            activeIDs.insert(job.video.id)
            if let i = records.firstIndex(where: { $0.id == job.video.id }) { records[i].state = "downloading"; records[i].bytes = job.bytes; records[i].error = nil }
            persist(); task.resume()
        } catch { fail(job.video.id, error.localizedDescription) }
    }
    func progress(_ id: String, written: Int64, expected: Int64) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].progress = expected > 0 ? min(1, Double(written) / Double(expected)) : 0
    }
    func finished(_ id: String, size: Int64) {
        activeIDs.remove(id)
        guard !ignored.contains(id), let i = records.firstIndex(where: { $0.id == id }) else { try? FileManager.default.removeItem(at: Self.file(id)); return }
        records[i].state = "ready"; records[i].progress = 1; records[i].bytes = size; records[i].error = nil; persist()
    }
    func fail(_ id: String, _ reason: String) {
        activeIDs.remove(id)
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].state = "failed"; records[i].error = reason; persist()
    }
    func remove(_ id: String) {
        ignored.insert(id); UserDefaults.standard.set(Array(ignored), forKey: "ignoredDownloads")
        records.removeAll { $0.id == id }; persist()
        try? FileManager.default.removeItem(at: Self.file(id))
        Task { for task in await transfers.allTasks where task.taskDescription == id { task.cancel() }; activeIDs.remove(id) }
    }
    func setRule(_ rule: ChannelRule) async {
        do {
            _ = try await call("v1/channels/" + rule.id, method: "PUT", body: JSONEncoder().encode(rule))
            await sync()
        } catch { self.error = error.localizedDescription }
    }
    func addChannel(_ text: String) async {
        do {
            let data = try await call("v1/resolve-channel", method: "POST", body: JSONSerialization.data(withJSONObject: ["url": text]))
            var rule = try JSONDecoder().decode(ChannelRule.self, from: data); rule.enabled = true
            await setRule(rule)
        } catch { self.error = error.localizedDescription }
    }
    func importChannels(_ rules: [ChannelRule]) async {
        for rule in rules where !channels.contains(where: { $0.id == rule.id }) {
            do { _ = try await call("v1/channels/" + rule.id, method: "PUT", body: JSONEncoder().encode(rule)) }
            catch { self.error = error.localizedDescription; break }
        }
        await sync()
    }
    func foreground(_ active: Bool) {
        polling?.cancel()
        if active {
            polling = Task {
                while !Task.isCancelled {
                    await sync()
                    try? await Task.sleep(for: .seconds(12))
                }
            }
        } else { scheduleRefresh() }
    }
    func scheduleRefresh() {
        guard channels.contains(where: \.enabled) || records.contains(where: { !["ready", "failed", "expired"].contains($0.state) }) else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

final class TransferDelegate: PinnedSessionDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    @MainActor weak var owner: OfflineLibrary?
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in owner?.progress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, id.range(of: "^[a-zA-Z0-9_-]{11}$", options: .regularExpression) != nil else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200, response.mimeType == "video/mp4" else { throw URLError(.badServerResponse) }
            let size = (try location.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size > 1024, size <= 500 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            let destination = OfflineLibrary.file(id)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            // Move synchronously: URLSession deletes this temporary file when the delegate returns.
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in owner?.finished(id, size: Int64(size)) }
        } catch { Task { @MainActor in owner?.fail(id, error.localizedDescription) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        Task { @MainActor in owner?.fail(id, error.localizedDescription) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in owner?.persist(); owner?.backgroundCompletion?(); owner?.backgroundCompletion = nil }
    }
}

final class ApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: OfflineLibrary.refreshID, using: nil) { task in
            Task { @MainActor in
                let work = Task { await OfflineLibrary.shared.sync(); OfflineLibrary.shared.scheduleRefresh(); task.setTaskCompleted(success: OfflineLibrary.shared.connected) }
                task.expirationHandler = { work.cancel() }
            }
        }
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        OfflineLibrary.shared.backgroundCompletion = completionHandler
    }
}
