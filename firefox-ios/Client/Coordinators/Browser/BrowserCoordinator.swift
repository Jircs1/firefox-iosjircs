// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import WebKit
import Shared
import Storage
import Redux
import TabDataStore

class BrowserCoordinator: BaseCoordinator,
                          LaunchCoordinatorDelegate,
                          BrowserDelegate,
                          SettingsCoordinatorDelegate,
                          BrowserNavigationHandler,
                          LibraryCoordinatorDelegate,
                          EnhancedTrackingProtectionCoordinatorDelegate,
                          FakespotCoordinatorDelegate,
                          ParentCoordinatorDelegate,
                          TabManagerDelegate,
                          TabTrayCoordinatorDelegate,
                          PrivateHomepageDelegate,
                          WindowEventCoordinator {
    var browserViewController: BrowserViewController
    var webviewController: WebviewViewController?
    var homepageViewController: HomepageViewController?
    var privateViewController: PrivateHomepageViewController?

    private var profile: Profile
    private let tabManager: TabManager
    private let themeManager: ThemeManager
    private let windowManager: WindowManager
    private let screenshotService: ScreenshotService
    private let glean: GleanWrapper
    private let applicationHelper: ApplicationHelper
    private var browserIsReady = false
    private var windowUUID: WindowUUID { return tabManager.windowUUID }

    init(router: Router,
         screenshotService: ScreenshotService,
         tabManager: TabManager,
         profile: Profile = AppContainer.shared.resolve(),
         themeManager: ThemeManager = AppContainer.shared.resolve(),
         windowManager: WindowManager = AppContainer.shared.resolve(),
         glean: GleanWrapper = DefaultGleanWrapper.shared,
         applicationHelper: ApplicationHelper = DefaultApplicationHelper()) {
        self.screenshotService = screenshotService
        self.profile = profile
        self.tabManager = tabManager
        self.themeManager = themeManager
        self.windowManager = windowManager
        self.browserViewController = BrowserViewController(profile: profile, tabManager: tabManager)
        self.applicationHelper = applicationHelper
        self.glean = glean
        super.init(router: router)

        // TODO [7856]: Additional telemetry updates forthcoming once iPad multi-window enabled.
        // For now, we only have a single BVC and TabManager. Plug it into our TelemetryWrapper:
        TelemetryWrapper.shared.defaultTabManager = tabManager

        browserViewController.browserDelegate = self
        browserViewController.navigationHandler = self
        tabManager.addDelegate(self)
    }

    func start(with launchType: LaunchType?) {
        router.push(browserViewController, animated: false)

        if let launchType = launchType, launchType.canLaunch(fromType: .BrowserCoordinator) {
            startLaunch(with: launchType)
        }
    }

    // MARK: - Helper methods

    private func startLaunch(with launchType: LaunchType) {
        let launchCoordinator = LaunchCoordinator(router: router)
        launchCoordinator.parentCoordinator = self
        add(child: launchCoordinator)
        launchCoordinator.start(with: launchType)
    }

    // MARK: - LaunchCoordinatorDelegate

    func didFinishLaunch(from coordinator: LaunchCoordinator) {
        router.dismiss(animated: true, completion: nil)
        remove(child: coordinator)

        // Once launch is done, we check for any saved Route
        if let savedRoute {
            findAndHandle(route: savedRoute)
        }
    }

    // MARK: - BrowserDelegate

    func showHomepage(inline: Bool,
                      toastContainer: UIView,
                      homepanelDelegate: HomePanelDelegate,
                      libraryPanelDelegate: LibraryPanelDelegate,
                      statusBarScrollDelegate: StatusBarScrollDelegate,
                      overlayManager: OverlayModeManager) {
        let homepageController = getHomepage(inline: inline,
                                             toastContainer: toastContainer,
                                             homepanelDelegate: homepanelDelegate,
                                             libraryPanelDelegate: libraryPanelDelegate,
                                             statusBarScrollDelegate: statusBarScrollDelegate,
                                             overlayManager: overlayManager)

        guard browserViewController.embedContent(homepageController) else { return }
        self.homepageViewController = homepageController
        homepageController.scrollToTop()
        // We currently don't support full page screenshot of the homepage
        screenshotService.screenshotableView = nil
    }

    func showPrivateHomepage(overlayManager: OverlayModeManager) {
        let privateHomepageController = PrivateHomepageViewController(overlayManager: overlayManager)
        privateHomepageController.parentCoordinator = self
        guard browserViewController.embedContent(privateHomepageController) else {
            logger.log("Unable to embed private homepage", level: .debug, category: .coordinator)
            return
        }
        self.privateViewController = privateHomepageController
    }

    // MARK: - PrivateHomepageDelegate

    func homePanelDidRequestToOpenInNewTab(with url: URL, isPrivate: Bool, selectNewTab: Bool) {
        browserViewController.homePanelDidRequestToOpenInNewTab(
            url,
            isPrivate: isPrivate,
            selectNewTab: selectNewTab
        )
    }

    func switchMode() {
        browserViewController.tabManager.switchPrivacyMode()
    }

    func show(webView: WKWebView) {
        // Keep the webviewController in memory, update to newest webview when needed
        if let webviewController = webviewController {
            webviewController.update(webView: webView, isPrivate: tabManager.selectedTab?.isPrivate ?? false)
            browserViewController.frontEmbeddedContent(webviewController)
        } else {
            let webviewViewController = WebviewViewController(
                webView: webView,
                isPrivate: tabManager.selectedTab?.isPrivate ?? false
            )
            webviewController = webviewViewController
            _ = browserViewController.embedContent(webviewViewController)
        }

        screenshotService.screenshotableView = webviewController
    }

    func browserHasLoaded() {
        browserIsReady = true
        logger.log("Browser has loaded", level: .info, category: .coordinator)

        if let savedRoute {
            findAndHandle(route: savedRoute)
        }
    }

    private func getHomepage(inline: Bool,
                             toastContainer: UIView,
                             homepanelDelegate: HomePanelDelegate,
                             libraryPanelDelegate: LibraryPanelDelegate,
                             statusBarScrollDelegate: StatusBarScrollDelegate,
                             overlayManager: OverlayModeManager) -> HomepageViewController {
        if let homepageViewController = homepageViewController {
            homepageViewController.configure(isZeroSearch: inline)
            return homepageViewController
        } else {
            let homepageViewController = HomepageViewController(
                profile: profile,
                isZeroSearch: inline,
                toastContainer: toastContainer,
                tabManager: tabManager,
                overlayManager: overlayManager)
            homepageViewController.homePanelDelegate = homepanelDelegate
            homepageViewController.libraryPanelDelegate = libraryPanelDelegate
            homepageViewController.statusBarScrollDelegate = statusBarScrollDelegate
            homepageViewController.browserNavigationHandler = self

            return homepageViewController
        }
    }

    // MARK: - Route handling

    override func canHandle(route: Route) -> Bool {
        guard browserIsReady, !tabManager.isRestoringTabs else {
            let readyMessage = "browser is ready? \(browserIsReady)"
            let restoringMessage = "is restoring tabs? \(tabManager.isRestoringTabs)"
            logger.log("Could not handle route, \(readyMessage), \(restoringMessage)",
                       level: .info,
                       category: .coordinator)
            return false
        }

        switch route {
        case .searchQuery, .search, .searchURL, .glean, .homepanel, .action, .fxaSignIn, .defaultBrowser:
            return true
        case let .settings(section):
            return canHandleSettings(with: section)
        }
    }

    override func handle(route: Route) {
        guard browserIsReady, !tabManager.isRestoringTabs else {
            return
        }

        logger.log("Handling a route", level: .info, category: .coordinator)
        switch route {
        case let .searchQuery(query):
            handle(query: query)

        case let .search(url, isPrivate, options):
            handle(url: url, isPrivate: isPrivate, options: options)

        case let .searchURL(url, tabId):
            handle(searchURL: url, tabId: tabId)

        case let .glean(url):
            glean.handleDeeplinkUrl(url: url)

        case let .homepanel(section):
            handle(homepanelSection: section)

        case let .settings(section):
            handleSettings(with: section)

        case let .action(routeAction):
            switch routeAction {
            case .closePrivateTabs:
                handleClosePrivateTabs()
            case .showQRCode:
                handleQRCode()
            case .showIntroOnboarding:
                showIntroOnboarding()
            }

        case let .fxaSignIn(params):
            handle(fxaParams: params)

        case let .defaultBrowser(section):
            switch section {
            case .systemSettings:
                applicationHelper.openSettings()
            case .tutorial:
                startLaunch(with: .defaultBrowser)
            }
        }
    }

    private func showIntroOnboarding() {
        let introManager = IntroScreenManager(prefs: profile.prefs)
        let launchType = LaunchType.intro(manager: introManager)
        startLaunch(with: launchType)
    }

    private func handleQRCode() {
        browserViewController.handleQRCode()
    }

    private func handleClosePrivateTabs() {
        browserViewController.handleClosePrivateTabs()
    }

    private func handle(homepanelSection section: Route.HomepanelSection) {
        switch section {
        case .bookmarks:
            browserViewController.showLibrary(panel: .bookmarks)
        case .history:
            browserViewController.showLibrary(panel: .history)
        case .readingList:
            browserViewController.showLibrary(panel: .readingList)
        case .downloads:
            browserViewController.showLibrary(panel: .downloads)
        case .topSites:
            browserViewController.openURLInNewTab(HomePanelType.topSites.internalUrl)
        case .newPrivateTab:
            browserViewController.openBlankNewTab(focusLocationField: false, isPrivate: true)
        case .newTab:
            browserViewController.openBlankNewTab(focusLocationField: false)
        }
    }

    private func handle(query: String) {
        browserViewController.handle(query: query)
    }

    private func handle(url: URL?, isPrivate: Bool, options: Set<Route.SearchOptions>? = nil) {
        browserViewController.handle(url: url, isPrivate: isPrivate, options: options)
    }

    private func handle(searchURL: URL?, tabId: String) {
        browserViewController.handle(url: searchURL, tabId: tabId)
    }

    private func handle(fxaParams: FxALaunchParams) {
        browserViewController.presentSignInViewController(fxaParams)
    }

    private func canHandleSettings(with section: Route.SettingsSection) -> Bool {
        guard !childCoordinators.contains(where: { $0 is SettingsCoordinator }) else {
            return false // route is handled with existing child coordinator
        }
        return true
    }

    private func handleSettings(with section: Route.SettingsSection) {
        guard !childCoordinators.contains(where: { $0 is SettingsCoordinator }) else {
            return // route is handled with existing child coordinator
        }
        windowManager.postWindowEvent(event: .settingsOpened, windowUUID: windowUUID)
        let navigationController = ThemedNavigationController()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let modalPresentationStyle: UIModalPresentationStyle = isPad ? .fullScreen: .formSheet
        navigationController.modalPresentationStyle = modalPresentationStyle
        let settingsRouter = DefaultRouter(navigationController: navigationController)

        let settingsCoordinator = SettingsCoordinator(router: settingsRouter, tabManager: tabManager)
        settingsCoordinator.parentCoordinator = self
        add(child: settingsCoordinator)
        settingsCoordinator.start(with: section)

        navigationController.onViewDismissed = { [weak self] in
            self?.didFinishSettings(from: settingsCoordinator)
        }
        router.present(navigationController)
    }

    private func showLibrary(with homepanelSection: Route.HomepanelSection) {
        windowManager.postWindowEvent(event: .libraryOpened, windowUUID: windowUUID)
        if let libraryCoordinator = childCoordinators[LibraryCoordinator.self] {
            libraryCoordinator.start(with: homepanelSection)
            (libraryCoordinator.router.navigationController as? UINavigationController).map { router.present($0) }
        } else {
            let navigationController = DismissableNavigationViewController()
            navigationController.modalPresentationStyle = .formSheet

            let libraryCoordinator = LibraryCoordinator(
                router: DefaultRouter(navigationController: navigationController),
                tabManager: tabManager
            )
            libraryCoordinator.parentCoordinator = self
            add(child: libraryCoordinator)
            libraryCoordinator.start(with: homepanelSection)

            router.present(navigationController)
        }
    }

    private func showETPMenu(sourceView: UIView) {
        let enhancedTrackingProtectionCoordinator = EnhancedTrackingProtectionCoordinator(router: router,
                                                                                          tabManager: tabManager)
        enhancedTrackingProtectionCoordinator.parentCoordinator = self
        add(child: enhancedTrackingProtectionCoordinator)
        enhancedTrackingProtectionCoordinator.start(sourceView: sourceView)
    }

    // MARK: - SettingsCoordinatorDelegate

    func openURLinNewTab(_ url: URL) {
        browserViewController.openURLInNewTab(url)
    }

    func didFinishSettings(from coordinator: SettingsCoordinator) {
        router.dismiss(animated: true, completion: nil)
        remove(child: coordinator)
    }

    func openDebugTestTabs(count: Int) {
        guard let url = URL(string: "https://www.mozilla.org") else { return }
        browserViewController.debugOpen(numberOfNewTabs: count, at: url)
    }

    // MARK: - LibraryCoordinatorDelegate

    func openRecentlyClosedSiteInSameTab(_ url: URL) {
        browserViewController.openRecentlyClosedSiteInSameTab(url)
    }

    func openRecentlyClosedSiteInNewTab(_ url: URL, isPrivate: Bool) {
        browserViewController.openRecentlyClosedSiteInNewTab(url, isPrivate: isPrivate)
    }

    func libraryPanelDidRequestToOpenInNewTab(_ url: URL, isPrivate: Bool) {
        browserViewController.libraryPanelDidRequestToOpenInNewTab(url, isPrivate: isPrivate)
        router.dismiss()
    }

    func libraryPanel(didSelectURL url: URL, visitType: Storage.VisitType) {
        browserViewController.libraryPanel(didSelectURL: url, visitType: visitType)
        router.dismiss()
    }

    var libraryPanelWindowUUID: WindowUUID {
        return windowUUID
    }

    func didFinishLibrary(from coordinator: LibraryCoordinator) {
        router.dismiss(animated: true, completion: nil)
        remove(child: coordinator)
    }

    // MARK: - EnhancedTrackingProtectionCoordinatorDelegate

    func didFinishEnhancedTrackingProtection(from coordinator: EnhancedTrackingProtectionCoordinator) {
        router.dismiss(animated: true, completion: nil)
        remove(child: coordinator)
    }

    func settingsOpenPage(settings: Route.SettingsSection) {
        handleSettings(with: settings)
    }

    // MARK: - BrowserNavigationHandler

    func show(settings: Route.SettingsSection) {
        presentWithModalDismissIfNeeded {
            self.handleSettings(with: settings)
        }
    }

    /// Not all flows are handled by coordinators at the moment so we can't call router.dismiss for all
    /// This bridges to use the presentWithModalDismissIfNeeded method we have in older flows
    private func presentWithModalDismissIfNeeded(completion: @escaping () -> Void) {
        if let presentedViewController = router.navigationController.presentedViewController {
            presentedViewController.dismiss(animated: false, completion: {
                completion()
            })
        } else {
            completion()
        }
    }

    func show(homepanelSection: Route.HomepanelSection) {
        showLibrary(with: homepanelSection)
    }

    func showEnhancedTrackingProtection(sourceView: UIView) {
        showETPMenu(sourceView: sourceView)
    }

    func showFakespotFlowAsModal(productURL: URL) {
        guard let coordinator = makeFakespotCoordinator() else { return }
        coordinator.startModal(productURL: productURL)
    }

    func showFakespotFlowAsSidebar(productURL: URL,
                                   sidebarContainer: SidebarEnabledViewProtocol,
                                   parentViewController: UIViewController) {
        guard let coordinator = makeFakespotCoordinator() else { return }
        coordinator.startSidebar(productURL: productURL,
                                 sidebarContainer: sidebarContainer,
                                 parentViewController: parentViewController)
    }

    func dismissFakespotModal(animated: Bool = true) {
        guard let fakespotCoordinator = childCoordinators.first(where: {
            $0 is FakespotCoordinator
        }) as? FakespotCoordinator else {
            return // there is no modal to close
        }
        fakespotCoordinator.dismissModal(animated: animated)
    }

    func dismissFakespotSidebar(sidebarContainer: SidebarEnabledViewProtocol, parentViewController: UIViewController) {
        guard let fakespotCoordinator = childCoordinators.first(where: {
            $0 is FakespotCoordinator
        }) as? FakespotCoordinator else {
            return // there is no sidebar to close
        }
        fakespotCoordinator.closeSidebar(sidebarContainer: sidebarContainer,
                                         parentViewController: parentViewController)
    }

    func updateFakespotSidebar(productURL: URL,
                               sidebarContainer: SidebarEnabledViewProtocol,
                               parentViewController: UIViewController) {
        guard let fakespotCoordinator = childCoordinators.first(where: {
            $0 is FakespotCoordinator
        }) as? FakespotCoordinator else {
            return // there is no sidebar
        }
        fakespotCoordinator.updateSidebar(productURL: productURL,
                                          sidebarContainer: sidebarContainer,
                                          parentViewController: parentViewController)
    }

    private func makeFakespotCoordinator() -> FakespotCoordinator? {
        guard !childCoordinators.contains(where: { $0 is FakespotCoordinator }) else {
            return nil // flow is already handled
        }

        let coordinator = FakespotCoordinator(router: router, tabManager: tabManager)
        coordinator.parentCoordinator = self
        add(child: coordinator)
        return coordinator
    }

    func showShareExtension(
        url: URL,
        sourceView: UIView,
        sourceRect: CGRect?,
        toastContainer: UIView,
        popoverArrowDirection: UIPopoverArrowDirection
    ) {
        guard childCoordinators.first(where: { $0 is ShareExtensionCoordinator }) as? ShareExtensionCoordinator == nil
        else {
            // If this case is hitted it means the share extension coordinator wasn't removed
            // correctly in the previous session.
            return
        }
        let shareExtensionCoordinator = ShareExtensionCoordinator(
            alertContainer: toastContainer,
            router: router,
            profile: profile,
            parentCoordinator: self,
            tabManager: tabManager
        )
        add(child: shareExtensionCoordinator)
        shareExtensionCoordinator.start(
            url: url,
            sourceView: sourceView,
            sourceRect: sourceRect,
            popoverArrowDirection: popoverArrowDirection
        )
    }

    func showCreditCardAutofill(creditCard: CreditCard?,
                                decryptedCard: UnencryptedCreditCardFields?,
                                viewType state: CreditCardBottomSheetState,
                                frame: WKFrameInfo?,
                                alertContainer: UIView) {
        let bottomSheetCoordinator = makeCredentialAutofillCoordinator()
        bottomSheetCoordinator.showCreditCardAutofill(
            creditCard: creditCard,
            decryptedCard: decryptedCard,
            viewType: state,
            frame: frame,
            alertContainer: alertContainer
        )
    }

    func showRequiredPassCode() {
        let bottomSheetCoordinator = makeCredentialAutofillCoordinator()
        bottomSheetCoordinator.showPassCodeController()
    }

    private func makeCredentialAutofillCoordinator() -> CredentialAutofillCoordinator {
        if let bottomSheetCoordinator = childCoordinators.first(where: {
            $0 is CredentialAutofillCoordinator
        }) as? CredentialAutofillCoordinator {
            return bottomSheetCoordinator
        }
        let bottomSheetCoordinator = CredentialAutofillCoordinator(
            profile: profile,
            router: router,
            parentCoordinator: self,
            tabManager: tabManager
        )
        add(child: bottomSheetCoordinator)
        return bottomSheetCoordinator
    }

    func showQRCode(delegate: QRCodeViewControllerDelegate, rootNavigationController: UINavigationController?) {
        var coordinator: QRCodeCoordinator
        if let qrCodeCoordinator = childCoordinators.first(where: { $0 is QRCodeCoordinator }) as? QRCodeCoordinator {
            coordinator = qrCodeCoordinator
        } else {
            if rootNavigationController != nil {
                coordinator = QRCodeCoordinator(
                    parentCoordinator: self,
                    router: DefaultRouter(navigationController: rootNavigationController!)
                )
            } else {
                coordinator = QRCodeCoordinator(
                    parentCoordinator: self,
                    router: router
                )
            }

            add(child: coordinator)
        }
        coordinator.showQRCode(delegate: delegate)
    }

    func showTabTray(selectedPanel: TabTrayPanelType) {
        guard !childCoordinators.contains(where: { $0 is TabTrayCoordinator }) else {
            return // flow is already handled
        }

        let navigationController = DismissableNavigationViewController()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let modalPresentationStyle: UIModalPresentationStyle = isPad ? .fullScreen: .formSheet
        navigationController.modalPresentationStyle = modalPresentationStyle

        let tabTrayCoordinator = TabTrayCoordinator(
            router: DefaultRouter(navigationController: navigationController),
            tabTraySection: selectedPanel,
            profile: profile,
            tabManager: tabManager
        )
        tabTrayCoordinator.parentCoordinator = self
        add(child: tabTrayCoordinator)
        tabTrayCoordinator.start(with: selectedPanel)

        router.present(navigationController)
    }

    func showBackForwardList() {
        guard let backForwardList = tabManager.selectedTab?.webView?.backForwardList else { return }
        let backForwardListVC = BackForwardListViewController(profile: profile, backForwardList: backForwardList)
        backForwardListVC.backForwardTransitionDelegate = BackForwardListAnimator()
        backForwardListVC.browserFrameInfoProvider = browserViewController
        backForwardListVC.tabManager = tabManager
        backForwardListVC.modalPresentationStyle = .overCurrentContext
        router.present(backForwardListVC)
    }

    // MARK: - ParentCoordinatorDelegate
    func didFinish(from childCoordinator: Coordinator) {
        remove(child: childCoordinator)
    }

    // MARK: - TabManagerDelegate
    func tabManagerDidRestoreTabs(_ tabManager: TabManager) {
        // Once tab restore is made, if there's any saved route we make sure to call it
        if let savedRoute {
            findAndHandle(route: savedRoute)
        }
    }

    // MARK: - TabTrayCoordinatorDelegate
    func didDismissTabTray(from coordinator: TabTrayCoordinator) {
        router.dismiss(animated: true, completion: nil)
        remove(child: coordinator)
    }

    // MARK: - WindowEventCoordinator

    func coordinatorHandleWindowEvent(event: WindowEvent, uuid: WindowUUID) {
        switch event {
        case .windowWillClose:
            guard uuid == windowUUID else { return }
            // Additional cleanup performed when the current iPad window is closed.
            // This is necessary in order to ensure the BVC and other memory is freed correctly.

            // TODO: Revisit for [FXIOS-8064]. Disabled temporarily to avoid potential KVO crash in WebKit. (FXIOS-8416)
            // browserViewController.contentContainer.subviews.forEach { $0.removeFromSuperview() }
            // browserViewController.removeFromParent()
        case .libraryOpened:
            // Auto-close library panel if it was opened in another iPad window. [FXIOS-8095]
            guard uuid != windowUUID else { return }
            performIfCoordinatorRootVCIsPresented(LibraryCoordinator.self) { _ in
                router.dismiss(animated: true, completion: nil)
            }
        case .settingsOpened:
            // Auto-close settings panel if it was opened in another iPad window. [FXIOS-8095]
            guard uuid != windowUUID else { return }
            performIfCoordinatorRootVCIsPresented(SettingsCoordinator.self) {
                didFinishSettings(from: $0)
            }
        }
    }

    /// Utility. Performs the supplied action if a coordinator of the indicated type
    /// is currently presenting its primary view controller.
    /// - Parameters:
    ///   - coordinatorType: the type of coordinator.
    ///   - action: the action to perform. The Coordinator instance is supplied for convenience.
    private func performIfCoordinatorRootVCIsPresented<T: Coordinator>(_ coordinatorType: T.Type,
                                                                       action: (T) -> Void) {
        guard let expectedCoordinator = childCoordinators[coordinatorType] else { return }
        let browserPresentedVC = router.navigationController.presentedViewController
        let rootVC = (browserPresentedVC as? UINavigationController)?.viewControllers.first
        if rootVC === expectedCoordinator.router.rootViewController {
            action(expectedCoordinator)
        }
    }
}
