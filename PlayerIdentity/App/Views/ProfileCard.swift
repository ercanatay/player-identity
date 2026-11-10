import AppKit
import SwiftUI

/// Profile card: model thumbnail, name combo + model menu with "Edited" badges, Apply… (diff sheet),
/// key/value rows; game-running lock, userconfig override warning, loading / empty / error states.
struct ProfileCard: View {
    @Bindable var model: AppModel

    @State private var copied = false
    @State private var showsManualModel = false
    @State private var manualModelText = ""

    var body: some View {
        ThemedCard {
            CardHeader(symbol: "person.crop.circle", title: L10n.text(.profileTitle)) {
                if identity != nil { applyGroup }
            }
        } content: {
            if model.isGameRunning {
                // §15.7: the identity is read-only while the game runs.
                NoticeBox(symbol: "lock.fill", symbolColor: Palette.orangeText, text: EditMessage.gameRunning.text,
                          background: Palette.orangeTint)
                    .accessibilityIdentifier("gameRunningNote")
            }
            if model.hasConfigOverride { overrideNotice }
            switch model.identity {
            case .success?:
                readyContent
            case nil:
                ProfileSkeleton()
            case .failure(let error)?:
                failureContent(error)
            }
        }
        .accessibilityLabel(L10n.text(.profileTitle))
        .alert(L10n.text(.alertManualModelTitle), isPresented: $showsManualModel) {
            TextField(L10n.text(.profileModel), text: $manualModelText)
            Button(L10n.text(.actionOK)) { model.modelDraft = manualModelText }
            Button(L10n.text(.actionCancel), role: .cancel) {}
        }
    }

    private var identity: Identity? {
        guard case .success(let identity)? = model.identity else { return nil }
        return identity
    }

    private var isLocked: Bool { model.isGameRunning }

    // MARK: Header (pending count + Apply…)

    private var pendingCount: Int {
        (model.pendingName == nil ? 0 : 1) + (model.pendingModel == nil ? 0 : 1)
    }

