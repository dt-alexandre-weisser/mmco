import Cocoa

// Chrome starts the native-messaging host with the extension origin as its first argument.
let launchArguments = Array(CommandLine.arguments.dropFirst())
if launchArguments.first?.hasPrefix("chrome-extension://") == true || launchArguments.contains("--native-host") {
    NativeHost().run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
