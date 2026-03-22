import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let mobilePushChannelName = "to.iris/mobile_push"
  private var mobilePushChannel: FlutterMethodChannel?
  private var pendingRemoteNotificationPayloads: [[String: String]] = []
  private var isMobilePushDartReady = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    application.registerForRemoteNotifications()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    mobilePushChannel = FlutterMethodChannel(
      name: mobilePushChannelName,
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    mobilePushChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "UNAVAILABLE", message: "AppDelegate deallocated", details: nil))
        return
      }

      switch call.method {
      case "setDartReady":
        self.isMobilePushDartReady = true
        let pending = self.pendingRemoteNotificationPayloads
        self.pendingRemoteNotificationPayloads.removeAll()
        result(pending)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NdrFfiPlugin") {
      NdrFfiPlugin.register(with: registrar)
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HashtreePlugin") {
      HashtreePlugin.register(with: registrar)
    }
  }

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    handleRemoteNotification(userInfo)
    completionHandler(.newData)
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    handleRemoteNotification(notification.request.content.userInfo)
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .badge, .sound])
    } else {
      completionHandler([.alert, .badge, .sound])
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    handleRemoteNotification(response.notification.request.content.userInfo)
    completionHandler()
  }

  private func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
    let payload = normalizeRemoteNotificationPayload(userInfo)
    guard !payload.isEmpty else {
      return
    }

    if isMobilePushDartReady, let mobilePushChannel {
      mobilePushChannel.invokeMethod("remoteNotification", arguments: payload)
      return
    }

    pendingRemoteNotificationPayloads.append(payload)
  }

  private func normalizeRemoteNotificationPayload(_ userInfo: [AnyHashable: Any]) -> [String: String] {
    var payload: [String: String] = [:]

    for (rawKey, rawValue) in userInfo {
      let key = String(describing: rawKey)
      guard let value = stringifyRemoteNotificationValue(rawValue) else {
        continue
      }
      payload[key] = value
    }

    return payload
  }

  private func stringifyRemoteNotificationValue(_ value: Any) -> String? {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      return number.stringValue
    case let dictionary as [AnyHashable: Any]:
      let normalized = dictionary.reduce(into: [String: Any]()) { partialResult, entry in
        partialResult[String(describing: entry.key)] = entry.value
      }
      guard JSONSerialization.isValidJSONObject(normalized),
            let data = try? JSONSerialization.data(withJSONObject: normalized),
            let string = String(data: data, encoding: .utf8)
      else {
        return String(describing: value)
      }
      return string
    case let array as [Any]:
      guard JSONSerialization.isValidJSONObject(array),
            let data = try? JSONSerialization.data(withJSONObject: array),
            let string = String(data: data, encoding: .utf8)
      else {
        return String(describing: value)
      }
      return string
    default:
      return String(describing: value)
    }
  }
}
