// Copyright 2015-present 650 Industries. All rights reserved.

import EXDevMenuInterface

class DevMenuBridgeProxyDelegate : DevMenuDelegateProtocol {
  private let bridge: RCTBridge
  
  init(_ bridge: RCTBridge) {
    self.bridge = bridge
  }
  
  public func appBridge(forDevMenuManager manager: DevMenuManagerProtocol) -> AnyObject? {
    return self.bridge;
  }
}

class Dispatch {
  static func mainSync<T>(_ closure: () -> T) -> T {
    if Thread.isMainThread {
      return closure()
    } else {
      var result: T?
      DispatchQueue.main.sync {
        result = closure()
      }
      return result!
    }
  }
}

/**
 A container for dev menu screens array.
 NSMapTable requires the second generic type to be a class, so `[DevMenuScreen]` is not allowed.
 */
class DevMenuScreensContainer {
  fileprivate let screens: [DevMenuScreen]

  fileprivate init(screens: [DevMenuScreen]) {
    self.screens = screens
  }
}

/**
 A hash map storing an array of dev menu items for specific extension.
 */
private let extensionToDevMenuItemsMap = NSMapTable<DevMenuExtensionProtocol, DevMenuItemsContainerProtocol>.weakToStrongObjects()

/**
 A hash map storing an array of dev menu screens for specific extension.
 */
private let extensionToDevMenuScreensMap = NSMapTable<DevMenuExtensionProtocol, DevMenuScreensContainer>.weakToStrongObjects()

/**
 Manages the dev menu and provides most of the public API.
 */
@objc
open class DevMenuManager: NSObject, DevMenuManagerProtocol {
  lazy var expoSessionDelegate: DevMenuExpoSessionDelegate = DevMenuExpoSessionDelegate(manager: self)
  lazy var extensionSettings: DevMenuExtensionSettingsProtocol = DevMenuExtensionDefaultSettings(manager: self)
  
  public var expoApiClient: DevMenuExpoApiClientProtocol = DevMenuExpoApiClient()
  
  /**
   Shared singleton instance.
   */
  @objc
  static public let shared = DevMenuManager()

  /**
   The window that controls and displays the dev menu view.
   */
  var window: DevMenuWindow?

  /**
   `DevMenuAppInstance` instance that is responsible for initializing and managing React Native context for the dev menu.
   */
  lazy var appInstance: DevMenuAppInstance = DevMenuAppInstance(manager: self)

  /**
   Instance of `DevMenuSession` that keeps the details of the currently opened dev menu session.
   */
  public private(set) var session: DevMenuSession?

  var currentScreen: String?
  
