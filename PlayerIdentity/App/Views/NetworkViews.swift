import SwiftUI

/// Network card: public IP (copy), /24 + /16 ranges, local IPs, interfaces (§37) and egress / VPN state.
struct NetworkCard: View {
    @Bindable var model: AppModel
    @State private var copied = false

    var body: some View {
        ThemedCard {
            CardHeader(symbol: "globe", title: L10n.text(.networkTitle))
        } content: {
            if model.lastChecked == nil, model.isRefreshing {
                NetworkSkeleton()
            } else if isDisconnected {
                StateBlock(symbol: "wifi", symbolColor: Palette.text3, title: L10n.text(.networkEmptyTitle),
                           message: L10n.text(.networkEmptyBody)) { EmptyView() }
            } else {
                readyContent
            }
        }
        .accessibilityLabel(L10n.text(.networkTitle))
    }

    /// Checked, no public IP, no LAN address and no active interface.
    private var isDisconnected: Bool {
        guard model.lastChecked != nil, model.publicIP == nil, model.lanAddresses.isEmpty else { return false }
        return !(model.interfaceReport?.interfaces.contains(where: \.isActive) ?? false)
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            publicIPBlock
            rangesGrid
            ThemedDivider()
            InterfacesSection(report: model.interfaceReport, publicIP: model.publicIP)
        }
    }

    // MARK: Public IP

    private var publicIPBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(.networkPublicIP))
                .font(TypeScale.caption)
                .foregroundStyle(Palette.text2)
            if let ip = model.publicIP {
                HStack(spacing: Space.s2) {
                    Text(verbatim: ip)
                        .font(TypeScale.monoStrong)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .help(ip)
                        .accessibilityIdentifier("publicIP")
                    Button {
                        Pasteboard.copy(ip)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(L10n.text(copied ? .actionCopied : .actionCopy), systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(TypeScale.callout)
                    }
                    .controlSize(.small)
                    .help(L10n.text(.networkCopyIP))
                    .accessibilityLabel(L10n.text(.networkCopyIP))
                }
                .frame(height: Metrics.control)
            } else if model.lastChecked == nil {
                Text(verbatim: "—")
                    .font(TypeScale.monoStrong)
                    .foregroundStyle(Palette.text3)
                    .frame(height: Metrics.control)
            } else {
                // Error: lookup failed + Retry; ranges show "—", interfaces stay listed.
                HStack(spacing: Space.s2) {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.red)
                        .accessibilityHidden(true)
                    Text(L10n.text(.networkUnavailable))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.redText)
                        .lineLimit(1)
                        .help(MessageCode.publicIPFailed.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text(.actionRetry)) { model.refresh() }
                        .controlSize(.small)
                        .disabled(model.isRefreshing)
                }
                .frame(height: Metrics.control)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("publicIPFailed")
            }
        }
    }

    // MARK: Ranges + local IPs

    private var rangesGrid: some View {
        let ranges = model.publicIP.flatMap(IPRange.ranges(for:))
        let isIPv6 = model.publicIP.map { $0.contains(":") } ?? false
        return Grid(alignment: .leading, horizontalSpacing: Space.s3, verticalSpacing: 0) {
            rangeRow(isIPv6 ? "/64" : "/24", ranges?.narrow)
            rangeRow(isIPv6 ? "/48" : "/16", ranges?.wide)
            GridRow(alignment: .firstTextBaseline) {
                Text(L10n.text(.networkLocalIPs))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text2)
                    .fixedSize()
                if model.lanAddresses.isEmpty {
                    Text(model.lastChecked == nil ? "—" : MessageCode.lanIPMissing.text)
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text3)
                } else {
                    let text = model.lanAddresses.map(\.display).joined(separator: "\n")
                    Text(verbatim: text)
                        .font(TypeScale.mono)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .help(text)
                }
            }
            .frame(minHeight: Metrics.keyValueRow)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("publicIPRange")
    }

    private func rangeRow(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(verbatim: label)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
            Text(verbatim: value ?? "—")
                .font(TypeScale.mono)
                .foregroundStyle(value == nil ? Palette.text3 : Palette.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .help(value ?? "")
        }
        .frame(height: Metrics.keyValueRow)
    }
}

