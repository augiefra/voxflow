import AppKit

/// Fenêtre « À propos » : version, copyright (Info.plist) et crédits des moteurs.
enum AboutPanel {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: """
            Dictée vocale 100 % locale, sur ce Mac.

            Voxtral Mini 4B Realtime, Mistral AI
            Qwen2.5-Coder 7B Instruct, Alibaba Cloud
            Licence Apache 2.0, exécutés par MLX
            Mises à jour : Sparkle

            Détail : menu « Licences tierces… »
            """,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// VoxFlow --about-demo : affiche seulement la fenêtre « À propos » (contrôle visuel).
final class AboutDemo: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AboutPanel.show()
    }
}