  /**
   The delegate of `DevMenuManager` implementing `DevMenuDelegateProtocol`.
   */
  @objc
  public var delegate: DevMenuDelegateProtocol? {
    didSet {
      guard DevMenuSettings.showsAtLaunch || !DevMenuSettings.isOnboardingFinished, let bridge = delegate?.appBridge?(forDevMenuManager: self) as? RCTBridge else {
        return
      }
      if bridge.isLoading {
        NotificationCenter.default.addObserver(self, selector: #selector(DevMenuManager.autoLaunch), name: DevMenuViewController.ContentDidAppearNotification, object: nil)
      } else {
        autoLaunch()
      }
    }
  }
  
  @objc
  public static func configure(withBridge bridge: AnyObject) {
    if let bridge = bridge as? RCTBridge {
      shared.delegate = DevMenuBridgeProxyDelegate(bridge)
    } else {
      fatalError("Cound't cast to RCTBrigde. Make sure that you passed `RCTBridge` to `DevMenuManager.initializeWithBridge`.")
    }
  }

  @objc
  public func autoLaunch(_ shouldRemoveObserver: Bool = true) {
    NotificationCenter.default.removeObserver(self)
  
    DispatchQueue.main.async {
      self.openMenu()
    }
  }

  override init() {
    super.init()
    self.window = DevMenuWindow(manager: self)
    
    DevMenuSettings.setup()
    self.expoSessionDelegate.restoreSession()
  }

  /**
   Whether the dev menu window is visible on the device screen.
   */
  @objc
  public var isVisible: Bool {
    return Dispatch.mainSync { !(window?.isHidden ?? true) }
  }

  /**
   Opens up the dev menu.
   */
  @objc
  @discardableResult
  public func openMenu(_ screen: String? = nil) -> Bool {
    return setVisibility(true, screen: screen)
  }
  
  @objc
  @discardableResult
  public func openMenu() -> Bool {
    return openMenu(nil)
  }

  /**
   Sends an event to JS to start collapsing the dev menu bottom sheet.
   */
  @objc
  @discardableResult
  public func closeMenu() -> Bool {
    if (isVisible) {
      appInstance.sendCloseEvent()
      return true
    }
    
    return false
  }

  /**
   Forces the dev menu to hide. Called by JS once collapsing the bottom sheet finishes.
   */
  @objc
  @discardableResult
  public func hideMenu() -> Bool {
    return setVisibility(false)
  }

  /**
   Toggles the visibility of the dev menu.
   */
  @objc
  @discardableResult
  public func toggleMenu() -> Bool {
    return isVisible ? closeMenu() : openMenu()
  }
  
  @objc
  public func setCurrentScreen(_ screenName: String?) {
    currentScreen = screenName
  }
  
  @objc
  public func sendEventToDelegateBridge(_ eventName: String, data: Any?) {
    guard let bridge = delegate?.appBridge?(forDevMenuManager: self) as? RCTBridge else {
      return;
    }
    
    bridge.enqueueJSCall("RCTDeviceEventEmitter.emit", args: [eventName, data])
  }

  // MARK: internals

  func dispatchAction(withId actionId: String) {
    for action in devMenuActions {
      if (action.actionId == actionId) {
        if delegate?.devMenuManager?(self, willDispatchAction: action) ?? true {
          action.action()
        }
        
        return
      }
    }
  }

  /**
   Returns an array of modules conforming to `DevMenuExtensionProtocol`.
   Bridge may register multiple modules with the same name – in this case it returns only the one that overrides the others.
   */
  var extensions: [DevMenuExtensionProtocol]? {
    guard let bridge = session?.bridge else {
      return nil
    }
    let allExtensions = bridge.modulesConforming(to: DevMenuExtensionProtocol.self) as! [DevMenuExtensionProtocol]
    let uniqueExtensionNames: [String] = Array(Set(allExtensions.map({ type(of: $0).moduleName() })))

    return uniqueExtensionNames
      .map({ bridge.module(forName: DevMenuUtils.stripRCT($0)) })
      .filter({ $0 is DevMenuExtensionProtocol }) as! [DevMenuExtensionProtocol]
  }

  /**
   Gathers `DevMenuItem`s from all dev menu extensions and returns them as an array.
   */
  var devMenuItems: [DevMenuScreenItem] {
    return extensions?.map { loadDevMenuItems(forExtension: $0)?.getAllItems() ?? [] }.flatMap { $0 } ?? []
  }
  
  /**
   Gathers root `DevMenuItem`s (elements on the main screen) from all dev menu extensions and returns them as an array.
   */
  var devMenuRootItems: [DevMenuScreenItem] {
    return extensions?.map { loadDevMenuItems(forExtension: $0)?.getRootItems() ?? [] }.flatMap { $0 } ?? []
  }
  
  /**
   Gathers `DevMenuScreen`s from all dev menu extensions and returns them as an array.
   */
  var devMenuScreens: [DevMenuScreen] {
    return extensions?.map { loadDevMenuScreens(forExtension: $0) ?? [] }.flatMap {$0} ?? []
  }
  
  /**
   Returns an array of `DevMenuAction`s returned by the dev menu extensions.
   */
  var devMenuActions: [DevMenuAction] {
    if currentScreen == nil {
      return devMenuItems.filter { $0 is DevMenuAction } as! [DevMenuAction]
    }
    
    return (devMenuScreens.first { $0.screenName == currentScreen }?.getAllItems() ?? [])
      .filter { $0 is DevMenuAction } as! [DevMenuAction]
  }

  /**
   Returns an array of dev menu items serialized to the dictionary.
   */
  func serializedDevMenuItems() -> [[String : Any]] {
    return devMenuRootItems
      .sorted(by: { $0.importance > $1.importance })
      .map({ $0.serialize() })
  }
  
  /**
   Returns an array of dev menu screens serialized to the dictionary.
   */
  func serializedDevMenuScreens() -> [[String : Any]] {
    return devMenuScreens
      .map({ $0.serialize() })
  }

  // MARK: delegate stubs

  /**
   Returns a bool value whether the dev menu can change its visibility.
   Returning `false` entirely disables the dev menu.
   */
  func canChangeVisibility(to visible: Bool) -> Bool {
    if isVisible == visible {
      return false
    }
    return delegate?.devMenuManager?(self, canChangeVisibility: visible) ?? true
  }

  /**
   Returns bool value whether the onboarding view should be displayed by the dev menu view.
   */
  func shouldShowOnboarding() -> Bool {
    return delegate?.shouldShowOnboarding?(manager: self) ?? !DevMenuSettings.isOnboardingFinished
  }

  @available(iOS 12.0, *)
  var userInterfaceStyle: UIUserInterfaceStyle {
    return delegate?.userInterfaceStyle?(forDevMenuManager: self) ?? UIUserInterfaceStyle.unspecified
  }

  // MARK: private

  private func loadDevMenuItems(forExtension ext: DevMenuExtensionProtocol) -> DevMenuItemsContainerProtocol? {
    if let itemsContainer = extensionToDevMenuItemsMap.object(forKey: ext) {
      return itemsContainer
    }
    
    if let itemsContainer = ext.devMenuItems?(extensionSettings) {
      extensionToDevMenuItemsMap.setObject(itemsContainer, forKey: ext)
      return itemsContainer
    }
    
    return nil
  }
  
  private func loadDevMenuScreens(forExtension ext: DevMenuExtensionProtocol) -> [DevMenuScreen]? {
    if let screenContainer = extensionToDevMenuScreensMap.object(forKey: ext) {
      return screenContainer.screens
    }
    
    if let screens = ext.devMenuScreens?(extensionSettings) {
      let container = DevMenuScreensContainer(screens: screens)
      extensionToDevMenuScreensMap.setObject(container, forKey: ext)
      return screens
    }
    
    return nil;
  }

  private func setVisibility(_ visible: Bool, screen: String? = nil) -> Bool {
    if !canChangeVisibility(to: visible) {
      return false
    }
    if visible {
      guard let bridge = delegate?.appBridge?(forDevMenuManager: self) as? RCTBridge else {
        debugPrint("DevMenuManager: The delegate is unset or it didn't provide a bridge to render for.")
        return false
      }
      session = DevMenuSession(bridge: bridge, appInfo: delegate?.appInfo?(forDevMenuManager: self), screen: screen)
      DispatchQueue.main.async { self.window?.makeKeyAndVisible() }
    } else {
      session = nil
      DispatchQueue.main.async { self.window?.isHidden = true }
    }
    return true
  }
}