/// §37 network card rows: interfaces (icon, name, kind, IP, VPN / inactive), egress "<interface> → <IP>" and VPN state.
struct InterfacesSection: View {
    let report: InterfaceReport?
    let publicIP: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(.networkInterfaces))
                .font(TypeScale.caption)
                .foregroundStyle(Palette.text2)
                .padding(.bottom, 2)
            if let report, !report.interfaces.isEmpty {
                ForEach(report.interfaces, id: \.name) { InterfaceRow(interface: $0) }
            } else {
                Text(report == nil ? "—" : L10n.text(.networkInterfacesEmpty))
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.text3)
                    .frame(height: Metrics.interfaceRow)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("networkInterfaces")
        ThemedDivider()
        egress
    }

    private var egress: some View {
        HStack(alignment: .top, spacing: Space.s2) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.text2)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text(L10n.text(.networkEgress))
                        .font(TypeScale.callout)
                        .foregroundStyle(Palette.text2)
                        .fixedSize()
                    let line = Self.egressLine(publicIP: publicIP, interface: report?.egressInterface)
                    Text(verbatim: line)
                        .font(TypeScale.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(line)
                        .accessibilityIdentifier("networkEgress")
                }
                if let report {
                    if report.isVPNActive {
                        Label(L10n.text(.networkVPNWarning), systemImage: "lock.shield.fill")
                            .font(TypeScale.callout)
                            .foregroundStyle(Palette.orangeText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("networkVPNWarning")
                    } else {
                        Text(L10n.text(.networkVPNNone))
                            .font(TypeScale.callout)
                            .foregroundStyle(Palette.text2)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Çıkış: <IP> · <arayüz>"; unknown parts are "—".
    static func egressText(publicIP: String?, interface: String?) -> String {
        "\(publicIP ?? "—") · \(interface ?? "—")"
    }

    /// Card line `<interface> → <public IP>`; unknown parts are "—".
    static func egressLine(publicIP: String?, interface: String?) -> String {
        "\(interface ?? "—") → \(publicIP ?? "—")"
    }
}

/// Grid 16 | 44 | flex | 104 | 48: icon, BSD name, kind, IP, VPN badge or "Inactive". Row height 24.
private struct InterfaceRow: View {
    let interface: NetworkInterface

    var body: some View {
        let addresses = interface.ipv4 + interface.ipv6
        HStack(spacing: Space.s2) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(interface.isEgress ? Palette.accentText : Palette.text2)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(verbatim: interface.name)
                .font(TypeScale.mono)
                .lineLimit(1)
                .frame(width: 52, alignment: .leading)
            Text(kind)
                .font(TypeScale.callout)
                .foregroundStyle(Palette.text2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: addresses.first ?? "—")
                .font(TypeScale.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(width: 104, alignment: .trailing)
            Group {
                if interface.isTunnel {
                    TintBadge(text: L10n.text(.networkInterfaceVPN), foreground: Palette.accentText, background: Palette.accentTint)
                } else if !interface.isActive {
                    Text(L10n.text(.networkInterfaceInactive))
                        .font(TypeScale.caption)
                        .foregroundStyle(Palette.text3)
                        .lineLimit(1)
                }
            }
            .frame(width: 48, alignment: .trailing)
        }
        .frame(height: Metrics.interfaceRow)
        .opacity(interface.isActive ? 1 : 0.75)
        .help(addresses.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(addresses))
    }

    private var symbol: String {
        if interface.isTunnel { return "lock.shield.fill" }
        return interface.name.hasPrefix("bridge") ? "point.3.connected.trianglepath.dotted" : "network"
    }

    private var kind: String {
        if interface.isTunnel { return L10n.text(.networkKindTunnel) }
        return L10n.text(interface.name.hasPrefix("bridge") ? .networkKindBridge : .networkKindPhysical)
    }

    private func accessibilityText(_ addresses: [String]) -> String {
        var parts = [interface.name, kind]
        parts += addresses
        parts.append(L10n.text(interface.isActive ? .networkInterfaceActive : .networkInterfaceInactive))
        if interface.isTunnel { parts.append(L10n.text(.networkInterfaceVPN)) }
        if interface.isEgress { parts.append(L10n.text(.networkInterfaceEgress)) }
        return parts.joined(separator: ", ")
    }
}

/// Loading skeleton of the network card.
private struct NetworkSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBar(width: 60, height: 9)
                SkeletonBar(width: 150, height: 18, radius: 5)
            }
            VStack(alignment: .leading, spacing: Space.s3) {
                SkeletonBar(width: 160)
                SkeletonBar(width: 130)
            }
            .padding(.vertical, 5)
            ThemedDivider()
            VStack(alignment: .leading, spacing: 14) {
                SkeletonBar()
                SkeletonBar()
                SkeletonBar(width: 180)
            }
            .padding(.vertical, Space.s1)
            ThemedDivider()
            VStack(alignment: .leading, spacing: Space.s2) {
                SkeletonBar(width: 200)
                SkeletonBar(width: 140)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.text(.topbarChecking))
    }
}