    @ViewBuilder
    private var applyGroup: some View {
        switch model.applyStatus {
        case .success(let text)?:
            Text(text).font(TypeScale.callout).foregroundStyle(Palette.text2).lineLimit(1)
        case .failure(let error)?:
            Text(error.text).font(TypeScale.callout).foregroundStyle(Palette.redText).lineLimit(1).help(error.text)
        case nil:
            EmptyView()
        }
        if pendingCount > 0 {
            Text(L10n.format(.profilePending, String(pendingCount)))
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .opacity(isLocked ? 0.45 : 1)
        }
        Button {
            model.requestApply()
        } label: {
            HStack(spacing: 6) {
                if model.isApplying { ProgressView().controlSize(.small) }
                Text(verbatim: L10n.text(.actionApply) + "…")
            }
        }
        .prominentButton()
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canApply || isLocked)
        .help(L10n.text(.helpApply))
        .accessibilityIdentifier("applyButton")
    }

    // MARK: Notices

    private var overrideNotice: some View {
        // §43.1 userconfig.cfg override warning
        NoticeBox(symbol: "exclamationmark.triangle.fill", symbolColor: Palette.orangeText,
                  text: L10n.text(.configOverrideWarning), background: Palette.orangeTint) {
            Button(L10n.text(.configOverrideRemove)) { model.showsOverrideRemoval = true }
                .controlSize(.small)
                .disabled(model.isApplying)
        }
        .confirmationDialog(L10n.text(.configOverrideConfirmTitle), isPresented: $model.showsOverrideRemoval,
                            titleVisibility: .visible) {
            Button(L10n.text(.configOverrideRemove), role: .destructive) { model.removeOverride() }
            Button(L10n.text(.actionCancel), role: .cancel) {}
        } message: {
            Text(L10n.format(.configOverrideConfirmMessage, model.overriddenKeys.joined(separator: "/")))
        }
    }

    // MARK: Ready

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s4) {
                let preview = model.preview(for: model.modelDraft)
                    ?? (model.isLoadingPreviews ? nil : ModelPreview.placeholder)
                ModelPreviewView(preview: preview, modelName: model.modelDraft)
                    .help(preview?.image?.url.path ?? (model.modelDraft.isEmpty ? "" : model.modelDraft + ".bmp"))
                VStack(alignment: .leading, spacing: Space.s2) {
                    nameField
                    if let error = model.nameError { fieldError(error) }
                    modelRow
                    if let error = model.modelError { fieldError(error) }
                    Text(L10n.text(.profileModelServerNote))
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(isLocked ? 0.45 : 1)
                .disabled(isLocked)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            keyValueGrid(includeIdentity: true)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.s1) {
                Text(L10n.text(.profileName))
                sourceNote(model.configSources.name)
            }
            .font(TypeScale.caption)
            .foregroundStyle(Palette.text2)
            HStack(spacing: Space.s2) {
                TextField(L10n.text(.profileName), text: $model.nameDraft)
                    .textFieldStyle(.plain)
                    .font(TypeScale.title)
                    .lineLimit(1)
                    .help(model.nameDraft)
                    .accessibilityLabel(L10n.format(.a11yProfileName, model.nameDraft))
                    .accessibilityIdentifier("profileName")
                if model.pendingName != nil { editedBadge }
                Menu {
                    ForEach(model.nameOptions, id: \.self) { option in
                        Button(option) { model.nameDraft = option }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.text2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.nameOptions.isEmpty)
                .help(L10n.text(.profileNameRecent))
                .accessibilityLabel(L10n.text(.profileNameRecent))
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: Metrics.nameField)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Palette.controlBorder, lineWidth: 1))
        }
    }

    private var modelRow: some View {
        HStack(spacing: Space.s2) {
            Text(L10n.text(.profileModel))
                .font(TypeScale.caption)
                .foregroundStyle(Palette.text2)
                .fixedSize()
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
                .frame(width: Metrics.modelPicker)
            if model.pendingModel != nil { editedBadge }
            sourceNote(model.configSources.model)
            Spacer(minLength: 0)
        }
    }

    private var editedBadge: some View {
        TintBadge(text: L10n.text(.profileEdited), foreground: Palette.orangeText, background: Palette.orangeTint)
    }

    @ViewBuilder
    private func sourceNote(_ source: ConfigFileKind?) -> some View {
        if let source {
            Text(verbatim: "· " + source.note)
                .font(TypeScale.caption)
                .foregroundStyle(Palette.text3)
                .lineLimit(1)
                .help(source.note)
        }
    }

    private func fieldError(_ error: EditMessage) -> some View {
        Text(error.text)
            .font(TypeScale.callout)
            .foregroundStyle(Palette.redText)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Key / value grid

    private func keyValueGrid(includeIdentity: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Space.s2, verticalSpacing: Space.s1) {
            if includeIdentity {
                let raw = identity?.rawIDHex ?? "—"
                kvRow(L10n.text(.profileRawID)) {
                    Text(verbatim: raw).font(TypeScale.mono).middleTruncated(raw)
                } action: {
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc",
                               label: L10n.text(copied ? .actionCopied : .actionCopy)) { copyRawID(raw) }
                        .disabled(identity == nil)
                }
                let path = identity?.source.url.path
                kvRow(L10n.text(.profileIdentitySource)) {
                    Text(verbatim: path.map(Self.abbreviated) ?? "—").font(TypeScale.mono).middleTruncated(path ?? "")
                } action: {
                    if let url = identity?.source.url {
                        IconButton(symbol: "folder", label: L10n.text(.profileShowInFinder)) { Finder.reveal(url) }
                    }
                }
            }
            kvRow(L10n.text(.profileGamedir)) {
                if gamedirOptions.isEmpty {
                    Text(L10n.text(.profileNoGamedir)).font(TypeScale.callout).foregroundStyle(Palette.text2)
                } else {
                    Picker(L10n.text(.profileGamedir), selection: Binding(
                        get: { model.selectedGamedir ?? "" },
                        set: { model.selectGamedir($0) }
                    )) {
                        ForEach(gamedirOptions, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(isLocked)
                }
            } action: {
                EmptyView()
            }
            kvRow(L10n.text(.profileDataRoot)) {
                Text(verbatim: Self.abbreviated(model.dataRoot.path)).font(TypeScale.mono).middleTruncated(model.dataRoot.path)
            } action: {
                Menu {
                    Button(L10n.text(.profileShowInFinder)) { Finder.reveal(model.dataRoot) }
                    Button(L10n.text(.profileChooseFolder), action: chooseDataRoot)
                } label: {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Palette.text2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: Metrics.smallControl, height: Metrics.smallControl)
                .help(L10n.text(.profileChooseFolder))
                .accessibilityLabel(L10n.text(.profileChooseFolder))
                .accessibilityIdentifier("dataRootMenu")
            }
        }
    }

    private func kvRow<Value: View, Action: View>(_ label: String, @ViewBuilder value: () -> Value,
                                                  @ViewBuilder action: () -> Action) -> some View {
        GridRow {
            Text(label)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .frame(width: Metrics.keyValueLabel, alignment: .leading)
                .help(label)
            value()
                .frame(maxWidth: .infinity, minHeight: Metrics.keyValueRow, alignment: .leading)
            action()
                .frame(width: Metrics.smallControl, height: Metrics.smallControl)
        }
        .accessibilityElement(children: .contain)
    }

    private func copyRawID(_ raw: String) {
        Pasteboard.copy(raw)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    // MARK: Empty / error

    @ViewBuilder
    private func failureContent(_ error: IdentityError) -> some View {
        VStack(spacing: Space.s3) {
            switch error {
            case .missing:
                StateBlock(symbol: "person.crop.circle", symbolColor: Palette.text3, title: L10n.text(.profileEmptyTitle),
                           message: MessageCode.identityMissing.text, minHeight: 168) {
                    Button(L10n.text(.profileScanAgain)) { model.refresh() }
                        .disabled(model.isRefreshing)
                    Button(L10n.text(.profileChooseFolder), action: chooseDataRoot)
                        .prominentButton()
                }
            case .invalid:
                StateBlock(symbol: "exclamationmark.triangle.fill", symbolColor: Palette.orange,
                           title: L10n.text(.profileErrorTitle), message: MessageCode.identityInvalid.text,
                           minHeight: 168) {
                    Button(L10n.text(.profileChooseFolder), action: chooseDataRoot)
                    Button(L10n.text(.actionRetry)) { model.refresh() }
                        .prominentButton()
                        .disabled(model.isRefreshing)
                }
                .accessibilityAddTraits(.isStaticText)
            }
            keyValueGrid(includeIdentity: false)
        }
    }

    // MARK: Helpers

    private var gamedirOptions: [String] {
        var options = model.gamedirs
        if let selected = model.selectedGamedir, !options.contains(selected) { options.append(selected) }
        return options
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func chooseDataRoot() {
        DataRootPanel.choose(model)
    }
}

/// Loading skeleton with the ready state's geometry (thumbnail, name field, model menu, five key/value rows).
private struct ProfileSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s4) {
                RoundedRectangle(cornerRadius: Radius.inner)
                    .fill(Palette.skeleton)
                    .frame(width: Metrics.modelThumbnail.width, height: Metrics.modelThumbnail.height)
                VStack(alignment: .leading, spacing: Space.s2) {
                    SkeletonBar(height: Metrics.nameField, radius: Radius.control)
                    SkeletonBar(width: 196, height: Metrics.control, radius: Radius.control)
                }
                .padding(.top, 15)
            }
            VStack(alignment: .leading, spacing: Space.s1) {
                ForEach([0.70, 0.80, 0.76, 0.24, 0.64], id: \.self) { fraction in
                    HStack(spacing: Space.s2) {
                        SkeletonBar(width: 96)
                        GeometryReader { proxy in
                            SkeletonBar(width: proxy.size.width * fraction)
                        }
                        .frame(height: 10)
                    }
                    .frame(height: Metrics.keyValueRow)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.text(.topbarChecking))
        .accessibilityIdentifier("profileSkeleton")
    }
}
