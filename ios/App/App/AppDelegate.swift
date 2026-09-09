import UIKit
import AVFoundation
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        configureAudioSession()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(audioRouteChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(audioServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            NSLog("Aeon audio session configuration failed: %@", error.localizedDescription)
        }
    }

    private func notifyPlayer(_ event: String) {
        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.window?.rootViewController as? CAPBridgeViewController else { return }
            controller.webView?.evaluateJavaScript("window.dispatchEvent(new Event('\(event)'))", completionHandler: nil)
        }
    }

    @objc private func audioInterrupted(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        notifyPlayer("aeon-interruption")
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        // Disconnecting headphones must not unexpectedly move music to the speaker.
        notifyPlayer("aeon-interruption")
    }

    @objc private func audioServicesReset() {
        configureAudioSession()
        notifyPlayer("aeon-media-reset")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard let controller = window?.rootViewController as? CAPBridgeViewController else { return }
        controller.webView?.evaluateJavaScript("typeof audio !== 'undefined' && !audio.paused") { [weak self] result, _ in
            guard let playing = result as? Bool, playing else { return }
            let session = AVAudioSession.sharedInstance()
            if session.isOtherAudioPlaying {
                self?.notifyPlayer("aeon-interruption")
                return
            }
            do {
                try session.setActive(true)
                self?.notifyPlayer("aeon-foreground")
            } catch {
                self?.notifyPlayer("aeon-interruption")
                NSLog("Aeon audio session activation failed: %@", error.localizedDescription)
            }
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

}
