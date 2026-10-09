import AppKit

// Plain AppKit lifecycle. Everything user-facing is AppKit-hosted SwiftUI (the
// menu panel, the settings window); a SwiftUI Scene would add nothing but an
// unreachable Cmd+, entry — an accessory app has no menu bar for SwiftUI to
// hang it on. Key equivalents live in the main menu built by AppDelegate.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
