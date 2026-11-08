import AppKit
import SwiftUI

/// §17.7 Düzelt sayfası: IP ban (onaylı akış), CID ban (itiraz), erişilemiyor (yeniden kontrol).
struct FixSheet: View {
    @Bindable var model: AppModel
    let initialSession: AppModel.FixSession

    @State private var copied = false

    /// Güncel oturum (sheet açıkken model değişir).
    private var session: AppModel.FixSession { model.fixSession ?? initialSession }

    private var entry: ServerEntry? { model.servers.first { $0.id == session.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch session.kind {
            case .ipBan: ipBanContent
            case .cidBan: cidBanContent
            case .unreachable: unreachableContent
            }
            if let note = session.note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 640)
        .interactiveDismissDisabled(model.isFixRunning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.bold())
            if let entry {
                Text("\(entry.label) · \(entry.host):\(String(entry.port))")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch session.kind {
        case .ipBan: return "IP banını düzelt"
        case .cidBan: return "CID banı"
        case .unreachable: return "Sunucuya erişilemiyor"
        }
    }

    // MARK: IP ban (§17.2)

    @ViewBuilder
    private var ipBanContent: some View {
        switch session.phase {
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Mevcut genel IP") {
                    Text(model.publicIP ?? "—").font(.body.monospaced())
                }
                Text("Yapılacaklar").font(.headline)
                numbered([
                    "Mevcut genel IP kaydedilir.",
                    "Varsayılan ağ arayüzü bulunur (route get default).",
                    "Wi-Fi ise Wi-Fi 3 sn kapatılıp açılır; Ethernet ise DHCP yenilenir (macOS yönetici onayı ister).",
                    "Ağ en çok 45 sn beklenir; yeni genel IP alınır.",
                    "IP değiştiyse bu sunucu için ban yeniden kontrol edilir.",
                ])
                Text("Tahmini kesinti: 5–20 sn.").font(.callout)
                Text("Risk: IP değişimi garanti değildir; ISS statik IP, CGNAT veya router PPPoE oturumu IP'yi koruyabilir. Kesinti sırasında diğer bağlantılar kopabilir. Yönetici parolası yalnız macOS diyaloğunda istenir; uygulama parolayı görmez ve saklamaz.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Vazgeç", role: .cancel) { model.fixSession = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Başlat") { model.startIPFix() }
                    .keyboardShortcut(.defaultAction)
            }
        case .running(let progress):
            runningView(progress, cancellable: true)
        case .finished(let outcome, let at):
            ipResult(outcome, at: at)
        }
    }

    @ViewBuilder
    private func ipResult(_ outcome: IPFixOutcome, at date: Date) -> some View {
        Text("\(outcome.message) · \(TimeText.format(date))")
            .foregroundStyle(outcome.isSuccess ? Color.green : Color.red)
            .fixedSize(horizontal: false, vertical: true)
        switch outcome {
        case .ipUnchanged(_, let routerURL):
            numbered(IPFixOutcome.unchangedNextSteps)
            HStack {
                if let routerURL {
                    Button("Router arayüzünü aç") { NSWorkspace.shared.open(routerURL) }
                }
                Spacer()
                retryAndClose
            }
        case .rangeBanned:
            Text("Öneriler").font(.headline)
            numbered(IPFixOutcome.rangeBannedSuggestions)
            HStack {
                appealButtons
                Spacer()
                retryAndClose
            }
        case .stillBanned:
            Text(IPFixOutcome.outOfRangeText).fixedSize(horizontal: false, vertical: true)
            Text("Olası nedenler").font(.headline)
            numbered(IPFixOutcome.stillBannedReasons)
            HStack {
                appealButtons
                Spacer()
                retryAndClose
            }
        default:
            HStack {
                serverPageButton
                Spacer()
                retryAndClose
            }
        }
    }

    private var retryAndClose: some View {
        HStack {
            Button("Yeniden dene") {
                model.fixSession?.phase = .ready
                model.fixSession?.note = nil
            }
            Button("Kapat") { model.fixSession = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: CID ban (§17.3)

    @ViewBuilder
    private var cidBanContent: some View {
        Text("CID banı yerel olarak kaldırılamaz; ban sunucu tarafındadır. Yöneticinin doğru sistemi temizlemesi için aşağıdaki itiraz metnini gönderin.")
            .fixedSize(horizontal: false, vertical: true)
        if let text = model.appealText(for: session.id) {
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
        if case .running(let progress) = session.phase {
            runningView(progress, cancellable: false)
        }
        HStack {
            appealButtons
            Button("Yeniden kontrol et") { model.recheckServer(session.id) }
                .disabled(model.isFixRunning)
            Spacer()
            Button("Kapat") { model.fixSession = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Erişilemiyor (§17.4)

    @ViewBuilder
    private var unreachableContent: some View {
        Text(MessageCode.unreachable.text)
        if case .running(let progress) = session.phase {
            runningView(progress, cancellable: false)
        }
        HStack {
            Button("Yeniden kontrol et") { model.recheckServer(session.id) }
                .disabled(model.isFixRunning)
            serverPageButton
            Spacer()
            Button("Kapat") { model.fixSession = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Ortak

    private var appealButtons: some View {
        HStack {
            Button(copied ? "Kopyalandı" : "Unban mesajını kopyala") {
                if let text = model.appealText(for: session.id) {
                    Pasteboard.copy(text)
                    copied = true
                }
            }
            serverPageButton
        }
    }

    @ViewBuilder
    private var serverPageButton: some View {
        if let url = model.serverPageURL(for: session.id) {
            Button("Sunucu sayfasını aç") { NSWorkspace.shared.open(url) }
                .help("Yöneticiye ulaş: \(url.absoluteString)")
        }
    }

    private func runningView(_ progress: FixProgress, cancellable: Bool) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(progress.text)
            Spacer()
            if cancellable {
                Button("İptal") { model.cancelFix() }
            }
        }
    }

    private func numbered(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Text("\(index + 1). \(item)")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
