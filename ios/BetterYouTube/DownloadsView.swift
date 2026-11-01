import SwiftUI

struct DownloadsView: View {
    @ObservedObject var engine: YouTubeEngine
    @ObservedObject private var library = OfflineLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var channel = ""
    @State private var adding = false
    @State private var removeID: String?
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
                Section("Downloads") {
                    if library.records.isEmpty { Text("Tap Download on any video. Finished downloads play here without an internet connection.").foregroundStyle(.secondary).font(.subheadline) }
                    ForEach(library.records) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            HStack {
                                Text(status(record)).font(.caption).foregroundStyle(record.state == "ready" ? .green : .secondary)
                                Spacer()
                                if record.state == "ready" { Button { engine.play(record.video); dismiss() } label: { Image(systemName: "play.fill") }.accessibilityLabel("Play offline \(record.video.title)").accessibilityIdentifier("offline-\(record.id)") }
                                if ["failed", "expired"].contains(record.state) { Button("Retry") { library.download(record.video) }.font(.caption) }
                                Button { removeID = record.id } label: { Image(systemName: "trash") }.foregroundStyle(.secondary).accessibilityLabel("Remove download")
                            }
                            if record.state == "downloading" { ProgressView(value: record.progress) }
                            if let error = record.error { Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(4) }
                        }.padding(.vertical, 5)
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
            .navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await library.sync() }
            .confirmationDialog("Remove this download from your iPhone?", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } }), titleVisibility: .visible) {
                Button("Remove download", role: .destructive) { if let id = removeID { library.remove(id) }; removeID = nil }
            }
        }
    }
    private func status(_ record: DownloadRecord) -> String {
        switch record.state {
        case "ready": return "Available offline · " + ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file)
        case "requesting": return "Requesting download…"
        case "queued": return "Queued on companion"
        case "preparing": return "Preparing video on companion"
        case "waiting": return "Waiting to transfer"
        case "downloading": return "Downloading · \(Int(record.progress * 100))%"
        case "expired": return "Server copy expired · tap Retry"
        default: return "Download needs attention"
        }
    }
}
