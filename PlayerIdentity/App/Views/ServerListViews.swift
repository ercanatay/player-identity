import AppKit
import SwiftUI

/// Row callbacks; the row itself holds no model (§8, §29–§33).
struct ServerRowActions {
    var copy: (String) -> Void = { _ in }
    var edit: () -> Void = {}
    var delete: () -> Void = {}
    /// §17.1: only on `ipBanned` / `cidBanned` / `unreachable` rows.
    var fix: (() -> Void)?
    /// §29: `nil` = Xash3D is not installed (the action is hidden).
    var join: (() -> Void)?
    var toggleFavorite: () -> Void = {}
    /// §42 🔔 watch switch.
    var toggleWatch: () -> Void = {}
    /// §31 ▲/▼; `nil` = the row cannot move in that direction.
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    /// §32 notes and appeal; §33 share card.
    var details: () -> Void = {}
    var shareCard: () -> Void = {}
}

/// §31 server list: filters, sections by group (servers without a group under "Other"), favorites first.
struct ServerSectionsView: View {
    @Bindable var model: AppModel
    let copiedKey: String?
    let makeActions: (ServerEntry) -> ServerRowActions

    var body: some View {
        let sections = model.serverSections(filter: model.serverFilter)
        let showsHeaders = !model.serverGroups.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Spacer()
                Toggle(L10n.text(.serversFilterBanned), isOn: $model.serverFilter.onlyBanned)
                    .accessibilityIdentifier("filterBanned")
                Toggle(L10n.text(.serversFilterFavorites), isOn: $model.serverFilter.onlyFavorites)
                    .accessibilityIdentifier("filterFavorites")
                Toggle(L10n.text(.serversFilterWatched), isOn: $model.serverFilter.onlyWatched)
                    .accessibilityIdentifier("filterWatched")
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            if model.hasWatchedServers, !model.menuBarEnabled {
                // §42: no background checks without the menu bar mode.
                Label(L10n.text(.watchBackgroundNote), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("watchBackgroundNote")
            }

            if sections.isEmpty {
                Text(L10n.text(.serversFilterEmpty))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            ForEach(sections, id: \.group) { section in
                VStack(alignment: .leading, spacing: 0) {
                    if showsHeaders {
                        Text(section.group ?? L10n.text(.serversOther))
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(section.servers) { entry in
                        ServerRowView(entry: entry,
                                      status: model.rowStatus(entry.id),
                                      copied: copiedKey == entry.id.uuidString,
                                      followUpDue: model.isFollowUpDue(entry),
                                      actions: makeActions(entry))
                        if entry.id != section.servers.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

/// Server row: ★ · status icon · label · host:port · badges · ban · CID · actions; last check time below (§8).
struct ServerRowView: View {
    let entry: ServerEntry
    let status: ServerRowStatus?
    let copied: Bool
    /// §32: the follow-up date of an open appeal has passed (🔔).
    var followUpDue = false
    let actions: ServerRowActions

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: actions.toggleFavorite) {
                Image(systemName: entry.favorite ? "star.fill" : "star")
                    .foregroundStyle(entry.favorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.text(entry.favorite ? .serverFavoriteRemove : .serverFavoriteAdd))
            .accessibilityLabel(L10n.text(entry.favorite ? .serverFavoriteRemove : .serverFavoriteAdd))
            .accessibilityValue(entry.favorite ? L10n.text(.serverFavorite) : "")
            .accessibilityIdentifier("favorite")

            Group {
                if let status {
                    StatusIcon(level: status.displayLevel, help: status.displayMessage?.text)
                } else {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text(.serverNotChecked))
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text(entry.label).fontWeight(.medium)
                        .help(entry.banCheck?.info?.name ?? "")
                    Text(verbatim: "\(entry.host):\(String(entry.port))")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    badges
                }
                // §20: `host → resolved IP` (or resolving/error); §21: `map · 9/26 · 42 ms`, hidden if unknown.
                if let address = ServerRowText.addressLine(host: entry.host, status: status) {
                    Text(verbatim: address)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let info = ServerRowText.infoLine(entry.banCheck?.info) {
                    Text(verbatim: info)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(entry.banCheck?.info?.name ?? "")
                        .accessibilityIdentifier("serverInfo")
                }
                HStack(spacing: 8) {
                    Text(L10n.format(.topbarLastCheck, TimeText.format(entry.lastCheckedAt)))
                    if let message = status?.message {
                        Text(message.text)
                    }
                    if let check = entry.banCheck,
                       case .rejectedUnknownType(let raw) = BanClassification.classify(check) {
                        // §17.9.2: server rejected, type unknown → the raw reply is shown.
                        Text(BanClassification.unverifiedText + ": " + raw)
                    } else if let banMessage = entry.banCheck?.status.messageCode {
                        Text(banMessage.text)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 4) {
                BanColumn(check: entry.banCheck)
                if let fix = actions.fix {
                    // §17.7: "Fix" next to/below the ban icon.
                    Button(L10n.text(.actionFix), action: fix)
                        .controlSize(.small)
                }
            }

            if let cid = status?.currentCID {
                Button {
                    actions.copy(cid)
                } label: {
                    Text(copied ? L10n.text(.actionCopied) : cid)
                        .font(.body.monospaced())
                        .frame(minWidth: 290, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help(L10n.text(.serverCopyHint))
            } else {
                Text(verbatim: "—").foregroundStyle(.secondary)
            }

            Button(action: actions.toggleWatch) {
                Image(systemName: entry.watch ? "bell.fill" : "bell")
                    .foregroundStyle(entry.watch ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.text(entry.watch ? .watchToggleOff : .watchToggleOn))
            .accessibilityLabel(L10n.text(entry.watch ? .watchToggleOff : .watchToggleOn))
            .accessibilityValue(entry.watch ? L10n.text(.watchBadge) : "")
            .accessibilityIdentifier("watchToggle")

            if let join = actions.join {
                Button(action: join) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help(L10n.text(.gameJoin))
                .accessibilityLabel(L10n.text(.gameJoin))
                .accessibilityIdentifier("joinGame")
            }

            VStack(spacing: 0) {
                Button { actions.moveUp?() } label: { Image(systemName: "chevron.up").font(.caption2) }
                    .disabled(actions.moveUp == nil)
                    .help(L10n.text(.serverMoveUp))
                    .accessibilityLabel(L10n.text(.serverMoveUp))
                Button { actions.moveDown?() } label: { Image(systemName: "chevron.down").font(.caption2) }
                    .disabled(actions.moveDown == nil)
                    .help(L10n.text(.serverMoveDown))
                    .accessibilityLabel(L10n.text(.serverMoveDown))
            }
            .buttonStyle(.borderless)

            Button(action: actions.delete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.text(.actionDelete))
            .accessibilityLabel(L10n.text(.actionDelete))
            .opacity(hovering ? 1 : 0)
            .disabled(!hovering)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let join = actions.join {
                Button(L10n.text(.gameJoin), action: join)
                Divider()
            }
            Button(L10n.text(.serverDetails), action: actions.details)
            Button(L10n.text(.shareCardCreate), action: actions.shareCard)
            Divider()
            Button(L10n.text(entry.favorite ? .serverFavoriteRemove : .serverFavoriteAdd), action: actions.toggleFavorite)
            Button(L10n.text(entry.watch ? .watchToggleOff : .watchToggleOn), action: actions.toggleWatch)
            Button(L10n.text(.serverMoveUp)) { actions.moveUp?() }.disabled(actions.moveUp == nil)
            Button(L10n.text(.serverMoveDown)) { actions.moveDown?() }.disabled(actions.moveDown == nil)
            Divider()
            Button(L10n.text(.actionEdit), action: actions.edit)
            Button(L10n.text(.actionDelete), role: .destructive, action: actions.delete)
        }
    }

    /// §32: note, appeal status and follow-up reminder; each opens the details.
    @ViewBuilder
    private var badges: some View {
        if entry.watch {
            // §42 small 🔔 badge of a watched row.
            Label(L10n.text(.watchBadge), systemImage: "bell.fill")
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
                .accessibilityIdentifier("watchBadge")
        }
        if !entry.note.isEmpty {
            Button(action: actions.details) {
                Image(systemName: "note.text").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(entry.note)
            .accessibilityLabel(L10n.text(.notesHasNote))
        }
        if let appeal = entry.appeal {
            Button(action: actions.details) {
                AppealStatusBadge(status: appeal.status)
            }
            .buttonStyle(.plain)
            .help(L10n.text(.appealTitle) + " · " + appeal.channelLabel)
            if followUpDue, let date = appeal.followUpAt {
                // §32: 🔔 reminder when the follow-up date has passed.
                Button(action: actions.details) {
                    Image(systemName: "bell.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help(L10n.format(.appealFollowUpDue, AppealDates.text(date)))
                .accessibilityLabel(L10n.format(.appealFollowUpDue, AppealDates.text(date)))
                .accessibilityIdentifier("followUpDue")
            }
        }
    }
}

/// Appeal status capsule (§32).
struct AppealStatusBadge: View {
    let status: AppealStatus

    var body: some View {
        Text(status.label)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
            .fixedSize()
            .accessibilityLabel(L10n.text(.appealTitle) + " · " + status.label)
    }

    private var color: Color {
        switch status {
        case .sent: return .blue
        case .answered: return .purple
        case .rejected: return .red
        case .accepted: return .green
        }
    }
}

enum AppealDates {
    static func text(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }
}
