import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var importer: ImporterMode?

    enum ImporterMode {
        case folder, files
    }

    var body: some View {
        NavigationView {
            Form {
                folderSection
                filesSection
                optionsSection
                installSection
            }
            .navigationTitle("Bedrock Addons")
            .fileImporter(
                isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
                allowedContentTypes: importer == .folder ? [.folder] : [.item],
                allowsMultipleSelection: importer == .files
            ) { result in
                let mode = importer
                importer = nil
                guard case .success(let urls) = result else { return }
                if mode == .folder, let url = urls.first {
                    model.pickedFolder(url)
                } else {
                    model.addFiles(urls)
                }
            }
            .confirmationDialog("Several Minecraft folders found", isPresented: Binding(
                get: { !model.folderChoices.isEmpty }, set: { if !$0 { model.folderChoices = [] } }
            ), titleVisibility: .visible) {
                ForEach(model.folderChoices, id: \.self) { url in
                    Button(MinecraftFolder.label(for: url) + worldsHint(url)) { model.setFolder(url) }
                }
            }
            .alert("Bedrock Addons", isPresented: Binding(
                get: { model.message != nil }, set: { if !$0 { model.message = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.message ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    private func worldsHint(_ url: URL) -> String {
        let n = MinecraftFolder.stats(url).worlds
        return n > 0 ? String(localized: " — worlds: \(n)") : ""
    }

    // MARK: Sections

    private var folderSection: some View {
        Section {
            if let folder = model.folder {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Folder selected", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(MinecraftFolder.label(for: folder))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    Text("Resource packs: \(model.stats.resource) · behavior packs: \(model.stats.behavior) · worlds: \(model.stats.worlds)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Label("Minecraft folder not selected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            Button {
                model.autoDetect()
            } label: {
                Label("Find automatically", systemImage: "magnifyingglass")
            }
            Button {
                importer = .folder
            } label: {
                Label("Pick folder manually…", systemImage: "folder")
            }
        } header: {
            Text("Minecraft folder")
        } footer: {
            Text("Automatic search works when Minecraft and this app are in the same LiveContainer. Manually: Files → LiveContainer → Data → Application → Minecraft’s folder → Documents → games → com.mojang. Any folder above it works too, com.mojang is found inside.")
        }
    }

    private var filesSection: some View {
        Section {
            ForEach(model.files) { file in
                FileRow(file: file)
            }
            .onDelete { model.remove(at: $0) }
            Button {
                importer = .files
            } label: {
                Label("Add files…", systemImage: "plus.circle.fill")
            }
            .disabled(model.isInstalling)
            if model.files.contains(where: { if case .done = $0.status { return true } else { return false } }) {
                Button("Remove installed from the list") { model.clearFinished() }
                    .disabled(model.isInstalling)
            }
        } header: {
            Text("Addons")
        } footer: {
            Text(".mcpack, .mcaddon, .mcworld, .mctemplate or .zip, several at once. If a pack is already installed, the new version replaces it.")
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Enable resource packs right away", isOn: $model.enableGlobally)
            Toggle("Attach to worlds", isOn: $model.attachToWorlds)
            if model.attachToWorlds {
                if model.worlds.isEmpty {
                    Text("No worlds yet").foregroundColor(.secondary)
                }
                ForEach(model.worlds) { world in
                    Button {
                        if model.selectedWorlds.contains(world.id) {
                            model.selectedWorlds.remove(world.id)
                        } else {
                            model.selectedWorlds.insert(world.id)
                        }
                    } label: {
                        HStack {
                            Text(world.name).foregroundColor(.primary)
                            Spacer()
                            if model.selectedWorlds.contains(world.id) {
                                Image(systemName: "checkmark").foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("After installing")
        } footer: {
            Text("“Enable right away” adds resource packs to the game’s global resources. “Attach to worlds” adds resource and behavior packs to the checked worlds. Script packs may also need experimental features turned on in the world settings.")
        }
    }

    private var installSection: some View {
        Section {
            Button {
                model.install()
            } label: {
                HStack {
                    Spacer()
                    if model.isInstalling {
                        ProgressView().padding(.trailing, 6)
                        Text("Installing…")
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                        Text("Install")
                    }
                    Spacer()
                }
                .font(.headline)
            }
            .disabled(!model.canInstall)
        }
    }
}

struct FileRow: View {
    let file: QueuedFile

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(2)
                details
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        switch file.status {
        case .pending: Image(systemName: "shippingbox").foregroundColor(.secondary)
        case .working: ProgressView()
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
        }
    }

    @ViewBuilder private var details: some View {
        switch file.status {
        case .pending:
            Text("Waiting to install").font(.caption).foregroundColor(.secondary)
        case .working:
            Text("Unpacking…").font(.caption).foregroundColor(.secondary)
        case .done(let items):
            ForEach(items) { item in
                Group {
                    if item.replaced {
                        Text("Updated \(item.kind.title): \(item.name)")
                    } else {
                        Text("Installed \(item.kind.title): \(item.name)")
                    }
                }
                .font(.caption).foregroundColor(.secondary)
            }
        case .failed(let reason):
            Text(reason).font(.caption).foregroundColor(.red)
        }
    }
}
