import SwiftUI

/// §37 network card rows: interfaces (name, IPs, active, VPN), egress "<IP> · <interface>", VPN state and warning.
struct InterfacesSection: View {
    let report: InterfaceReport?
    let publicIP: String?

    var body: some View {
        FieldRow(title: L10n.text(.networkInterfaces)) {
            if let report, !report.interfaces.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.interfaces, id: \.name) { InterfaceRow(interface: $0) }
                }
            } else {
                Text(report == nil ? "—" : L10n.text(.networkInterfacesEmpty)).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("networkInterfaces")
        FieldRow(title: L10n.text(.networkEgress)) {
            Text(verbatim: Self.egressText(publicIP: publicIP, interface: report?.egressInterface))
                .font(.body.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("networkEgress")
        }
        if let report {
            FieldRow(title: L10n.text(.networkVPN)) {
                if report.isVPNActive {
                    Label(L10n.text(.networkVPNWarning), systemImage: "lock.shield.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("networkVPNWarning")
                } else {
                    Text(L10n.text(.networkVPNNone)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "Çıkış: <IP> · <arayüz>"; unknown parts are "—".
    static func egressText(publicIP: String?, interface: String?) -> String {
        "\(publicIP ?? "—") · \(interface ?? "—")"
    }
}

private struct InterfaceRow: View {
    let interface: NetworkInterface

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: interface.isActive ? "circle.fill" : "circle")
                .font(.system(size: 8))
                .foregroundStyle(interface.isActive ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(verbatim: interface.name)
                .font(.body.monospaced().weight(.medium))
                .frame(minWidth: 70, alignment: .leading)
            Text(verbatim: (interface.ipv4 + interface.ipv6).joined(separator: ", "))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            badge(L10n.text(interface.isActive ? .networkInterfaceActive : .networkInterfaceInactive),
                  color: interface.isActive ? .green : .secondary)
            if interface.isTunnel {
                badge(L10n.text(.networkInterfaceVPN), color: .orange)
            }
            if interface.isEgress {
                Image(systemName: "arrow.up.right.circle.fill")
                    .foregroundStyle(.blue)
                    .help(L10n.text(.networkInterfaceEgress))
                    .accessibilityLabel(L10n.text(.networkInterfaceEgress))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .fixedSize()
    }
}
