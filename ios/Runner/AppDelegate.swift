import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    application.registerForRemoteNotifications()
    GeneratedPluginRegistrant.register(with: self)

    // Register the NDR FFI plugin for native Rust bindings
    NdrFfiPlugin.register(with: self.registrar(forPlugin: "NdrFfiPlugin")!)
    HashtreePlugin.register(with: self.registrar(forPlugin: "HashtreePlugin")!)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
