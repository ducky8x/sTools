import STDesign
import STPlatform
import SwiftUI

extension AppModel {
    /// Applies `change` to the appearance settings, updates the live theme at once and saves (debounced).
    func updateAppearance(_ change: (inout AppearanceSettings) -> Void) {
        var next = appearance
        change(&next)
        next.apply(to: theme)
        appearance = AppearanceSettings(theme: theme)
        settings.save(appearance)
    }

    /// Reads `appearance.json` again and shows it at once: after an import, Reduce animations and the rest of
    /// Appearance apply without a relaunch, and a later change can't write the old values back over the file.
    func reloadAppearance() {
        settings.load(AppearanceSettings.self).apply(to: theme)
        appearance = AppearanceSettings(theme: theme)
    }

    func appearanceBinding<Value>(_ keyPath: WritableKeyPath<AppearanceSettings, Value>) -> Binding<Value> {
        Binding(get: { self.appearance[keyPath: keyPath] },
                set: { value in self.updateAppearance { $0[keyPath: keyPath] = value } })
    }

    /// A 0-100 binding over a 0-1 setting, for the percent sliders.
    func percentBinding(_ keyPath: WritableKeyPath<AppearanceSettings, Double>) -> Binding<Double> {
        Binding(get: { self.appearance[keyPath: keyPath] * 100 },
                set: { value in self.updateAppearance { $0[keyPath: keyPath] = value / 100 } })
    }
}
