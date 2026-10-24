import AppKit

// App de barre de menu (LSUIElement) : pas d'icône dans le Dock.
let application = NSApplication.shared
let arguments = CommandLine.arguments
let delegate: NSApplicationDelegate = arguments.contains("--hud-demo") ? HUDDemo()
    : arguments.contains("--about-demo") ? AboutDemo()
    : arguments.contains("--snapshots") ? SnapshotDemo() : AppController()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
