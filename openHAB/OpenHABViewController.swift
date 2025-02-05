//
//  OpenHABViewController.swift
//  openHAB
//
//  Created by Victor Belov on 12/01/14.
//  Copyright (c) 2014 Victor Belov. All rights reserved.
//
//  Converted to Swift 4 by Tim Müller-Seydlitz and Swiftify on 06/01/18
//

import AVFoundation
import AVKit
import DynamicButton
import os.log
import SDWebImage
import SDWebImageSVGCoder
import SideMenu
import SwiftMessages
import UIKit

private let OpenHABViewControllerMapViewCellReuseIdentifier = "OpenHABViewControllerMapViewCellReuseIdentifier"
private let OpenHABViewControllerImageViewCellReuseIdentifier = "OpenHABViewControllerImageViewCellReuseIdentifier"

enum TargetController {
    case root
    case settings
    case notifications
}
protocol ModalHandler: class {
    func modalDismissed(to: TargetController)
}

class OpenHABViewController: UIViewController {

    var tracker: OpenHABTracker?

    var hamburgerButton: DynamicButton!

    private var selectedWidgetRow: Int = 0
    private var currentPageOperation: OpenHABHTTPRequestOperation?
    private var commandOperation: OpenHABHTTPRequestOperation?

    @IBOutlet var widgetTableView: UITableView!
    var pageUrl = ""
    var openHABRootUrl = ""
    var openHABUsername = ""
    var openHABPassword = ""
    var defaultSitemap = ""
    var idleOff = false
    var sitemaps: [OpenHABSitemap] = []
    var currentPage: OpenHABSitemapPage?
    var selectionPicker: UIPickerView?
    var pageNetworkStatus: Reachability.Connection?
    var pageNetworkStatusAvailable = false
    var toggle: Int = 0
    var deviceToken = ""
    var deviceId = ""
    var deviceName = ""
    var atmosphereTrackingId = ""
    var refreshControl: UIRefreshControl?
    var iconType: IconType = .png

    let search = UISearchController(searchResultsController: nil)
    var filteredPage: OpenHABSitemapPage?

    func sendCommand(_ item: OpenHABItem?, commandToSend command: String?) {
        if let commandUrl = URL(string: item?.link ?? "") {
            var commandRequest = URLRequest(url: commandUrl)

            commandRequest.httpMethod = "POST"
            commandRequest.httpBody = command?.data(using: .utf8)
            commandRequest.setAuthCredentials(openHABUsername, openHABPassword)
            commandRequest.setValue("text/plain", forHTTPHeaderField: "Content-type")
            if commandOperation != nil {
                commandOperation?.cancel()
                commandOperation = nil
            }
            commandOperation = OpenHABHTTPRequestOperation(request: commandRequest, delegate: self)
            commandOperation?.setCompletionBlockWithSuccess({ operation, responseObject in
                os_log("Command sent!", log: .remoteAccess, type: .info)
            }, failure: { operation, error in
                os_log("%{PUBLIC}@ %d", log: .default, type: .error, error.localizedDescription, Int(operation.response?.statusCode ?? 0))
            })
            os_log("Timeout %{PUBLIC}g", log: .default, type: .info, commandRequest.timeoutInterval)
            if let link = item?.link {
                os_log("OpenHABViewController posting %{PUBLIC}@ command to %{PUBLIC}@", log: .default, type: .info, command  ?? "", link)
                os_log("%{PUBLIC}@", log: .default, type: .info, commandRequest.debugDescription)
            }
            commandOperation?.start()
        }
    }

    func sideMenuWillDisappear(menu: UISideMenuNavigationController, animated: Bool) {
        self.hamburgerButton.setStyle(.hamburger, animated: animated)
    }

