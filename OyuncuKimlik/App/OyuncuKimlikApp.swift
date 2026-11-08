import SwiftUI

@main
struct OyuncuKimlikApp: App {
    var body: some Scene {
        WindowGroup("Oyuncu Kimlik Kartı") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}

/// İskelet pencere; asıl arayüz parça 2'de.
struct ContentView: View {
    var body: some View {
        Text("Hazır")
            .font(.title)
            .frame(minWidth: 720, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }
}
