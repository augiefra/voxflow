import Foundation

/// Textes de l'interface, en français ou en anglais selon la langue du Mac.
///
/// Les tables sont dans Resources/{en,fr}.lproj, copiées dans l'app par build_app.sh.
/// Ne pas déclarer de `resources:` dans Package.swift : SwiftPM créerait un bundle à part
/// que l'app distribuée n'embarque pas. Lancé hors de l'app (`swift run`, tests),
/// l'interface affiche les clés brutes.
public enum L10n {
    public static func tr(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: args)
    }

    /// « 3,1 Go » / « 3.1 GB » (unités décimales, comme le Finder).
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Mémoire vive en unités binaires : « 24 Go » comme dans « À propos de ce Mac ».
    public static func memory(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }
}
