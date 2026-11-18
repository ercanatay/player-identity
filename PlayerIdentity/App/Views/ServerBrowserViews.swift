import SwiftUI

/// §70.3 "Find Servers" window: toolbar (title + count, search / cancel, reload), progress line, filter bar, notes,
/// then the table (name | map | players | ping | password | Add · Diagnose · Refresh) or an idle / empty / error /
/// cancelled state, and a footer.
struct ServerBrowserView: View {
    @Bindable var model: AppModel
    /// Offscreen renders have no window toolbar: draw the same toolbar groups in the content (`InlineToolbar`).
    var inlineToolbar = false
    /// The main window (the diagnosis opens in its server details).
    var openMainWindow: () -> Void = {}

    private var browser: ServerBrowserController { model.serverBrowser }

    var body: some View {
        VStack(spacing: 0) {
            if inlineToolbar {
                InlineToolbar { toolbarLeading } trailing: { toolbarTrailing }
            }
            VStack(alignment: .leading, spacing: Space.s3) {
                if browser.isRunning { progress }
                BrowserFilterBar(browser: browser)
                notes
                content
                footer
            }
            .padding(Space.s4)
        }
        .background(Palette.window)
        .foregroundStyle(Palette.text)
        .font(TypeScale.body)
        .frame(minWidth: BrowserLayout.minWidth, minHeight: BrowserLayout.minHeight)
        .toolbar {
            if !inlineToolbar {
                ToolbarItem(placement: .navigation) { toolbarLeading }
                ToolbarItemGroup(placement: .primaryAction) { toolbarTrailing }
            }
        }
        .task {
            // Opening the window shows the last scan (≤ 5 min) or starts one; never in the test host.
            guard !AppModel.isRunningTests, browser.phase == .idle else { return }
            browser.start()
        }
    }

    // MARK: Toolbar

    private var toolbarLeading: some View {
        ToolbarTitle(title: L10n.text(.serverBrowserTitle), count: countText)
            .accessibilityIdentifier("serverBrowserCount")
    }

    private var countText: String? {
        guard !browser.servers.isEmpty else { return nil }
        let listing = browser.listing
        return L10n.format(.serverBrowserCount, String(listing.rows.count), String(listing.total))
    }

    @ViewBuilder
    private var toolbarTrailing: some View {
        if browser.isRunning {
            Button { browser.cancel() } label: {
                Label(L10n.text(.actionAbort), systemImage: "stop.circle")
                    .labelStyle(.titleAndIcon)
            }
            .help(L10n.text(.actionAbort))
            .accessibilityIdentifier("serverBrowserCancel")
        } else {
            Button { browser.start(force: browser.scan != nil) } label: {
                Label(browser.scan == nil ? L10n.text(.serverBrowserSearch) : L10n.text(.serverBrowserReload),
                      systemImage: browser.scan == nil ? "magnifyingglass" : "arrow.clockwise")
                    .labelStyle(.titleAndIcon)
            }
            .help(browser.scan == nil ? L10n.text(.serverBrowserSearch) : L10n.text(.serverBrowserReload))
            .accessibilityIdentifier("serverBrowserStart")
        }
    }

    // MARK: Progress, notes, footer

