import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @State private var selection: Mapping.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.config.mappings) { mapping in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mapping.repo.isEmpty ? "owner/repo" : mapping.repo).font(.body)
                        Text(mapping.path.isEmpty ? "no folder" : abbreviate(mapping.path))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(mapping.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItemGroup {
                    Button(action: addMapping) { Image(systemName: "plus") }.help("Add a repository")
                    Button(action: removeSelected) { Image(systemName: "minus") }
                        .disabled(selection == nil).help("Remove the selected repository")
                }
            }
        } detail: {
            if let index = store.config.mappings.firstIndex(where: { $0.id == selection }) {
                MappingEditor(mapping: $store.config.mappings[index], store: store)
                    .id(store.config.mappings[index].id)
            } else {
                ContentUnavailableView(
                    "No repository selected",
                    systemImage: "folder.badge.gearshape",
                    description: Text("Pick a row on the left, or add one with +. Each row maps a GitHub repo to a local folder and holds the shell run before and after the checkout.")
                )
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onChange(of: store.config) { _, _ in store.save() }
        .overlay(alignment: .bottom) {
            if let error = store.loadError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6)).padding()
            }
        }
    }

    private func addMapping() {
        let mapping = Mapping(repo: "", path: "", preCheckout: store.defaultPre(), postCheckout: "")
        store.config.mappings.append(mapping)
        selection = mapping.id
    }

    private func removeSelected() {
        store.config.mappings.removeAll { $0.id == selection }
        selection = nil
    }
}

struct MappingEditor: View {
    @Binding var mapping: Mapping
    let store: ConfigStore

    var body: some View {
        Form {
            Section("Repository") {
                TextField("GitHub repository (owner/repo)", text: $mapping.repo, prompt: Text("DiliTrust/module-mm"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Local folder", text: $mapping.path, prompt: Text("/Users/you/dev/module-mm"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseFolder)
                }
            }
            BlockSection(
                title: "Pre-checkout",
                subtitle: "Runs inside the folder after git fetch --all --prune and before the branch switch. Variables: MMCO_REPO, MMCO_PATH, MMCO_BRANCH, MMCO_DEFAULT_BRANCH. A non-zero exit aborts the run.",
                text: $mapping.preCheckout,
                reset: { mapping.preCheckout = store.defaultPre() }
            )
            BlockSection(
                title: "Post-checkout",
                subtitle: "Runs inside the folder after the branch switch, in the terminal chosen below, so its output stays visible. Same variables.",
                text: $mapping.postCheckout,
                reset: { mapping.postCheckout = store.defaultPost(for: mapping.path) }
            )
            Section {
                Toggle("Run it in a Terminal window instead of VS Code", isOn: $mapping.opensInTerminal)
            } header: {
                Text("After checkout")
            } footer: {
                Text(mapping.opensInTerminal
                     ? "A Terminal.app window opens in the folder and runs the block. The shell stays open afterwards."
                     : "VS Code opens a workspace on the folder (stored in its .git/mmco) whose folderOpen task runs the block in the integrated terminal. VS Code runs it only in a trusted workspace, and only once you have answered “Allow and Run” to its automatic-tasks prompt. ⇧⌘B reruns it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        if !mapping.path.isEmpty { panel.directoryURL = URL(fileURLWithPath: mapping.path) }
        if panel.runModal() == .OK, let url = panel.url {
            mapping.path = url.path
            if mapping.postCheckout.isEmpty { mapping.postCheckout = store.defaultPost(for: url.path) }
        }
    }
}

struct BlockSection: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    let reset: () -> Void

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button("Reset to default", action: reset).font(.caption)
            }
        } footer: {
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func abbreviate(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
