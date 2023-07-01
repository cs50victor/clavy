import AppKit
import Carbon

// TODO: Use Apple unified logging to replace `print`s: https://github.com/chrisaljoudi/swift-log-oslog

// TODO: Add CLI interface: launch (normal), --(un)?install-service, --(start|stop|restart)-service

// TODO: Handle spotlight: https://stackoverflow.com/questions/36264038/cocoa-programmatically-detect-frontmost-floating-windows

let suiteName = "io.github.rami3l.Claveilleur"
let userDefaults = UserDefaults(suiteName: suiteName)!

func saveInputSource(_ id: String, forApp appID: String) {
  userDefaults.set(id, forKey: appID)
}

// https://github.com/mzp/EmojiIM/issues/27#issue-1361876711
func getInputSource() -> String {
  let inputSource = TISCopyCurrentKeyboardInputSource().takeUnretainedValue()
  return unsafeBitCast(
    TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID),
    to: NSString.self
  ) as String
}

// https://github.com/daipeihust/im-select/blob/83046bb75333e58c9a7cbfbd055db6f360361781/macOS/im-select/im-select/main.m
func setInputSource(to id: String) -> Bool {
  if getInputSource() == id {
    return true
  }
  print("Restoring input source to: \(id)")
  let filter = [kTISPropertyInputSourceID!: id] as NSDictionary
  let inputSources =
    TISCreateInputSourceList(filter, false).takeUnretainedValue()
    as NSArray as! [TISInputSource]
  guard !inputSources.isEmpty else {
    return false
  }
  let inputSource = inputSources[0]
  TISSelectInputSource(inputSource)
  return true
}

let currentInputSourceObserver = NotificationCenter
  .default
  .publisher(for: NSTextInputContext.keyboardSelectionDidChangeNotification)
  .map { _ in getInputSource() }
  .removeDuplicates()
  .sink { inputSource in
    guard let currentApp = getCurrentAppBundleID() else {
      return
    }

    print("Switching to input source: \(inputSource)")
    saveInputSource(inputSource, forApp: currentApp)
  }

// TODO: Listen for `NSAccessibilityFocusedWindowChangedNotification` for each pid
// https://developer.apple.com/documentation/appkit/nsaccessibilityfocusedwindowchangednotification
class RunningAppsObserver: NSObject {
  @objc var currentWorkSpace: NSWorkspace
  var observation: NSKeyValueObservation?

  var windowChangeObservers = [pid_t: WindowChangeObserver]()

  convenience override init() {
    self.init(workspace: NSWorkspace.shared)
  }

  init(workspace: NSWorkspace) {
    currentWorkSpace = workspace
    windowChangeObservers = Self.getWindowChangeObservers(for: currentWorkSpace.runningApplications)
    super.init()

    observation = currentWorkSpace.observe(
      \.runningApplications,
      options: [.new]
    ) { _, _ in
      // TODO: Should not recreate necessary observers.
      let oldKeys = Set(self.windowChangeObservers.keys)
      let newKeys = Set(self.currentWorkSpace.runningApplications.map { $0.processIdentifier })
      let toRemove = oldKeys.subtracting(newKeys)
      for key in toRemove {
        self.windowChangeObservers.removeValue(forKey: key)
      }
      let toAdd = newKeys.subtracting(oldKeys)
      for key in toAdd {
        self.windowChangeObservers[key] = WindowChangeObserver(pid: key)
      }
    }
  }

  static func getWindowChangeObservers(
    for runningApps: [NSRunningApplication]
  ) -> [pid_t: WindowChangeObserver] {
    // https://apple.stackexchange.com/a/317705
    // https://gist.github.com/ljos/3040846
    // https://stackoverflow.com/a/61688877
    // let onScreenAppPIDs =
    //   (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)!
    //   as Array)
    //   .compactMap { $0.object(forKey: kCGWindowOwnerPID) as? pid_t }

    return Dictionary(
      uniqueKeysWithValues:
        runningApps
        .map { $0.processIdentifier }
        // .filter { onScreenAppPIDs.contains($0) }
        .map { ($0, WindowChangeObserver(pid: $0)) }
    )
  }
}

// https://stackoverflow.com/a/38928864
let focusedWindowChangedNotification =
  Notification.Name("claveilleur-focused-window-changed")

