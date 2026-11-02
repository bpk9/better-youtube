import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var library = OfflineLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var channel = ""
    @State private var adding = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack { Label("Offline library", systemImage: "arrow.down.circle.fill").font(.headline); Spacer(); if library.syncing { ProgressView() } }
                    Text("\(ByteCountFormatter.string(fromByteCount: library.storageBytes, countStyle: .file)) of 2 GB on this iPhone").font(.caption).foregroundStyle(.secondary)
                    Toggle("Download on Wi-Fi only", isOn: $library.wifiOnly).onChange(of: library.wifiOnly) { _, value in UserDefaults.standard.set(value, forKey: "downloadWiFiOnly") }
                    Text("Changes apply to newly started transfers. Downloads already in progress keep their original network preference.").font(.caption2).foregroundStyle(.secondary)
                    Button("Sync downloads now") { Task { await library.sync() } }.disabled(library.syncing || !library.isConfigured)
                }
                if !library.isConfigured {
                    Section { Label("Companion setup needed", systemImage: "server.rack"); Text("The download service is ready to install, but this build isn’t paired with your server yet. Search and streaming still work.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Section {
                        Label(library.connected ? "Companion connected" : "Companion offline", systemImage: library.connected ? "checkmark.shield" : "wifi.slash")
                        if let error = library.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                }
                Section {
                    Text("New uploads from these channels will be prepared on your server. Nothing from a channel’s old backlog is downloaded automatically.").font(.caption).foregroundStyle(.secondary)
                    ForEach(library.channels) { rule in
                        VStack(alignment: .leading) {
                            Toggle(rule.title, isOn: Binding(get: { rule.enabled }, set: { value in var updated = rule; updated.enabled = value; Task { await library.setRule(updated) } }))
                            if let error = rule.error { Text(error).font(.caption2).foregroundStyle(.orange) }
                        }
                    }
                    HStack {
                        TextField("Channel link or @handle", text: $channel).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("channelInput")
                        Button {
                            adding = true
                            Task { await library.addChannel(channel); adding = false; if library.error == nil { channel = "" } }
                        } label: { if adding { ProgressView() } else { Image(systemName: "plus.circle.fill") } }.disabled(adding || channel.isEmpty || !library.isConfigured).accessibilityLabel("Add automatic download channel")
                    }
                } header: { Text("Automatic downloads") } footer: { Text("Your server checks every 30 minutes. iOS decides when to wake this app to fetch ready files; opening the app syncs immediately. Force-quitting can prevent background transfers until you open it again. The companion keeps a 5 GB, seven-day cache and prepares one video at a time.") }
            }
            .navigationTitle("Download settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await library.sync() }

        }
    }
}

struct DownloadLibraryView: View {
    @ObservedObject var engine: YouTubeEngine
    var openSettings: () -> Void
    @ObservedObject private var library = OfflineLibrary.shared
    @State private var removing: DownloadRecord?
    private var ready: [DownloadRecord] { library.records.filter { $0.state == "ready" } }
    private var pending: [DownloadRecord] { library.records.filter { $0.state != "ready" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(ready.count) ready to watch", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("\(ByteCountFormatter.string(fromByteCount: library.storageBytes, countStyle: .file)) of 2 GB used")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: openSettings) { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(accent).accessibilityLabel("Download settings").accessibilityIdentifier("openDownloads")
            }
            if !library.isConfigured {
                notice("Downloads need setup", message: "Connect your companion in download settings to start downloading.", icon: "server.rack")
            } else if let error = library.error {
                notice("Couldn’t refresh downloads", message: error, icon: "wifi.slash")
            } else if library.syncing {
                HStack(spacing: 10) { ProgressView(); Text("Checking downloads…").font(.caption).foregroundStyle(.secondary) }
                    .accessibilityIdentifier("downloadsLoading")
            } else if !library.connected {
                notice("Companion offline", message: "Videos already downloaded are ready to play. Pull down to try connecting again.", icon: "wifi.slash")
            }
            if library.records.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 34, weight: .light)).foregroundStyle(accent)
                    Text("Take a few favorites with you").font(.title3.bold())
                    Text("Choose Download from a video’s menu. You’ll see its progress here, then watch it anytime, even offline.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    .background(panel, in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityIdentifier("downloadsEmpty")
            }
            if !pending.isEmpty {
                Text("In progress & needs attention").font(.headline)
                ForEach(pending) { record in downloadCard(record) }
            }
            if !ready.isEmpty {
                Text("Available offline").font(.headline)
                LazyVStack(spacing: 18) { ForEach(ready) { record in downloadCard(record) } }
            }
        }
        .task { await library.sync() }
        .confirmationDialog("Remove this download from your iPhone?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { if let record = removing { library.remove(record.id) }; removing = nil }
        }
    }

    private func notice(_ title: String, message: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private func downloadCard(_ record: DownloadRecord) -> some View {
        let completed = record.state == "ready"
        let needsRetry = ["failed", "expired"].contains(record.state)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button { engine.play(record.video) } label: {
                    Thumbnail(video: record.video)
                        .frame(width: 112, height: 72).overlay {
                            if completed { Image(systemName: "play.fill").font(.title3).foregroundStyle(.white).padding(10).background(.black.opacity(0.6), in: Circle()) }
                        }.clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(!completed)
                    .accessibilityLabel("Play offline \(record.video.title)").accessibilityIdentifier(completed ? "offline-\(record.id)" : "download-thumbnail-\(record.id)")
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if !record.video.channel.isEmpty { Text(record.video.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if record.automatic { Text("Automatic download").font(.caption2).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    if needsRetry { Button("Retry download", systemImage: "arrow.clockwise") { library.download(record.video) } }
                    Button(completed || needsRetry ? "Remove download" : "Cancel download", systemImage: "trash", role: .destructive) { removing = record }
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44) }
                    .accessibilityLabel("Download options for \(record.video.title)")
            }
            HStack(spacing: 8) {
                if completed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if needsRetry {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                } else { ProgressView().controlSize(.small) }
                Text(record.statusText).font(.caption.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                if needsRetry { Button("Retry") { library.download(record.video) }.font(.caption.bold()).buttonStyle(.bordered) }
            }
            if record.state == "downloading" {
                ProgressView(value: record.progress).tint(accent)
                    .accessibilityLabel("Download progress").accessibilityValue("\(Int(record.progress * 100)) percent")
            }
            if let error = record.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 18))
    }

}

extension DownloadRecord {
    var statusText: String {
        switch state {
        case "ready": return "Available offline · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case "requesting": return "Requesting download…"
        case "queued": return "Queued · waiting to prepare"
        case "preparing": return "Preparing video…"
        case "waiting": return "Waiting to transfer…"
        case "waitingForNetwork": return "Waiting for a connection…"
        case "downloading": return progress > 0 ? "Downloading · \(Int(progress * 100))%" : "Starting download…"
        case "expired": return "Download expired"
        default: return "Download failed"
        }
    }
}
