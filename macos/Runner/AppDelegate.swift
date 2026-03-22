import Cocoa
import FlutterMacOS
import LaunchAtLogin

extension LaunchAtLogin {
  static var wasLaunchedAtLogin: Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent else {
      return false
    }

    return event.eventID == kAEOpenApplication &&
      event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue ==
        keyAELaunchedAsLogInItem
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private func activateExistingInstanceIfNeeded() -> Bool {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
      return false
    }

    let currentPid = ProcessInfo.processInfo.processIdentifier
    guard
      let existingInstance = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleIdentifier)
        .first(where: { $0.processIdentifier != currentPid })
    else {
      return false
    }

    existingInstance.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    DispatchQueue.main.async {
      NSApp.terminate(nil)
    }
    return true
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if activateExistingInstanceIfNeeded() {
      return
    }

    let launchedAtLogin = LaunchAtLogin.wasLaunchedAtLogin
    let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
    let registrar = controller.registrar(forPlugin: "NdrFfiPlugin")
    NdrFfiPlugin.register(with: registrar)
    let hashtreeRegistrar = controller.registrar(forPlugin: "HashtreePlugin")
    HashtreePlugin.register(with: hashtreeRegistrar)

    if launchedAtLogin {
      DispatchQueue.main.async {
        self.mainFlutterWindow?.miniaturize(nil)
      }
    }
  }
}