    // Here goes everything about view loading, appearing, disappearing, entering background and becoming active
    override func viewDidLoad() {
        super.viewDidLoad()
        os_log("OpenHABViewController viewDidLoad", log: .default, type: .info)

        pageNetworkStatus = nil //NetworkStatus(rawValue: -1)
        sitemaps = []
        widgetTableView.tableFooterView = UIView()
        NotificationCenter.default.addObserver(self, selector: #selector(OpenHABViewController.didEnterBackground(_:)), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(OpenHABViewController.didBecomeActive(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)

        self.registerTableViewCells()
        self.configureTableView()

        refreshControl = UIRefreshControl()

        refreshControl?.addTarget(self, action: #selector(OpenHABViewController.handleRefresh(_:)), for: .valueChanged)
        if let refreshControl = refreshControl {
            widgetTableView.refreshControl = refreshControl
        }

        self.hamburgerButton = DynamicButton(frame: CGRect(x: 0, y: 0, width: 31, height: 31))
        hamburgerButton.setStyle(.hamburger, animated: true)
        hamburgerButton.addTarget(self, action: #selector(OpenHABViewController.rightDrawerButtonPress(_:)), for: .touchUpInside)
        hamburgerButton.strokeColor = self.view.tintColor

        let hamburgerButtomItem = UIBarButtonItem(customView: hamburgerButton)
        navigationItem.setRightBarButton(hamburgerButtomItem, animated: true)

        self.navigationController?.navigationBar.prefersLargeTitles = true

        search.searchResultsUpdater = self
        self.navigationItem.searchController = search

        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search openHAB items"
        definesPresentationContext = true

        setupSideMenu()

        #if DEBUG
        // setup accessibilityIdentifiers for UITest
        widgetTableView.accessibilityIdentifier = "OpenHABViewControllerWidgetTableView"
        #endif
    }

    fileprivate func setupSideMenu() {
        // Define the menus

        SideMenuManager.default.menuRightNavigationController = storyboard!.instantiateViewController(withIdentifier: "RightMenuNavigationController") as? UISideMenuNavigationController

        // Enable gestures. The left and/or right menus must be set up above for these to work.
        // Note that these continue to work on the Navigation Controller independent of the View Controller it displays!
        SideMenuManager.default.menuAddPanGestureToPresent(toView: self.navigationController!.navigationBar)
        SideMenuManager.default.menuAddScreenEdgePanGesturesToPresent(toView: self.navigationController!.view)

        SideMenuManager.default.menuFadeStatusBar = false
    }

    func configureTableView() {
        widgetTableView.dataSource = self
        widgetTableView.delegate = self
    }

    func registerTableViewCells() {
        widgetTableView.register(MapViewTableViewCell.self, forCellReuseIdentifier: OpenHABViewControllerMapViewCellReuseIdentifier)
        widgetTableView.register(cellType: MapViewTableViewCell.self)
        widgetTableView.register(NewImageUITableViewCell.self, forCellReuseIdentifier: OpenHABViewControllerImageViewCellReuseIdentifier)
        widgetTableView.register(cellType: VideoUITableViewCell.self)
    }

    @objc func handleRefresh(_ refreshControl: UIRefreshControl?) {
        loadPage(false)
        widgetTableView.reloadData()
        widgetTableView.layoutIfNeeded()
    }

    @objc func handleApsRegistration(_ note: Notification?) {
        os_log("handleApsRegistration", log: .notifications, type: .info)
        let theData = note?.userInfo
        if theData != nil {
            deviceId = theData?["deviceId"] as? String ?? ""
            deviceToken = theData?["deviceToken"] as? String ?? ""
            deviceName = theData?["deviceName"] as? String ?? ""
            doRegisterAps()
        }
    }

    @objc func rightDrawerButtonPress(_ sender: Any?) {
        performSegue(withIdentifier: "sideMenu", sender: nil)
    }

    func doRegisterAps() {
        if let prefsURL = UserDefaults.standard.string(forKey: "remoteUrl"), prefsURL.contains("openhab.org") {
            if deviceId != "" && deviceToken != "" && deviceName != "" {
                os_log("Registering notifications with %{PUBLIC}@", log: .notifications, type: .info, prefsURL)
                if let registrationUrl = Endpoint.appleRegistration(prefsURL: prefsURL, deviceToken: deviceToken, deviceId: deviceId, deviceName: deviceName).url {
                    var registrationRequest = URLRequest(url: registrationUrl)
                    os_log("Registration URL = %{PUBLIC}@", log: .notifications, type: .info, registrationUrl.absoluteString)
                    registrationRequest.setAuthCredentials(openHABUsername, openHABPassword)
                    let registrationOperation = OpenHABHTTPRequestOperation(request: registrationRequest, delegate: self)
                    registrationOperation.setCompletionBlockWithSuccess({ operation, responseObject in
                        os_log("my.openHAB registration sent", log: .notifications, type: .info)
                    }, failure: { operation, error in
                        os_log("my.openHAB registration failed %{PUBLIC}@ %d", log: .notifications, type: .error, error.localizedDescription, Int(operation.response?.statusCode ?? 0))

                    })
                    registrationOperation.start()
                }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        os_log("OpenHABViewController viewDidAppear", log: .viewCycle, type: .info)
        super.viewDidAppear(animated)
    }

    override func viewWillAppear(_ animated: Bool) {
        os_log("OpenHABViewController viewWillAppear", log: .viewCycle, type: .info)
        super.viewWillAppear(animated)
        // Load settings into local properties
        loadSettings()
        // Set authentication parameters to SDImag
        setSDImageAuth()
        // Disable idle timeout if configured in settings
        if idleOff {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        doRegisterAps()
        // if pageUrl == "" it means we are the first opened OpenHABViewController
        if pageUrl == "" {
            // Set self as root view controller
            appData?.rootViewController = self
            // Add self as observer for APS registration
            NotificationCenter.default.addObserver(self, selector: #selector(OpenHABViewController.handleApsRegistration(_:)), name: NSNotification.Name("apsRegistered"), object: nil)
            if currentPage != nil {
                currentPage?.widgets = []
                widgetTableView.reloadData()
            }
            os_log("OpenHABViewController pageUrl is empty, this is first launch", log: .viewCycle, type: .info)
            UIApplication.shared.isNetworkActivityIndicatorVisible = true
            tracker = OpenHABTracker()
            tracker?.delegate = self
            tracker?.start()
        } else {
            if !pageNetworkStatusChanged() {
                os_log("OpenHABViewController pageUrl = %{PUBLIC}@", log: .notifications, type: .info, pageUrl)
                loadPage(false)
            } else {
                os_log("OpenHABViewController network status changed while I was not appearing", log: .viewCycle, type: .info)
                restart()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        os_log("OpenHABViewController viewWillDisappear", log: .viewCycle, type: .info)
        if currentPageOperation != nil {
            currentPageOperation?.cancel()
            currentPageOperation = nil
        }
        super.viewWillDisappear(animated)

        // workaround for #309 (see: https://stackoverflow.com/questions/46301813/broken-uisearchbar-animation-embedded-in-navigationitem)
        if #available(iOS 13.0, *) {
            // do nothing
        } else {
            if animated, !search.isActive, !search.isEditing, navigationController.map({$0.viewControllers.last != self}) ?? false,
                let searchBarSuperview = search.searchBar.superview,
                let searchBarHeightConstraint = searchBarSuperview.constraints.first(where: {
                    $0.firstAttribute == .height
                        && $0.secondItem == nil
                        && $0.secondAttribute == .notAnAttribute
                        && $0.constant > 0
                }) {

                UIView.performWithoutAnimation {
                    searchBarHeightConstraint.constant = 0
                    searchBarSuperview.superview?.layoutIfNeeded()
                }
            }
        }
    }

    @objc func didEnterBackground(_ notification: Notification?) {
        os_log("OpenHABViewController didEnterBackground", log: .viewCycle, type: .info)
        if currentPageOperation != nil {
            currentPageOperation?.cancel()
            currentPageOperation = nil
        }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    @objc func didBecomeActive(_ notification: Notification?) {
        os_log("OpenHABViewController didBecomeActive", log: .viewCycle, type: .info)
        // re disable idle off timer
        if idleOff {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        if isViewLoaded && view.window != nil && pageUrl != "" {
            if !pageNetworkStatusChanged() {
                os_log("OpenHABViewController isViewLoaded, restarting network activity", log: .viewCycle, type: .info)
                loadPage(false)
            } else {
                os_log("OpenHABViewController network status changed while it was inactive", log: .viewCycle, type: .info)
                restart()
            }
        }
    }

    func restart() {
        if appData?.rootViewController == self {
            os_log("I am a rootViewController!", log: .viewCycle, type: .info)

        } else {
            appData?.rootViewController?.pageUrl = ""
            navigationController?.popToRootViewController(animated: true)
        }
    }

    func relevantWidget(indexPath: IndexPath) -> OpenHABWidget? {
        return relevantPage?.widgets[indexPath.row]
    }

    var relevantPage: OpenHABSitemapPage? {
        if isFiltering {
            return filteredPage
        } else {
            return currentPage
        }
    }

    private func updateWidgetTableView() {
        UIView.performWithoutAnimation {
            widgetTableView.beginUpdates()
            widgetTableView.endUpdates()
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        os_log("OpenHABViewController prepareForSegue %{PUBLIC}@", log: .viewCycle, type: .info, segue.identifier ?? "")

        switch segue.identifier {
        case "showSelectionView": os_log("Selection seague", log: .viewCycle, type: .info)
        case "sideMenu":
            let navigation = segue.destination as? UINavigationController
            let drawer = navigation?.viewControllers[0] as? OpenHABDrawerTableViewController
            drawer?.openHABRootUrl = openHABRootUrl
            drawer?.delegate = self
            drawer?.drawerTableType = .with
        case "showSelectSitemap":
            let dest = segue.destination as! OpenHABDrawerTableViewController
            dest.openHABRootUrl = openHABRootUrl
            dest.drawerTableType = .without
            dest.delegate = self
        default: break
        }
    }

    // load our page and show it into UITableView
    func loadPage(_ longPolling: Bool) {
        if pageUrl == "" {
            return
        }
        os_log("pageUrl = %{PUBLIC}@", log: OSLog.remoteAccess, type: .info, pageUrl)

        // If this is the first request to the page make a bulk call to pageNetworkStatusChanged
        // to save current reachability status.
        if !longPolling {
            _ = pageNetworkStatusChanged()
        }
        //let pageToLoadUrl = URL(string: pageUrl)
        guard let pageToLoadUrl = URL(string: pageUrl) else { return }
        var pageRequest = URLRequest(url: pageToLoadUrl)

        pageRequest.setAuthCredentials(openHABUsername, openHABPassword)
        // We accept XML only if openHAB is 1.X
        if appData?.openHABVersion == 1 {
            pageRequest.setValue("application/xml", forHTTPHeaderField: "Accept")
        }
        pageRequest.setValue("1.0", forHTTPHeaderField: "X-Atmosphere-Framework")
        if longPolling {
            os_log("long polling, so setting atmosphere transport", log: OSLog.remoteAccess, type: .info)
            pageRequest.setValue("long-polling", forHTTPHeaderField: "X-Atmosphere-Transport")
            pageRequest.timeoutInterval = 300.0
        } else {
            atmosphereTrackingId = "0"
            UIApplication.shared.isNetworkActivityIndicatorVisible = true
            pageRequest.timeoutInterval = 10.0
        }
        pageRequest.setValue(atmosphereTrackingId, forHTTPHeaderField: "X-Atmosphere-tracking-id")

        if currentPageOperation != nil {
            currentPageOperation?.cancel()
            currentPageOperation = nil
        }
        currentPageOperation = OpenHABHTTPRequestOperation(request: pageRequest as URLRequest, delegate: self)

        currentPageOperation?.setCompletionBlockWithSuccess({ [weak self] operation, responseObject in
            guard let self = self else { return }

            os_log("Page loaded with success", log: OSLog.remoteAccess, type: .info)
            let headers = operation.response?.allHeaderFields

            self.atmosphereTrackingId = headers?["X-Atmosphere-tracking-id"] as? String ?? ""
            if !self.atmosphereTrackingId.isEmpty {
                os_log("Found X-Atmosphere-tracking-id: %{PUBLIC}@", log: .remoteAccess, type: .info, self.atmosphereTrackingId)
            }
            var openHABSitemapPage: OpenHABSitemapPage?
            if let response = responseObject as? Data {
                // If we are talking to openHAB 1.X, talk XML
                if self.appData?.openHABVersion == 1 {
                    let str = String(decoding: response, as: UTF8.self)
                    os_log("%{PUBLIC}@", log: .remoteAccess, type: .info, str)

                    guard let doc = try? GDataXMLDocument(data: response) else { return }
                    if let name = doc.rootElement().name() {
                        os_log("XML sitemmap with root element: %{PUBLIC}@", log: .remoteAccess, type: .info, name)
                    }
                    openHABSitemapPage = {
                        if doc.rootElement().name() == "page", let rootElement = doc.rootElement() {
                            return OpenHABSitemapPage(xml: rootElement)
                        }
                        return nil
                    }()
                } else {
                    // Newer versions talk JSON!
                    os_log("openHAB 2", log: OSLog.remoteAccess, type: .info)
                    do {
                        // Self-executing closure
                        // Inspired by https://www.swiftbysundell.com/posts/inline-types-and-functions-in-swift
                        openHABSitemapPage = try {
                            let sitemapPageCodingData = try response.decoded() as OpenHABSitemapPage.CodingData
                            return sitemapPageCodingData.openHABSitemapPage
                            }()
                    } catch {
                        os_log("Should not throw %{PUBLIC}@", log: OSLog.remoteAccess, type: .error, error.localizedDescription)
                    }
                }
            }
            self.currentPage = openHABSitemapPage
            if self.isFiltering {
                self.filterContentForSearchText(self.search.searchBar.text)
            }
            self.currentPage?.sendCommand = { [weak self] (item, command) in
                self?.sendCommand(item, commandToSend: command)
            }
            self.widgetTableView.reloadData()
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            self.refreshControl?.endRefreshing()
            self.navigationItem.title = self.currentPage?.title.components(separatedBy: "[")[0]
            self.loadPage(true)
            }, failure: { [weak self] operation, error in
                guard let self = self else { return }

                UIApplication.shared.isNetworkActivityIndicatorVisible = false
                os_log("On LoadPage %{PUBLIC}@ code: %d ", log: .remoteAccess, type: .error, error.localizedDescription, Int(operation.response?.statusCode ?? 0))
                self.atmosphereTrackingId = ""
                if (error as NSError?)?.code == -1001 && longPolling {
                    os_log("Timeout, restarting requests", log: OSLog.remoteAccess, type: .error)
                    self.loadPage(false)
                } else if (error as NSError?)?.code == -999 {
                    os_log("Request was cancelled", log: OSLog.remoteAccess, type: .error)
                } else {
                    // Error
                    DispatchQueue.main.async {
                        if (error as NSError?)?.code == -1012 {
                            var config = SwiftMessages.Config()
                            config.duration = .seconds(seconds: 5)
                            config.presentationStyle = .bottom

                            SwiftMessages.show(config: config) {
                                UIApplication.shared.isNetworkActivityIndicatorVisible = false
                                let view = MessageView.viewFromNib(layout: .cardView)
                                // ... configure the view
                                view.configureTheme(.error)
                                view.configureContent(title: "Error", body: "SSL Certificate Error")
                                view.button?.setTitle("Dismiss", for: .normal)
                                view.buttonTapHandler = { _ in SwiftMessages.hide() }
                                return view
                            }
                        } else {
                            var config = SwiftMessages.Config()
                            config.duration = .seconds(seconds: 5)
                            config.presentationStyle = .bottom

                            SwiftMessages.show(config: config) {
                                UIApplication.shared.isNetworkActivityIndicatorVisible = false
                                let view = MessageView.viewFromNib(layout: .cardView)
                                // ... configure the view
                                view.configureTheme(.error)
                                view.configureContent(title: "Error", body: error.localizedDescription)
                                view.button?.setTitle("Dismiss", for: .normal)
                                view.buttonTapHandler = { _ in SwiftMessages.hide() }
                                return view
                            }
                        }
                    }
                    os_log("Request failed: %{PUBLIC}@", log: .remoteAccess, type: .error, error.localizedDescription)
                }
        })
        os_log("OpenHABViewController sending new request", log: .remoteAccess, type: .error)
        currentPageOperation?.start()
        os_log("OpenHABViewController request sent", log: .remoteAccess, type: .error)
    }

    // Select sitemap
    func selectSitemap() {

        if let sitemapsUrl = Endpoint.sitemaps(openHABRootUrl: openHABRootUrl).url {
            var sitemapsRequest = URLRequest(url: sitemapsUrl)
            sitemapsRequest.setAuthCredentials(openHABUsername, openHABPassword)
            sitemapsRequest.timeoutInterval = 10.0
            let operation = OpenHABHTTPRequestOperation(request: sitemapsRequest, delegate: self)

            operation.setCompletionBlockWithSuccess({ operation, responseObject in
                let response = responseObject as? Data
                UIApplication.shared.isNetworkActivityIndicatorVisible = false
                self.sitemaps = deriveSitemaps(response, version: self.appData?.openHABVersion)
                switch self.sitemaps.count {
                case 2...:
                    if self.defaultSitemap != "" {
                        if let sitemapToOpen = self.sitemap(byName: self.defaultSitemap) {
                            self.pageUrl = sitemapToOpen.homepageLink
                            self.loadPage(false)
                        } else {
                            self.performSegue(withIdentifier: "showSelectSitemap", sender: self)
                        }
                    } else {
                        self.performSegue(withIdentifier: "showSelectSitemap", sender: self)
                    }
                case 1:
                    self.pageUrl = self.sitemaps[0].homepageLink
                    self.loadPage(false)
                case ...0:
                    var config = SwiftMessages.Config()
                    config.duration = .seconds(seconds: 5)
                    config.presentationStyle = .bottom

                    SwiftMessages.show(config: config) {
                        UIApplication.shared.isNetworkActivityIndicatorVisible = false
                        let view = MessageView.viewFromNib(layout: .cardView)
                        // ... configure the view
                        view.configureTheme(.error)
                        view.configureContent(title: "Error", body: "openHAB returned empty sitemap list")
                        view.button?.setTitle("Dismiss", for: .normal)
                        view.buttonTapHandler = { _ in SwiftMessages.hide() }
                        return view
                    }
                default: break
                }
            }, failure: { operation, error in
                os_log("%{PUBLIC}@ %d", log: .default, type: .error, error.localizedDescription, Int(operation.response?.statusCode ?? 0))
                DispatchQueue.main.async {
                    UIApplication.shared.isNetworkActivityIndicatorVisible = false
                    // Error
                    if (error as NSError?)?.code == -1012 {
                        var config = SwiftMessages.Config()
                        config.duration = .seconds(seconds: 5)
                        config.presentationStyle = .bottom

                        SwiftMessages.show(config: config) {
                            UIApplication.shared.isNetworkActivityIndicatorVisible = false
                            let view = MessageView.viewFromNib(layout: .cardView)
                            view.configureTheme(.error)
                            view.configureContent(title: "Error", body: "SSL Certificate Error")
                            view.button?.setTitle("Dismiss", for: .normal)
                            view.buttonTapHandler = { _ in SwiftMessages.hide() }
                            return view
                        }
                    } else {
                        var config = SwiftMessages.Config()
                        config.duration = .seconds(seconds: 5)
                        config.presentationStyle = .bottom

                        SwiftMessages.show(config: config) {
                            UIApplication.shared.isNetworkActivityIndicatorVisible = false
                            let view = MessageView.viewFromNib(layout: .cardView)
                            view.configureTheme(.error)
                            view.configureContent(title: "Error", body: error.localizedDescription)
                            view.button?.setTitle("Dismiss", for: .normal)
                            view.buttonTapHandler = { _ in SwiftMessages.hide() }
                            return view
                        }
                    }
                }
            })
            os_log("Firing request", log: .viewCycle, type: .info)

            UIApplication.shared.isNetworkActivityIndicatorVisible = true
            operation.start()
        }
    }

    // load app settings
    func loadSettings() {
        let prefs = UserDefaults.standard
        openHABUsername = prefs.string(forKey: "username") ?? ""
        openHABPassword = prefs.string(forKey: "password") ?? ""
        defaultSitemap = prefs.string(forKey: "defaultSitemap") ?? ""
        idleOff = prefs.bool(forKey: "idleOff")
        let rawIconType = prefs.integer(forKey: "iconType")
        iconType = IconType(rawValue: rawIconType) ?? .png

        appData?.openHABUsername = openHABUsername
        appData?.openHABPassword = openHABPassword

        #if DEBUG
        // always use demo sitemap for UITest
        if ProcessInfo.processInfo.environment["UITest"] != nil {
            defaultSitemap = "demo"
        }
        #endif
    }

    // Set SDImage (used for widget icons and images) authentication
    func setSDImageAuth() {
        let requestModifier = SDWebImageDownloaderRequestModifier { (request) -> URLRequest? in
            let authStr = "\(self.openHABUsername):\(self.openHABPassword)"
            let authData: Data? = authStr.data(using: .ascii)
            let authValue = "Basic \(authData?.base64EncodedString(options: []) ?? "")"
            var r = request
            r.setValue(authValue, forHTTPHeaderField: "Authorization")
            return r
        }
        SDWebImageDownloader.shared.requestModifier = requestModifier

        // Setup SDWebImage to use our downloader operation which handles client certificates
        SDWebImageDownloader.shared.config.operationClass = OpenHABSDWebImageDownloaderOperation.self
    }

    // Find and return sitemap by it's name if any
    func sitemap(byName sitemapName: String?) -> OpenHABSitemap? {
        for sitemap in sitemaps where sitemap.name == sitemapName {
            return sitemap
        }
        return nil
    }

    func pageNetworkStatusChanged() -> Bool {
        os_log("OpenHABViewController pageNetworkStatusChange", log: .remoteAccess, type: .info)
        if pageUrl != "" {
            let pageReachability = Reachability(hostname: pageUrl)
            if !pageNetworkStatusAvailable {
                pageNetworkStatus = pageReachability?.connection
                pageNetworkStatusAvailable = true
                return false
            } else {
                if pageNetworkStatus == pageReachability?.connection {
                    return false
                } else {
                    pageNetworkStatus = pageReachability?.connection
                    return true
                }
            }
        }
        return false
    }

    // App wide data access
    // https://stackoverflow.com/questions/45832155/how-do-i-refactor-my-code-to-call-appdelegate-on-the-main-thread
    var appData: OpenHABDataObject? {
        return AppDelegate.appDelegate.appData
    }

    // MARK: - Private instance methods

    var searchBarIsEmpty: Bool {
        // Returns true if the text is empty or nil
        return search.searchBar.text?.isEmpty ?? true
    }

    var isFiltering: Bool {
        return search.isActive && !searchBarIsEmpty
    }

    func filterContentForSearchText(_ searchText: String?, scope: String = "All") {
        guard let searchText = searchText else { return }

        filteredPage = currentPage?.filter {
            return $0.label.lowercased().contains(searchText.lowercased()) && $0.type != "Frame"
        }
        filteredPage?.sendCommand = { [weak self] (item, command) in
            self?.sendCommand(item, commandToSend: command)
        }
        widgetTableView.reloadData()
    }

}

// MARK: - OpenHABTrackerDelegate
extension OpenHABViewController: OpenHABTrackerDelegate {

    func openHABTracked(_ openHABUrl: URL?) {
        os_log("OpenHABViewController openHAB URL =  %{PUBLIC}@", log: .remoteAccess, type: .error, "\(openHABUrl!)")

        DispatchQueue.main.async {
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
        }
        openHABRootUrl = openHABUrl == nil ? "" : "\(openHABUrl!)"
        appData?.openHABRootUrl = openHABRootUrl

        if let pageToLoadUrl = Endpoint.tracker(openHABRootUrl: openHABRootUrl).url {
            var pageRequest = URLRequest(url: pageToLoadUrl)

            pageRequest.setAuthCredentials(openHABUsername, openHABPassword)
            pageRequest.timeoutInterval = 10.0
            let versionPageOperation = OpenHABHTTPRequestOperation(request: pageRequest, delegate: self)
            versionPageOperation.setCompletionBlockWithSuccess({ operation, responseObject in
                os_log("This is an openHAB 2.X", log: .remoteAccess, type: .info)
                self.appData?.openHABVersion = 2
                DispatchQueue.main.async {
                    UIApplication.shared.isNetworkActivityIndicatorVisible = false
                }
                self.selectSitemap()
            }, failure: { operation, error in
                os_log("This is an openHAB 1.X", log: .remoteAccess, type: .info)
                self.appData?.openHABVersion = 1
                DispatchQueue.main.async {
                    UIApplication.shared.isNetworkActivityIndicatorVisible = false
                }
                os_log("On Tracking %{PUBLIC}@ %d", log: .remoteAccess, type: .error, error.localizedDescription, Int(operation.response?.statusCode ?? 0))
                self.selectSitemap()
            })
            DispatchQueue.main.async {
                UIApplication.shared.isNetworkActivityIndicatorVisible = true
            }
            versionPageOperation.start()
        }
    }

    func openHABTrackingProgress(_ message: String?) {
        os_log("OpenHABViewController %{PUBLIC}@", log: .viewCycle, type: .info, message ?? "")
        var config = SwiftMessages.Config()
        config.duration = .seconds(seconds: 1.5)
        config.presentationStyle = .bottom

        SwiftMessages.show(config: config) {
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            let view = MessageView.viewFromNib(layout: .cardView)
            view.configureTheme(.info)
            view.configureContent(title: "Connecting", body: message ?? "")
            view.button?.setTitle("Dismiss", for: .normal)
            view.buttonTapHandler = { _ in SwiftMessages.hide() }
            return view
        }
    }

    func openHABTrackingError(_ error: Error) {
        os_log("OpenHABViewController discovery error", log: .viewCycle, type: .info)
        var config = SwiftMessages.Config()
        config.duration = .seconds(seconds: 60)
        config.presentationStyle = .bottom

        SwiftMessages.show(config: config) {
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            let view = MessageView.viewFromNib(layout: .cardView)
            // ... configure the view
            view.configureTheme(.error)
            view.configureContent(title: "Error", body: error.localizedDescription)
            view.button?.setTitle("Dismiss", for: .normal)
            view.buttonTapHandler = { _ in SwiftMessages.hide() }
            return view
        }
    }
}

// MARK: - OpenHABSelectionTableViewControllerDelegate
extension OpenHABViewController: OpenHABSelectionTableViewControllerDelegate {
    // send command on selected selection widget mapping
    func didSelectWidgetMapping(_ selectedMappingIndex: Int) {
        let selectedWidget: OpenHABWidget? = relevantPage?.widgets[selectedWidgetRow]
        let selectedMapping: OpenHABWidgetMapping? = selectedWidget?.mappings[selectedMappingIndex]
        sendCommand(selectedWidget?.item, commandToSend: selectedMapping?.command)
    }
}

// MARK: - UISearchResultsUpdating
extension OpenHABViewController: UISearchResultsUpdating {

    func updateSearchResults(for searchController: UISearchController) {
        filterContentForSearchText(searchController.searchBar.text)
    }

}

// MARK: - ColorPickerUITableViewCellDelegate
extension OpenHABViewController: ColorPickerUITableViewCellDelegate {
    func didPressColorButton(_ cell: ColorPickerUITableViewCell?) {
        let colorPickerViewController = storyboard?.instantiateViewController(withIdentifier: "ColorPickerViewController") as? ColorPickerViewController
        if let cell = cell {
            let widget = relevantPage?.widgets[widgetTableView.indexPath(for: cell)?.row ?? 0]
            colorPickerViewController?.title = widget?.labelText
            colorPickerViewController?.widget = widget
        }
        if let colorPickerViewController = colorPickerViewController {
            navigationController?.pushViewController(colorPickerViewController, animated: true)
        }
    }
}

// MARK: - AFRememberingSecurityPolicyDelegate
extension OpenHABViewController: AFRememberingSecurityPolicyDelegate {
    // delegate should ask user for a decision on what to do with invalid certificate
    func evaluateServerTrust(_ policy: AFRememberingSecurityPolicy?, summary certificateSummary: String?, forDomain domain: String?) {
        DispatchQueue.main.async(execute: {
            let alertView = UIAlertController(title: "SSL Certificate Warning", message: "SSL Certificate presented by \(certificateSummary ?? "") for \(domain ?? "") is invalid. Do you want to proceed?", preferredStyle: .alert)
            alertView.addAction(UIAlertAction(title: "Abort", style: .default) { _ in policy?.evaluateResult = .deny })
            alertView.addAction(UIAlertAction(title: "Once", style: .default) { _ in  policy?.evaluateResult = .permitOnce })
            alertView.addAction(UIAlertAction(title: "Always", style: .default) { _ in policy?.evaluateResult = .permitAlways })
            self.present(alertView, animated: true) {}
        })
    }

    // certificate received from openHAB doesn't match our record, ask user for a decision
    func evaluateCertificateMismatch(_ policy: AFRememberingSecurityPolicy?, summary certificateSummary: String?, forDomain domain: String?) {
        DispatchQueue.main.async(execute: {
            let alertView = UIAlertController(title: "SSL Certificate Warning", message: "SSL Certificate presented by \(certificateSummary ?? "") for \(domain ?? "") doesn't match the record. Do you want to proceed?", preferredStyle: .alert)
            alertView.addAction(UIAlertAction(title: "Abort", style: .default) { _ in  policy?.evaluateResult = .deny })
            alertView.addAction(UIAlertAction(title: "Once", style: .default) { _ in  policy?.evaluateResult = .permitOnce })
            alertView.addAction(UIAlertAction(title: "Always", style: .default) { _ in policy?.evaluateResult = .permitAlways })
            self.present(alertView, animated: true) {}
        })
    }
}

// MARK: - ClientCertificateManagerDelegate
extension OpenHABViewController: ClientCertificateManagerDelegate {

    // delegate should ask user for a decision on whether to import the client certificate into the keychain
    func askForClientCertificateImport(_ clientCertificateManager: ClientCertificateManager?) {
        DispatchQueue.main.async(execute: {
            let alertController = UIAlertController(title: "Client Certificate Import", message: "Import client certificate into the keychain?", preferredStyle: .alert)
            let okay = UIAlertAction(title: "Okay", style: .default) { (action: UIAlertAction) in
                clientCertificateManager!.clientCertificateAccepted(password: nil)
            }
            let cancel = UIAlertAction(title: "Cancel", style: .cancel) { (action: UIAlertAction) in
                clientCertificateManager!.clientCertificateRejected()
            }
            alertController.addAction(okay)
            alertController.addAction(cancel)
            self.present(alertController, animated: true, completion: nil)
        })
    }

    // delegate should ask user for the export password used to decode the PKCS#12
    func askForCertificatePassword(_ clientCertificateManager: ClientCertificateManager?) {
        DispatchQueue.main.async(execute: {
            let alertController = UIAlertController(title: "Client Certificate Import", message: "Password required for import.", preferredStyle: .alert)
            let okay = UIAlertAction(title: "Okay", style: .default) { (action: UIAlertAction) in
                let txtField = alertController.textFields?.first
                let password = txtField?.text
                clientCertificateManager!.clientCertificateAccepted(password: password)
            }
            let cancel = UIAlertAction(title: "Cancel", style: .cancel) { (action: UIAlertAction) in
                clientCertificateManager!.clientCertificateRejected()
            }
            alertController.addTextField { (textField) in
                textField.placeholder = "Password"
                textField.isSecureTextEntry = true
            }
            alertController.addAction(okay)
            alertController.addAction(cancel)
            self.present(alertController, animated: true, completion: nil)
        })
    }

    // delegate should alert the user that an error occured importing the certificate
    func alertClientCertificateError(_ clientCertificateManager: ClientCertificateManager?, errMsg: String) {
        DispatchQueue.main.async(execute: {
            let alertController = UIAlertController(title: "Client Certificate Import", message: errMsg, preferredStyle: .alert)
            let okay = UIAlertAction(title: "Okay", style: .default)
            alertController.addAction(okay)
            self.present(alertController, animated: true, completion: nil)
        })
    }
}

// MARK: - ModalHandler
extension OpenHABViewController: ModalHandler {
    func modalDismissed(to: TargetController) {
        switch to {
        case .root:
            navigationController?.popToRootViewController(animated: true)
        case .settings:
            if let newViewController = storyboard?.instantiateViewController(withIdentifier: "OpenHABSettingsViewController") as? OpenHABSettingsViewController {
                navigationController?.pushViewController(newViewController, animated: true)
            }
        case .notifications:
            if navigationController?.visibleViewController is OpenHABNotificationsViewController {
                os_log("Notifications are already open", log: .notifications, type: .info)
            } else {
                if let newViewController = storyboard?.instantiateViewController(withIdentifier: "OpenHABNotificationsViewController") as? OpenHABNotificationsViewController {
                    navigationController?.pushViewController(newViewController, animated: true)
                }
            }
        }
    }
}

// MARK: - UISideMenuNavigationControllerDelegate
extension OpenHABViewController: UISideMenuNavigationControllerDelegate {
    func sideMenuWillAppear(menu: UISideMenuNavigationController, animated: Bool) {
        self.hamburgerButton.setStyle(.arrowRight, animated: animated)

        guard let drawer = menu.viewControllers.first as? OpenHABDrawerTableViewController,
            (drawer.delegate == nil || drawer.openHABRootUrl.isEmpty)
            else {
                return
        }
        drawer.openHABRootUrl = openHABRootUrl
        drawer.delegate = self
        drawer.drawerTableType = .with
    }
}

// MARK: - UITableViewDelegate, UITableViewDataSource
extension OpenHABViewController: UITableViewDelegate, UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if currentPage != nil {
            if isFiltering {
                return filteredPage?.widgets.count ?? 0
            }
            return currentPage?.widgets.count ?? 0
        } else {
            return 0
        }
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return 44.0
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let widget: OpenHABWidget? = relevantPage?.widgets[indexPath.row]
        switch widget?.type {
        case "Frame":
            return widget?.label.count ?? 0 > 0 ? 35.0 : 0
        case "Image", "Chart", "Video":
            return UITableView.automaticDimension
        case "Webview", "Mapview":
            if let height = widget?.height, height.intValue != 0 {
                // calculate webview/mapview height and return it
                let heightValue = (Double(height) ?? 0.0) * 44
                os_log("Webview/Mapview height would be %g", log: .viewCycle, type: .info, heightValue)
                return CGFloat(heightValue)
            } else {
                // return default height for webview/mapview as 8 rows
                return 44.0 * 8
            }
        default: return 44.0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let widget: OpenHABWidget? = relevantWidget(indexPath: indexPath)

        let cell: UITableViewCell

        switch widget?.type {
        case "Frame":
            cell = tableView.dequeueReusableCell(for: indexPath) as FrameUITableViewCell
        case "Switch":
            if widget?.mappings.count ?? 0 > 0 {
                cell = tableView.dequeueReusableCell(for: indexPath) as SegmentedUITableViewCell
                //RollershutterItem changed to Rollershutter in later builds of OH2
            } else if widget?.item?.type == "RollershutterItem" || widget?.item?.type == "Rollershutter" || (widget?.item?.type == "Group" && widget?.item?.groupType == "Rollershutter") {
                cell = tableView.dequeueReusableCell(for: indexPath) as RollershutterUITableViewCell
            } else {
                cell = tableView.dequeueReusableCell(for: indexPath) as SwitchUITableViewCell
            }
        case "Setpoint":
            cell = tableView.dequeueReusableCell(for: indexPath) as SetpointUITableViewCell
        case "Slider":
            cell = tableView.dequeueReusableCell(for: indexPath) as SliderUITableViewCell
        case "Selection":
            cell = tableView.dequeueReusableCell(for: indexPath) as SelectionUITableViewCell
        case "Colorpicker":
            cell = tableView.dequeueReusableCell(for: indexPath) as ColorPickerUITableViewCell
            (cell as? ColorPickerUITableViewCell)?.delegate = self
        case "Image", "Chart":
            cell = tableView.dequeueReusableCell(withIdentifier: OpenHABViewControllerImageViewCellReuseIdentifier, for: indexPath) as! NewImageUITableViewCell
            (cell as? NewImageUITableViewCell)?.didLoad = { [weak self] in
                self?.updateWidgetTableView()
            }
        case "Video":
            cell = tableView.dequeueReusableCell(withIdentifier: "VideoUITableViewCell", for: indexPath) as! VideoUITableViewCell
            (cell as? VideoUITableViewCell)?.didLoad = { [weak self] in
                self?.updateWidgetTableView()
            }
        case "Webview":
            cell = tableView.dequeueReusableCell(for: indexPath) as WebUITableViewCell
        case "Mapview":
            cell = (tableView.dequeueReusableCell(withIdentifier: OpenHABViewControllerMapViewCellReuseIdentifier) as? MapViewTableViewCell)!
        default:
            cell = tableView.dequeueReusableCell(for: indexPath) as GenericUITableViewCell
        }

        // No icon is needed for image, video, frame and web widgets
        if (widget?.icon != nil) && !( (cell is NewImageUITableViewCell) || (cell is VideoUITableViewCell) || (cell is FrameUITableViewCell) || (cell is WebUITableViewCell) ) {

            let urlc = Endpoint.icon(rootUrl: openHABRootUrl,
                                     version: appData?.openHABVersion ?? 2,
                                     icon: widget?.icon,
                                     value: widget?.item?.state ?? "",
                                     iconType: iconType).url
            switch iconType {
            case .png :
                cell.imageView?.sd_setImage(with: urlc, placeholderImage: UIImage(named: "blankicon.png"), options: .imageOptionsIgnoreInvalidCertIfDefined)
            case .svg:
                let SVGCoder = SDImageSVGCoder.shared
                SDImageCodersManager.shared.addCoder(SVGCoder)
                cell.imageView?.sd_setImage(with: urlc, placeholderImage: UIImage(named: "blankicon.png"), options: .imageOptionsIgnoreInvalidCertIfDefined)
            }
        }

        if cell is FrameUITableViewCell {
            cell.backgroundColor = UIColor.groupTableViewBackground
        } else {
            cell.backgroundColor = UIColor.white
        }

        if let cell = cell as? GenericUITableViewCell {
            cell.widget = widget
            cell.displayWidget()
        }

        // Check if this is not the last row in the widgets list
        if indexPath.row < (relevantPage?.widgets.count ?? 1) - 1 {

            let nextWidget: OpenHABWidget? = relevantPage?.widgets[indexPath.row + 1]
            if nextWidget?.type == "Frame" || nextWidget?.type == "Image" || nextWidget?.type == "Video" || nextWidget?.type == "Webview" || nextWidget?.type == "Chart" {
                cell.separatorInset = UIEdgeInsets.zero
            } else if !(widget?.type == "Frame") {
                cell.separatorInset = UIEdgeInsets(top: 0, left: 60, bottom: 0, right: 0)
            }
        }

        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Prevent the cell from inheriting the Table View's margin settings
        cell.preservesSuperviewLayoutMargins = false

        // Explictly set your cell's layout margins
        cell.layoutMargins = .zero

        guard let videoCell = (cell as? VideoUITableViewCell) else { return }
        videoCell.playerView.player?.play()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let widget: OpenHABWidget? = relevantWidget(indexPath: indexPath)
        if widget?.linkedPage != nil {
            if let link = widget?.linkedPage?.link {
                os_log("Selected %{PUBLIC}@", log: .viewCycle, type: .info, link)
            }
            selectedWidgetRow = indexPath.row
            let newViewController = (storyboard?.instantiateViewController(withIdentifier: "OpenHABPageViewController") as? OpenHABViewController)!
            newViewController.title = widget?.linkedPage?.title.components(separatedBy: "[")[0]
            newViewController.pageUrl = widget?.linkedPage?.link ?? ""
            newViewController.openHABRootUrl = openHABRootUrl
            navigationController?.pushViewController(newViewController, animated: true)
        } else if widget?.type == "Selection" {
            os_log("Selected selection widget", log: .viewCycle, type: .info)

            selectedWidgetRow = indexPath.row
            let selectionViewController = (storyboard?.instantiateViewController(withIdentifier: "OpenHABSelectionTableViewController") as? OpenHABSelectionTableViewController)!
            let selectedWidget: OpenHABWidget? = relevantWidget(indexPath: indexPath)
            selectionViewController.title = selectedWidget?.labelText
            selectionViewController.mappings = (selectedWidget?.mappings)!
            selectionViewController.delegate = self
            selectionViewController.selectionItem = selectedWidget?.item
            navigationController?.pushViewController(selectionViewController, animated: true)
        }
        if let index = widgetTableView.indexPathForSelectedRow {
            widgetTableView.deselectRow(at: index, animated: false)
        }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // invalidate cache only if the cell is not visible
        if let cell = cell as? GenericCellCacheProtocol, let indexPath = tableView.indexPath(for: cell), let visibleIndexPaths = tableView.indexPathsForVisibleRows, !visibleIndexPaths.contains(indexPath) {
            cell.invalidateCache()
        }
    }
}