let currentAppObserver = NSWorkspace
  .shared
  .notificationCenter
  .publisher(for: Claveilleur.focusedWindowChangedNotification)
  .map { getAppBundleID(forPID: $0.object as! pid_t) }
  .merge(
    with: NSWorkspace
      .shared
      .notificationCenter
      .publisher(
        for: NSWorkspace.didActivateApplicationNotification
      )
      .map { notif in
        let userInfo =
          notif.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication
        return userInfo?.bundleIdentifier
      }
  )
  .removeDuplicates()
  .sink { currentApp in
    print("ping from \(currentApp)")
    // TODO: Should fix spotlight desactivation not detected.

    // print("Switching to app: \(currentApp)")
    // guard
    //   let oldInputSource = userDefaults.string(forKey: currentApp),
    //   setInputSource(to: oldInputSource)
    // else {
    //   let newInputSource = getInputSource()
    //   saveInputSource(newInputSource, forApp: currentApp)
    //   return
    // }
  }

enum AXUIError: Error {
  case axError(String)
  case typeCastError(String)
}

extension AXUIElement {
  func getValue<T>(forKey key: String) throws -> T {
    var res: AnyObject?
    let axResult = AXUIElementCopyAttributeValue(self, key as CFString, &res)
    guard case .success = axResult else {
      throw AXUIError.axError("AXUI function failed with `\(axResult)`")
    }
    guard let res = res as? T else {
      throw AXUIError.typeCastError("downcast failed from `\(type(of: res))` to `\(T.self)`")
    }
    return res
  }
}

func getCurrentAppPID() throws -> pid_t {
  let currentApp: AXUIElement = try AXUIElementCreateSystemWide().getValue(
    forKey: kAXFocusedApplicationAttribute
  )
  var res: pid_t = 0
  let axResult = AXUIElementGetPid(currentApp, &res)
  guard case .success = axResult else {
    throw AXUIError.axError("AXUI function failed with `\(axResult)`")
  }
  return res
}

private func getAppBundleID(forPID pid: pid_t) -> String? {
  let currentApp = NSWorkspace.shared.runningApplications.first {
    $0.processIdentifier == pid
  }
  return currentApp?.bundleIdentifier
}

func getCurrentAppBundleID() -> String? {
  guard let currentAppPID = try? getCurrentAppPID() else {
    return nil
  }
  return getAppBundleID(forPID: currentAppPID)
}

// https://juejin.cn/post/6919716600543182855
class WindowChangeObserver: NSObject {
  var currentAppPID: pid_t
  var element: AXUIElement
  var rawObserver: AXObserver?

  let notifNames =
    [
      kAXFocusedWindowChangedNotification
      // kAXFocusedUIElementChangedNotification
    ] as [CFString]

  let observerCallbackWithInfo: AXObserverCallbackWithInfo = {
    (observer, element, notification, userInfo, refcon) in
    guard let refcon = refcon else {
      return
    }
    let slf = Unmanaged<WindowChangeObserver>.fromOpaque(refcon).takeUnretainedValue()
    print("should ping from \(slf.currentAppPID)")
    NSWorkspace.shared.notificationCenter.post(
      name: Claveilleur.focusedWindowChangedNotification,
      object: slf.currentAppPID
    )
  }

  init(pid: pid_t) {
    currentAppPID = pid
    element = AXUIElementCreateApplication(currentAppPID)
    super.init()

    AXObserverCreateWithInfoCallback(currentAppPID, observerCallbackWithInfo, &rawObserver)

    let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    notifNames.forEach {
      AXObserverAddNotification(rawObserver!, element, $0, selfPtr)
    }
    CFRunLoopAddSource(
      CFRunLoopGetCurrent(),
      AXObserverGetRunLoopSource(rawObserver!),
      CFRunLoopMode.defaultMode
    )

    print("WindowChangeObserver pid: \(pid)")
  }

  deinit {
    CFRunLoopRemoveSource(
      CFRunLoopGetCurrent(),
      AXObserverGetRunLoopSource(rawObserver!),
      CFRunLoopMode.defaultMode
    )
    notifNames.forEach {
      AXObserverRemoveNotification(rawObserver!, element, $0)
    }
  }
}

let runningAppsObserver = RunningAppsObserver()
// let foo = WindowChangeObserver(pid: 548)

CFRunLoopRun()