import AppKit
import SwiftUI

@main
struct OyuncuKimlikApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Oyuncu Kimlik Kartı", id: "main") {
            ContentView(model: appDelegate.model)
        }
        .defaultSize(width: 900, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            // §6: Yenile düğmesi yenileme sırasında devre dışıdır; ⌘R ise her zaman çalışır ve
            // yenileme sürerken basılırsa önceki iptal edilir, en son istek kazanır.
            CommandGroup(before: .toolbar) {
                Button("Yenile") { appDelegate.model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Kaydet") { appDelegate.model.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}

/// Kapanışta kaydedilmemiş değişiklik onayı (§8).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel(dependencies: .live())

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Kaydetmeden çık?"
        alert.informativeText = "Kaydedilmemiş değişiklikler kaybolacak."
        alert.addButton(withTitle: "Kaydetmeden Çık")
        alert.addButton(withTitle: "Vazgeç")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
