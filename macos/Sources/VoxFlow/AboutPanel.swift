import AppKit
import VoxFlowCore

/// Fenêtre « À propos » : version, copyright (Info.plist) et crédits des moteurs.
enum AboutPanel {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: L10n.tr("about.credits"),
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
