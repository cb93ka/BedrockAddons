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
            .navigationTitle("Аддоны Bedrock")
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
            .confirmationDialog("Нашлось несколько папок Minecraft", isPresented: Binding(
                get: { !model.folderChoices.isEmpty }, set: { if !$0 { model.folderChoices = [] } }
            ), titleVisibility: .visible) {
                ForEach(model.folderChoices, id: \.self) { url in
                    Button(MinecraftFolder.label(for: url) + worldsHint(url)) { model.setFolder(url) }
                }
            }
            .alert("Аддоны Bedrock", isPresented: Binding(
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
        return n > 0 ? " — миров: \(n)" : ""
    }

    // MARK: Sections

    private var folderSection: some View {
        Section {
            if let folder = model.folder {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Папка выбрана", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(MinecraftFolder.label(for: folder))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    Text("Ресурс-паков: \(model.stats.resource) · поведения: \(model.stats.behavior) · миров: \(model.stats.worlds)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Label("Папка Minecraft не выбрана", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            Button {
                model.autoDetect()
            } label: {
                Label("Найти автоматически", systemImage: "magnifyingglass")
            }
            Button {
                importer = .folder
            } label: {
                Label("Выбрать папку вручную…", systemImage: "folder")
            }
        } header: {
            Text("Папка Minecraft")
        } footer: {
            Text("Поиск работает, когда Minecraft и это приложение стоят в одном LiveContainer. Вручную: Файлы → LiveContainer → Data → Application → папка Minecraft → Documents → games → com.mojang. Подойдёт и любая папка выше: com.mojang найдётся сам.")
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
                Label("Добавить файлы…", systemImage: "plus.circle.fill")
            }
            .disabled(model.isInstalling)
            if model.files.contains(where: { if case .done = $0.status { return true } else { return false } }) {
                Button("Убрать установленные из списка") { model.clearFinished() }
                    .disabled(model.isInstalling)
            }
        } header: {
            Text("Аддоны")
        } footer: {
            Text(".mcpack, .mcaddon, .mcworld, .mctemplate или .zip, можно сразу несколько. Если пак уже стоит, его обновлённая версия заменит старую.")
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Включить ресурс-паки сразу", isOn: $model.enableGlobally)
            Toggle("Подключить к мирам", isOn: $model.attachToWorlds)
            if model.attachToWorlds {
                if model.worlds.isEmpty {
                    Text("Миров пока нет").foregroundColor(.secondary)
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
            Text("После установки")
        } footer: {
            Text("«Включить сразу» добавляет ресурс-паки в глобальные ресурсы игры. «Подключить к мирам» добавляет ресурс-паки и паки поведения в отмеченные миры. Для паков со скриптами в настройках мира может понадобиться включить экспериментальные функции.")
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
                        Text("Устанавливаю…")
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                        Text("Установить")
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
            Text("Ждёт установки").font(.caption).foregroundColor(.secondary)
        case .working:
            Text("Распаковываю…").font(.caption).foregroundColor(.secondary)
        case .done(let items):
            ForEach(items) { item in
                Text("\(item.replaced ? "Обновлён" : "Установлен") \(item.kind.title): \(item.name)")
                    .font(.caption).foregroundColor(.secondary)
            }
        case .failed(let reason):
            Text(reason).font(.caption).foregroundColor(.red)
        }
    }
}