    private var progress: some View {
        let (text, value): (String, Double?) = {
            switch browser.phase {
            case .master(let count):
                return (L10n.format(.serverBrowserProgressMaster, String(count)), nil)
            case .servers(let asked, let answered, let total):
                return (L10n.format(.serverBrowserProgressServers, String(asked), String(total), String(answered)),
                        total > 0 ? Double(asked) / Double(total) : nil)
            default:
                return ("", nil)
            }
        }()
        return HStack(spacing: Space.s3) {
            if let value {
                ProgressView(value: value).frame(width: BrowserLayout.progressBar)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier("serverBrowserProgress")
    }

    @ViewBuilder
    private var notes: some View {
        if case .diskCache(let savedAt)? = browser.scan?.source {
            NoticeBox(symbol: "clock.arrow.circlepath", symbolColor: Palette.orange,
                      text: L10n.format(.serverBrowserCacheNote, savedAt.formatted(date: .abbreviated, time: .shortened)),
                      background: Palette.orangeTint)
                .accessibilityIdentifier("serverBrowserCacheNote")
        }
        if browser.scan?.isPartial == true {
            NoticeBox(symbol: "hourglass", symbolColor: Palette.orange, text: L10n.text(.serverBrowserPartialNote),
                      background: Palette.orangeTint)
        }
        if browser.phase == .cancelled, !browser.servers.isEmpty {
            NoticeBox(symbol: "stop.circle", symbolColor: Palette.text2, text: L10n.text(.serverBrowserCancelled),
                      background: Palette.group)
                .accessibilityIdentifier("serverBrowserCancelledNote")
        }
        if let message = browser.rowMessage {
            NoticeBox(symbol: "info.circle", symbolColor: Palette.text2, text: message, background: Palette.group)
        }
    }

    @ViewBuilder
    private var footer: some View {
        let listing = browser.listing
        HStack(spacing: Space.s2) {
            Image(systemName: "info.circle")
                .foregroundStyle(Palette.text3)
                .accessibilityHidden(true)
            Text(L10n.text(.serverBrowserIncompleteNote))
            if listing.isCut {
                Spacer(minLength: Space.s2)
                Text(L10n.format(.serverBrowserMore, String(BrowserFilter.displayLimit)))
                    .foregroundStyle(Palette.orangeText)
                    .accessibilityIdentifier("serverBrowserMore")
            }
        }
        .font(TypeScale.caption)
        .foregroundStyle(Palette.text3)
        .lineLimit(2)
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let listing = browser.listing
        if !listing.rows.isEmpty {
            BrowserTable(model: model, rows: listing.rows, openMainWindow: openMainWindow)
        } else if !browser.servers.isEmpty {
            state(symbol: "line.3.horizontal.decrease.circle", color: Palette.text3,
                  title: L10n.text(.serverBrowserNoMatchTitle), message: L10n.text(.serverBrowserNoMatchBody),
                  identifier: "serverBrowserNoMatch") {
                Button(L10n.text(.serverBrowserFilterClear)) { browser.clearFilter() }
            }
        } else {
            switch browser.phase {
            case .idle:
                state(symbol: "globe", color: Palette.accentText, title: L10n.text(.serverBrowserTitle),
                      message: L10n.text(.serverBrowserIdle), identifier: "serverBrowserIdle") {
                    Button(L10n.text(.serverBrowserSearch)) { browser.start() }
                        .prominentButton()
                }
            case .master, .servers:
                state(symbol: "antenna.radiowaves.left.and.right", color: Palette.text3,
                      title: L10n.text(.serverBrowserTitle), message: progressText, identifier: "serverBrowserLoading") {
                    EmptyView()
                }
            case .finished:
                state(symbol: "tray", color: Palette.text3, title: L10n.text(.serverBrowserEmptyTitle),
                      message: L10n.text(.serverBrowserEmptyBody), identifier: "serverBrowserEmpty") {
                    Button(L10n.text(.actionRetry)) { browser.start(force: true) }
                }
            case .failed(let error):
                state(symbol: "exclamationmark.triangle.fill", color: Palette.red, title: L10n.text(.serverBrowserErrorTitle),
                      message: BrowserText.error(error), identifier: "serverBrowserError") {
                    Button(L10n.text(.actionRetry)) { browser.start(force: true) }
                        .prominentButton()
                }
            case .cancelled:
                state(symbol: "stop.circle", color: Palette.text3, title: L10n.text(.serverBrowserTitle),
                      message: L10n.text(.serverBrowserCancelled), identifier: "serverBrowserCancelled") {
                    Button(L10n.text(.actionRetry)) { browser.start(force: true) }
                }
            }
        }
    }

    private var progressText: String {
        switch browser.phase {
        case .master(let count): return L10n.format(.serverBrowserProgressMaster, String(count))
        case .servers(let asked, let answered, let total):
            return L10n.format(.serverBrowserProgressServers, String(asked), String(total), String(answered))
        default: return ""
        }
    }

    private func state<Actions: View>(symbol: String, color: Color, title: String, message: String, identifier: String,
                                      @ViewBuilder actions: () -> Actions) -> some View {
        StateBlock(symbol: symbol, symbolColor: color, title: title, message: message, actions: actions)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
            .accessibilityIdentifier(identifier)
    }
}

/// Texts shared by the window and the tests.
enum BrowserText {
    static func error(_ error: MasterQueryError) -> String {
        switch error {
        case .dns: return L10n.text(.serverBrowserErrorDns)
        case .network: return L10n.text(.serverBrowserErrorNetwork)
        case .timeout: return L10n.text(.serverBrowserErrorTimeout)
        }
    }

    static func sort(_ sort: BrowserSort) -> String {
        switch sort {
        case .players: return L10n.text(.serverBrowserSortPlayers)
        case .ping: return L10n.text(.serverBrowserSortPing)
        case .name: return L10n.text(.serverBrowserFilterName)
        }
    }

    static func players(_ server: BrowserServer) -> String { "\(server.players)/\(server.maxPlayers)" }

    static func password(_ server: BrowserServer) -> String {
        switch server.passworded {
        case true?: return L10n.text(.serverBrowserPasswordOn)
        case false?: return L10n.text(.serverBrowserFilterNoPassword)
        case nil: return L10n.text(.serverBrowserPasswordUnknown)
        }
    }

    /// VoiceOver label of a row: name, map, players, ping (+ password state, + "Added").
    static func rowLabel(_ server: BrowserServer, added: Bool) -> String {
        var parts = [L10n.format(.serverBrowserA11yRow, server.displayName, server.map.isEmpty ? "—" : server.map,
                                 players(server), String(server.pingMillis)),
                     password(server)]
        if added { parts.append(L10n.text(.serverBrowserAdded)) }
        return parts.joined(separator: ", ")
    }
}

enum BrowserLayout {
    static let minWidth: CGFloat = 760
    static let minHeight: CGFloat = 440
    static let progressBar: CGFloat = 160
    static let map: CGFloat = 130
    static let players: CGFloat = 64
    static let ping: CGFloat = 56
    static let password: CGFloat = 28
    static let actions: CGFloat = 196
    static let textField: CGFloat = 120
    static let numberField: CGFloat = 52
}

// MARK: - Filter bar

private struct BrowserFilterBar: View {
    @Bindable var browser: ServerBrowserController

    var body: some View {
        HStack(spacing: Space.s2) {
            TextField(L10n.text(.serverBrowserFilterMap), text: $browser.filter.map)
                .frame(width: BrowserLayout.textField)
                .accessibilityLabel(L10n.text(.serverBrowserFilterMap))
                .accessibilityIdentifier("serverBrowserFilterMap")
            TextField(L10n.text(.serverBrowserFilterName), text: $browser.filter.name)
                .frame(width: BrowserLayout.textField)
                .accessibilityLabel(L10n.text(.serverBrowserFilterName))
                .accessibilityIdentifier("serverBrowserFilterName")
            numberField(L10n.text(.serverBrowserFilterMinPlayers), value: $browser.filter.minPlayers,
                        identifier: "serverBrowserFilterMinPlayers")
            numberField(L10n.text(.serverBrowserFilterMaxPing), value: $browser.filter.maxPing,
                        identifier: "serverBrowserFilterMaxPing")
            Toggle(L10n.text(.serverBrowserFilterNotEmpty), isOn: $browser.filter.notEmpty)
                .accessibilityIdentifier("serverBrowserFilterNotEmpty")
            Toggle(L10n.text(.serverBrowserFilterNoPassword), isOn: $browser.filter.noPassword)
                .accessibilityIdentifier("serverBrowserFilterNoPassword")
            Spacer(minLength: 0)
            Picker(L10n.text(.serverBrowserSort), selection: $browser.filter.sort) {
                ForEach(BrowserSort.allCases, id: \.self) { sort in
                    Text(BrowserText.sort(sort)).tag(sort)
                }
            }
            .fixedSize()
            .accessibilityIdentifier("serverBrowserSort")
        }
        .textFieldStyle(.roundedBorder)
        .toggleStyle(.checkbox)
        .font(TypeScale.callout)
        .controlSize(.small)
    }

    /// Digits only; empty = no limit.
    private func numberField(_ title: String, value: Binding<Int?>, identifier: String) -> some View {
        HStack(spacing: Space.s1) {
            Text(title)
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .fixedSize()
            TextField(title, text: Binding(
                get: { value.wrappedValue.map(String.init) ?? "" },
                set: { text in
                    let digits = String(text.filter(\.isASCIIDigit).prefix(5))
                    value.wrappedValue = digits.isEmpty ? nil : Int(digits)
                }), prompt: Text(verbatim: "—"))
                .labelsHidden()
                .frame(width: BrowserLayout.numberField)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Table

private struct BrowserTable: View {
    @Bindable var model: AppModel
    let rows: [BrowserServer]
    var openMainWindow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { server in
                        BrowserRow(model: model, server: server, openMainWindow: openMainWindow)
                        ThemedDivider()
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border, lineWidth: Metrics.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(.serverBrowserA11yTable))
        .accessibilityIdentifier("serverBrowserTable")
    }

    private var header: some View {
        HStack(spacing: Metrics.Column.gap) {
            Text(L10n.text(.serverBrowserFilterName)).frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.text(.serverBrowserFilterMap)).frame(width: BrowserLayout.map, alignment: .leading)
            Text(L10n.text(.serverBrowserSortPlayers)).frame(width: BrowserLayout.players, alignment: .trailing)
            Text(L10n.text(.serverBrowserSortPing)).frame(width: BrowserLayout.ping, alignment: .trailing)
            Image(systemName: "lock")
                .frame(width: BrowserLayout.password)
                .help(L10n.text(.serverBrowserColumnPassword))
                .accessibilityLabel(L10n.text(.serverBrowserColumnPassword))
            Color.clear.frame(width: BrowserLayout.actions, height: 1)
        }
        .lineLimit(1)
        .font(TypeScale.captionStrong)
        .foregroundStyle(Palette.text2)
        .padding(.horizontal, Space.s3)
        .frame(height: Metrics.groupHeader)
        .background(Palette.group)
        .overlay(alignment: .bottom) { ThemedDivider() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct BrowserRow: View {
    @Bindable var model: AppModel
    let server: BrowserServer
    var openMainWindow: () -> Void

    var body: some View {
        let added = model.savedServerID(for: server.address) != nil
        let refreshing = model.serverBrowser.refreshing.contains(server.address)
        HStack(spacing: Metrics.Column.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: server.displayName)
                    .font(TypeScale.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(server.displayName)
                Text(verbatim: server.address.id)
                    .font(TypeScale.monoSmall)
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: server.map.isEmpty ? "—" : server.map)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .help(server.map)
                .frame(width: BrowserLayout.map, alignment: .leading)
            Text(verbatim: BrowserText.players(server))
                .font(TypeScale.callout)
                .monospacedDigit()
                .foregroundStyle(server.players > 0 ? Palette.text : Palette.text3)
                .frame(width: BrowserLayout.players, alignment: .trailing)
            Text(verbatim: "\(server.pingMillis)")
                .font(TypeScale.callout)
                .monospacedDigit()
                .foregroundStyle(Palette.text2)
                .frame(width: BrowserLayout.ping, alignment: .trailing)
            Image(systemName: server.passworded == true ? "lock.fill" : (server.passworded == nil ? "questionmark" : "lock.open"))
                .font(.system(size: 11))
                .foregroundStyle(server.passworded == true ? Palette.orangeText : Palette.text3)
                .frame(width: BrowserLayout.password)
                .help(BrowserText.password(server))
                .accessibilityLabel(BrowserText.password(server))
            actions(added: added, refreshing: refreshing)
                .frame(width: BrowserLayout.actions, alignment: .trailing)
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .frame(minHeight: Metrics.row)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BrowserText.rowLabel(server, added: added))
    }

    private func actions(added: Bool, refreshing: Bool) -> some View {
        HStack(spacing: Space.s1) {
            if added {
                TintBadge(text: L10n.text(.serverBrowserAdded), foreground: Palette.greenText, background: Palette.greenTint,
                          symbol: "checkmark")
                    .accessibilityIdentifier("serverBrowserAdded")
            } else {
                Button(L10n.text(.actionAdd)) { model.addBrowserServer(server) }
                    .accessibilityIdentifier("serverBrowserAdd")
            }
            Button(L10n.text(.menuBarDiagnose)) {
                model.diagnoseBrowserServer(server)
                openMainWindow()
            }
            .disabled(model.isDataOperationRunning)
            .accessibilityIdentifier("serverBrowserDiagnose")
            IconButton(symbol: "arrow.clockwise", label: L10n.text(.actionRefresh)) {
                model.serverBrowser.refreshRow(server.address)
            }
            .disabled(refreshing)
            .opacity(refreshing ? 0.4 : 1)
            .accessibilityIdentifier("serverBrowserRefresh")
        }
        .controlSize(.small)
        .font(TypeScale.callout)
    }
}

/// The window scene's root: brings up the main window when a row's "Diagnose" opens the server details there.
struct ServerBrowserWindow: View {
    static let id = "serverBrowser"

    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ServerBrowserView(model: model, openMainWindow: { openWindow(id: "main") })
    }
}
