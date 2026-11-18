import SwiftUI

// MARK: - §69.1 Ban expiry notifications

/// Under the ban record of a timed ban: the "Notify When It Ends" switch (on by default), the planned times and the
/// "only while the app runs" limit.
struct BanExpiryControls: View {
    @Bindable var model: AppModel
    let serverID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(L10n.text(.banExpiryNotifyToggle), isOn: Binding(
                get: { model.isBanExpiryNotifyOn(for: serverID) },
                set: { model.setBanExpiryNotify($0, for: serverID) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption.weight(.medium))
                .accessibilityIdentifier("banExpiryNotify")
            if model.isBanExpiryNotifyOn(for: serverID),
               let line = BanExpiryText.scheduled(model.plannedBanExpiries(for: serverID)) {
                Label(line, systemImage: "bell.badge")
                    .font(.caption)
                    .foregroundStyle(Palette.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("banExpiryScheduled")
            }
            Text(L10n.text(.banExpiryLimitNote))
                .font(.caption2)
                .foregroundStyle(Palette.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("banExpiryControls")
    }
}

/// Main window row: "Upcoming ban expiries" (timed bans ending within a day, soonest first).
struct UpcomingBanExpiriesRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: "hourglass")
                .font(.title3)
                .foregroundStyle(Palette.orangeText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(.banExpiryUpcomingTitle))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.text2)
                ForEach(model.upcomingBanExpiryLines, id: \.self) { line in
                    Text(verbatim: line)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.orangeTint))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Palette.border))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("upcomingBanExpiries")
    }
}
