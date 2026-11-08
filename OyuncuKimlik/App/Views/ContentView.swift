import AppKit
import SwiftUI

/// Tek pencere arayüzü (§8).
struct ContentView: View {
    @Bindable var model: AppModel

    @State private var sheet: SheetMode?
    @State private var copiedKey: String?
    @State private var showsSuggestions = false
    @State private var showsNewName = false
    @State private var newNameText = ""
    @State private var showsManualModel = false
    @State private var manualModelText = ""

    enum SheetMode: Identifiable {
        case add
        case edit(UUID)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let id): return id.uuidString
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    profileCard
                    networkCard
                    serversCard
                    reasonsSection
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task {
            if !AppModel.isRunningTests { model.refresh() }
        }
        .sheet(item: $sheet) { mode in
            sheetView(mode)
        }
        .alert("Yeni ad", isPresented: $showsNewName) {
            TextField("Kullanıcı adı", text: $newNameText)
            Button("Tamam") { model.nameDraft = newNameText }
            Button("Vazgeç", role: .cancel) {}
        }
        .alert("Model adı", isPresented: $showsManualModel) {
            TextField("Oyuncu modeli", text: $manualModelText)
            Button("Tamam") { model.modelDraft = manualModelText }
            Button("Vazgeç", role: .cancel) {}
        }
        .alert("Kayıt yazılamadı", isPresented: Binding(
            get: { model.saveErrorMessage != nil },
            set: { if !$0 { model.saveErrorMessage = nil } }
        )) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(model.saveErrorMessage ?? "")
        }
    }

    // MARK: Üst bar

    private var topBar: some View {
        HStack(spacing: 12) {
            if let report = model.report {
                let statusLabel = Label {
                    Text(report.overall.label).font(.title3.bold())
                } icon: {
                    Image(systemName: report.overall.symbolName)
                        .foregroundStyle(report.overall.color)
                        .font(.title2)
                }
                if report.reasons.isEmpty {
                    statusLabel
                        .accessibilityElement(children: .combine)
                } else {
                    // §14.2/2: etikete tıklayınca "Ne yapmalı?" popover'ı.
                    Button {
                        showsSuggestions = true
                    } label: {
                        statusLabel
                    }
                    .buttonStyle(.plain)
                    .help("Ne yapmalı?")
                    .accessibilityLabel(report.overall.label)
                    .accessibilityHint("Ne yapmalı?")
                    .popover(isPresented: $showsSuggestions, arrowEdge: .bottom) {
                        SuggestionsPopover(reasons: report.reasons)
                    }
                }
            } else {
                Text(model.isRefreshing ? "Kontrol ediliyor…" : "Henüz kontrol edilmedi")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("Son kontrol: \(TimeText.format(model.lastChecked))")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            if model.hasUnsavedChanges {
                Text("Kaydedilmedi")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }

            Button {
                model.refresh()
            } label: {
                HStack(spacing: 6) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Yenile")
                }
            }
            .disabled(model.isRefreshing)
            .help("Yenile (⌘R)")

            Button {
                model.save()
            } label: {
                Label("Kaydet", systemImage: "square.and.arrow.down")
            }
            .help("Kaydet (⌘S)")
        }
    }

    // MARK: Profil kartı

    private var profileCard: some View {
        Card(title: "Profil") {
            if model.isGameRunning {
                // §15.7 oyun açık uyarı bandı
                Label(EditMessage.gameRunning.text, systemImage: StatusLevel.orange.symbolName)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.15)))
            }
            FieldRow(title: "Kullanıcı adı") {
                Menu {
                    ForEach(model.nameOptions, id: \.self) { option in
                        Button(option) { model.nameDraft = option }
                    }
                    Divider()
                    Button("Yeni ad…") {
                        newNameText = model.nameDraft
                        showsNewName = true
                    }
                } label: {
                    Text(model.nameDraft.isEmpty ? "—" : model.nameDraft)
                }
                .fixedSize()
                .accessibilityLabel("Kullanıcı adı: \(model.nameDraft)")
                sourceNote(model.configSources.name)
            }
            if let error = model.nameError { fieldError(error) }
            FieldRow(title: "Oyuncu modeli") {
                ModelPopUpButton(
                    title: model.modelDraft,
                    options: model.modelOptions,
                    thumbnails: Dictionary(uniqueKeysWithValues: model.modelOptions.map {
                        ($0.value, ModelPreviewStyle.thumbnail(model.preview(for: $0.value)))
                    }),
                    allowsManualEntry: model.allowsManualModelEntry,
                    onSelect: { model.modelDraft = $0 },
                    onManualEntry: {
                        manualModelText = model.modelDraft
                        showsManualModel = true
                    })
                .fixedSize()
                sourceNote(model.configSources.model)
            }
            if let error = model.modelError { fieldError(error) }
            FieldRow(title: "") {
                // §16.3 seçili model önizlemesi; kaynak dosya yolu ipucunda.
                let preview = model.preview(for: model.modelDraft)
                    ?? (model.isLoadingPreviews ? nil : ModelPreview.placeholder)
                HStack(spacing: 10) {
                    ModelPreviewView(preview: preview, modelName: model.modelDraft)
                    Text(model.modelDraft.isEmpty ? "—" : model.modelDraft)
                        .foregroundStyle(.secondary)
                }
                .help(preview?.image?.url.path ?? "")
            }
            HStack(spacing: 12) {
                Spacer().frame(width: 130)
                Button {
                    model.apply()
                } label: {
                    HStack(spacing: 6) {
                        if model.isApplying { ProgressView().controlSize(.small) }
                        Text("Uygula")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canApply)
                .help("Uygula (⌘⏎)")
                switch model.applyStatus {
                case .success(let text)?:
                    Text(text).font(.callout).foregroundStyle(.secondary)
                case .failure(let error)?:
                    Text(error.text).font(.callout).foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
                Spacer(minLength: 0)
            }
            FieldRow(title: "Ham kimlik") {
                Text(identityValue?.rawIDHex ?? "—")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            FieldRow(title: "Kimlik kaynağı") {
                let path = identityValue?.source.url.path
                Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "—")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path ?? "")
            }
            FieldRow(title: "Gamedir") {
                if gamedirOptions.isEmpty {
                    Text("Gamedir bulunamadı").foregroundStyle(.secondary)
                } else {
                    Picker("Gamedir", selection: Binding(
                        get: { model.selectedGamedir ?? "" },
                        set: { model.selectGamedir($0) }
                    )) {
                        ForEach(gamedirOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            FieldRow(title: "Veri kökü") {
                Text((model.dataRoot.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.dataRoot.path)
                Button("Klasör Seç…", action: chooseDataRoot)
            }
        }
    }

    @ViewBuilder
    private func sourceNote(_ source: ConfigFileKind?) -> some View {
        if let source {
            Text(source.note)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fieldError(_ error: EditMessage) -> some View {
        Text(error.text)
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.leading, 142)
    }

    private var identityValue: Identity? {
        guard case .success(let identity)? = model.identity else { return nil }
        return identity
    }

    private var gamedirOptions: [String] {
        var options = model.gamedirs
        if let selected = model.selectedGamedir, !options.contains(selected) { options.append(selected) }
        return options
    }

    private func chooseDataRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = model.dataRoot
        panel.prompt = "Seç"
        panel.message = "Oyun veri kökü klasörünü seçin"
        if panel.runModal() == .OK, let url = panel.url {
            model.setDataRoot(url)
        }
    }

    // MARK: Ağ kartı

    private var networkCard: some View {
        Card(title: "Ağ") {
            FieldRow(title: "Genel IP") {
                if let ip = model.publicIP {
                    Text(ip)
                        .font(.title2.monospaced())
                        .textSelection(.enabled)
                    copyButton(text: ip, key: "publicIP")
                } else {
                    Text(model.lastChecked == nil ? "—" : "Alınamadı")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            FieldRow(title: "Yerel IP'ler") {
                if model.lanAddresses.isEmpty {
                    Text(model.lastChecked == nil ? "—" : MessageCode.lanIPMissing.text)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.lanAddresses, id: \.display) { address in
                            Text(address.display)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func copyButton(text: String, key: String) -> some View {
        Button {
            copy(text, key: key)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Kopyala")
        .accessibilityLabel("Kopyala")
        if copiedKey == key {
            Text("Kopyalandı").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String, key: String) {
        Pasteboard.copy(text)
        copiedKey = key
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedKey == key { copiedKey = nil }
        }
    }

    // MARK: Sunucular

    private var serversCard: some View {
        Card(title: "Sunucular") {
            if model.servers.isEmpty {
                VStack(spacing: 8) {
                    Text("Henüz sunucu eklenmedi").foregroundStyle(.secondary)
                    addServerButton
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.servers) { entry in
                        ServerRowView(entry: entry,
                                      status: model.rowStatus(entry.id),
                                      copied: copiedKey == entry.id.uuidString,
                                      onCopy: { copy($0, key: entry.id.uuidString) },
                                      onEdit: { sheet = .edit(entry.id) },
                                      onDelete: { model.deleteServer(id: entry.id) })
                        if entry.id != model.servers.last?.id { Divider() }
                    }
                }
                addServerButton
            }
        }
    }

    private var addServerButton: some View {
        Button {
            sheet = .add
        } label: {
            Label("Sunucu Ekle", systemImage: "plus")
        }
    }

    @ViewBuilder
    private func sheetView(_ mode: SheetMode) -> some View {
        switch mode {
        case .add:
            ServerFormSheet(title: "Sunucu Ekle", confirmTitle: "Ekle",
                            onConfirm: { draft in
                                model.addServer(draft)
                                sheet = nil
                            },
                            onCancel: { sheet = nil })
        case .edit(let id):
            if let entry = model.servers.first(where: { $0.id == id }) {
                ServerFormSheet(title: "Sunucuyu Düzenle", confirmTitle: "Tamam", draft: ServerDraft(entry: entry),
                                onConfirm: { draft in
                                    model.updateServer(id: id, with: draft)
                                    sheet = nil
                                },
                                onCancel: { sheet = nil })
            }
        }
    }

    // MARK: Gerekçeler

    @ViewBuilder
    private var reasonsSection: some View {
        if let reasons = model.report?.reasons, !reasons.isEmpty {
            Card(title: "Gerekçeler") {
                ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                    // §14.2/1: birincil mesaj + ikincil "→ öneri" (gri, küçük).
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(reason.message)
                        } icon: {
                            Image(systemName: reason.severity.symbolName)
                                .foregroundStyle(reason.severity.color)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(reason.severity.label): \(reason.message)")

                        Text(SuggestionText.secondaryLine(for: reason.code))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 28)
                    }
                }
            }
        }
    }
}

/// Sunucu satırı: durum ikonu · etiket · host:port · CID; altında son kontrol zamanı (§8).
struct ServerRowView: View {
    let entry: ServerEntry
    let status: ServerRowStatus?
    let copied: Bool
    let onCopy: (String) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let status {
                    StatusIcon(level: status.displayLevel, help: status.displayMessage?.text)
                } else {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Kontrol edilmedi")
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 12) {
                    Text(entry.label).fontWeight(.medium)
                    Text("\(entry.host):\(String(entry.port))")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("Son kontrol: \(TimeText.format(entry.lastCheckedAt))")
                    if let message = status?.message {
                        Text(message.text)
                    }
                    if let banMessage = entry.banCheck?.status.messageCode {
                        Text(banMessage.text)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            BanColumn(check: entry.banCheck)

            if let cid = status?.currentCID {
                Button {
                    onCopy(cid)
                } label: {
                    Text(copied ? "Kopyalandı" : cid)
                        .font(.body.monospaced())
                        .frame(minWidth: 290, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help("Kopyalamak için tıklayın")
            } else {
                Text("—").foregroundStyle(.secondary)
            }

            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Sil")
            .accessibilityLabel("Sil")
            .opacity(hovering ? 1 : 0)
            .disabled(!hovering)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Düzenle", action: onEdit)
            Button("Sil", role: .destructive, action: onDelete)
        }
    }
}

/// §13.3 ban kolonu: ikon + metin; son kontrol zamanı tooltip'te.
struct BanColumn: View {
    let check: BanCheck?

    var body: some View {
        if let check {
            Label {
                Text(check.status.label)
            } icon: {
                Image(systemName: check.status.symbolName)
                    .foregroundStyle(check.status.level == .orange ? Color.secondary : check.status.level.color)
            }
            .frame(minWidth: 120, alignment: .leading)
            .help(tooltip(check))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Ban: \(check.status.label)")
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)
        }
    }

    private func tooltip(_ check: BanCheck) -> String {
        let time = "Son kontrol: \(TimeText.format(check.checkedAt))"
        return check.detail.isEmpty ? time : "\(time)\n\(check.detail)"
    }
}

/// "Ne yapmalı?" popover'ı (§14.2/2): gerekçelerin önerileri numaralı liste + "Kopyala".
struct SuggestionsPopover: View {
    let reasons: [StatusReason]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ne yapmalı?").font(.headline)
            ForEach(Array(SuggestionText.numberedLines(for: reasons).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                if copied {
                    Text("Kopyalandı").font(.caption).foregroundStyle(.secondary)
                }
                Button("Kopyala") {
                    Pasteboard.copy(SuggestionText.plainText(for: reasons))
                    copied = true
                }
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
