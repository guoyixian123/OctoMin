import SwiftUI
import AppKit

@main
struct MyCompressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup("MyCompress") {
            ContentView()
                .frame(minWidth: 480, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        
        if let window = NSApp.windows.first {
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.title = "MyCompress"
            
            if let appIcon = NSImage(contentsOfFile: Bundle.main.path(forResource: "AppIcon", ofType: "icns") ?? "") {
                window.appearance = NSAppearance(named: .aqua)
                NSApp.applicationIconImage = appIcon
            }
        }
    }
}
