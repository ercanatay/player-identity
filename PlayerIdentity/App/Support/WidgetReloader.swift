import WidgetKit

/// §69.2: the widget reads `widget-snapshot.json`; after a write the app asks WidgetKit to reload its timelines.
struct WidgetCenterReloader: WidgetReloading {
    init() {}

    func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
