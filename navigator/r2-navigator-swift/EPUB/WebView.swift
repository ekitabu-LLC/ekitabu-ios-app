//
//  WebView.swift
//  r2-navigator-swift
//
//  Created by Winnie Quinn, Alexandre Camilleri on 8/23/17.
//
//  Copyright 2018 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import WebKit

import R2Shared

protocol WebViewDelegate: class {
    func willAnimatePageChange()
    func didEndPageAnimation()
    func displayRightDocument(animated: Bool, completion: @escaping () -> Void)
    func displayLeftDocument(animated: Bool, completion: @escaping () -> Void)
    func webView(_ webView: WebView, didTapAt point: CGPoint)
    func publicationBaseUrl() -> URL?
    func handleTapOnLink(with url: URL)
    func handleTapOnInternalLink(with href: String)
    func documentPageDidChange(webView: WebView, currentPage: Int ,totalPage: Int)
}

class WebView: UIView, Loggable {
    
    weak var viewDelegate: WebViewDelegate?
    fileprivate let initialLocation: BinaryLocation
    
    let baseURL: URL
    let webView: WKWebView

    let readingProgression: ReadingProgression

    /// If YES, the content will be fade in once loaded.
    let animatedLoad: Bool
    
    let contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]
    var editingActions: EditingActionsController
  
    weak var activityIndicatorView: UIActivityIndicatorView?

    var initialId: String?
    // progression and totalPages only work on 'readium-scroll-off' mode
    var progression: Double?
    var totalPages: Int?
    func currentPage() -> Int {
        guard progression != nil && totalPages != nil else {
            return 1
        }
        return Int(progression! * Double(totalPages!)) + 1
    }
    
    var userSettings: UserSettings? {
        didSet {
            guard let userSettings = userSettings else { return }
            updateActivityIndicator(for: userSettings)
        }
    }

    var documentLoaded = false

    var hasLoadedJsEvents = false
    
    var jsEvents: [String: (Any) -> Void] {
        return [
            "tap": didTap,
            "didLoad": documentDidLoad,
            "updateProgression": progressionDidChange
        ]
    }
    
    var sizeObservation: NSKeyValueObservation?
    
    private static var gesturesScript: String? = {
        guard let url = Bundle(for: WebView.self).url(forResource: "gestures", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url)
    }();

    required init(baseURL: URL, initialLocation: BinaryLocation, readingProgression: ReadingProgression, animatedLoad: Bool = false, editingActions: EditingActionsController, contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]) {
        self.baseURL = baseURL
        self.initialLocation = initialLocation
        self.readingProgression = readingProgression
        self.animatedLoad = animatedLoad
        self.editingActions = editingActions
        self.webView = WKWebView(frame: .zero, configuration: .init())
        self.contentInset = contentInset
      
        super.init(frame: .zero)
        
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)

        isOpaque = false
        backgroundColor = .clear
        
        setupWebView()

        sizeObservation = scrollView.observe(\.contentSize, options: .new) { [weak self] scrollView, value in
            guard let self = self else {
                return
            }
            // update total pages
            guard self.documentLoaded else { return }
            guard let newWidth = value.newValue?.width else {return}
            let pageWidth = scrollView.frame.size.width
            if pageWidth == 0.0 {return} // Possible zero value
            let pageCount = Int(newWidth / scrollView.frame.size.width);
            if self.totalPages != pageCount {
                self.totalPages = pageCount
                self.viewDelegate?.documentPageDidChange(webView: self, currentPage: self.currentPage(), totalPage: pageCount)
            }
        }
        scrollView.alpha = 0
        
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapBackground)))
        
        if let gesturesScript = WebView.gesturesScript {
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: gesturesScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
    }
    
    deinit {
        sizeObservation = nil  // needs to be deallocated before the scrollView
    }
    
    func setupWebView() {
        webView.backgroundColor = UIColor.clear
        scrollView.backgroundColor = UIColor.clear
        
        webView.allowsBackForwardNavigationGestures = false

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        
        if #available(iOS 11.0, *) {
            // Prevents the pages from jumping down when the status bar is toggled
            scrollView.contentInsetAdjustmentBehavior = .never
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        scrollView.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
  
    var scrollView: UIScrollView {
        return webView.scrollView
    }

    override func didMoveToSuperview() {
        // Fixing an iOS 9 bug by explicitly clearing scrollView.delegate before deinitialization
        if superview == nil {
            scrollView.delegate = nil
        }
        else {
            scrollView.delegate = self
        }
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
    
    /// Evaluates the given JavaScript into the resource's HTML page.
    /// Don't use directly webView.evaluateJavaScript as the resource might be displayed into an iframe in a wrapper HTML page.
    func evaluateScriptInResource(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        webView.evaluateJavaScript(script, completionHandler: completion)
    }
  
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return super.canPerformAction(action, withSender: sender) && editingActions.canPerformAction(action)
    }

    override func copy(_ sender: Any?) {
        guard editingActions.requestCopy() else {
            return
        }
        super.copy(sender)
    }

    private func dismissIfNeeded() {
        self.isUserInteractionEnabled = false
        self.isUserInteractionEnabled = true
    }

    /// Called from the JS code when a tap is detected.
    private func didTap(body: Any) {
        guard let body = body as? [String: Any],
            let x = body["x"] as? Int,
            let y = body["y"] as? Int else
        {
            return
        }

        let point = CGPoint(
            x: CGFloat(x) * scrollView.zoomScale - scrollView.contentOffset.x + webView.frame.minX,
            y: CGFloat(y) * scrollView.zoomScale - scrollView.contentOffset.y + webView.frame.minY
        )
        viewDelegate?.webView(self, didTapAt: point)

        dismissIfNeeded()
    }
    
    /// Called by the UITapGestureRecognizer as a fallback tap when tapping around the webview.
    @objc private func didTapBackground(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        viewDelegate?.webView(self, didTapAt: point)
    }

    /// Called by the javascript code to notify on DocumentReady.
    ///
    /// - Parameter body: Unused.
    private func documentDidLoad(body: Any) {
        documentLoaded = true
        
        // FIXME: We need to give the CSS and webview time to layout correctly. 0.2 seconds seems like a good value for it to work on an iPhone 5s. Look into solving this better
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.activityIndicatorView?.stopAnimating()
            UIView.animate(withDuration: self.animatedLoad ? 0.3 : 0, animations: {
                self.scrollView.alpha = 1
            })
        }

        applyUserSettingsStyle()
        scrollToInitialPosition()
        setupDragAndDrop()
    }
    
    // Scroll at position 0-1 (0%-100%)
    func scrollAt(position: Double) {
        guard position >= 0 && position <= 1 else { return }
        
        let dir = readingProgression.rawValue
        evaluateScriptInResource("scrollToPosition(\'\(position)\', \'\(dir)\')")
    }

    // Scroll at the tag with id `tagId`.
    func scrollAt(tagId: String) {
        evaluateScriptInResource("scrollToId(\'\(tagId)\');")
    }

    // Scroll to .beggining or .end.
    func scrollAt(location: BinaryLocation) {
        switch location {
        case .left:
            scrollAt(position: 0)
        case .right:
            scrollAt(position: 1)
        }
    }

    /// Moves the webView to the initial location.
    func scrollToInitialPosition() {
        /// If the savedProgression property has been set by the navigator.
        if let initialPosition = progression, initialPosition > 0.0 {
            scrollAt(position: initialPosition)
        } else if let initialId = initialId {
            scrollAt(tagId: initialId)
        } else {
            scrollAt(location: initialLocation)
        }
    }

    enum ScrollDirection {
        case left
        case right
    }
    
    func scrollTo(_ direction: ScrollDirection, animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        let viewDelegate = self.viewDelegate
        if animated {
            switch direction {
            case .left:
                let isAtFirstPageInDocument = scrollView.contentOffset.x == 0
                if !isAtFirstPageInDocument {
                    viewDelegate?.willAnimatePageChange()
                    scrollView.scrollToPreviousPage(animated: animated, completion: completion)
                    return true
                }
            case .right:
                let isAtLastPageInDocument = scrollView.contentOffset.x == scrollView.contentSize.width - scrollView.frame.size.width
                if !isAtLastPageInDocument {
                    viewDelegate?.willAnimatePageChange()
                    scrollView.scrollToNextPage(animated: animated, completion: completion)
                    return true
                }
            }
        }
        
        let dir = readingProgression.rawValue
        switch direction {
        case .left:
            evaluateScriptInResource("scrollLeft(\"\(dir)\");") { result, error in
                if error == nil, let result = result as? String, result == "edge" {
                    viewDelegate?.displayLeftDocument(animated: animated, completion: completion)
                } else {
                    completion()
                }
            }
        case .right:
            evaluateScriptInResource("scrollRight(\"\(dir)\");") { result, error in
                if error == nil, let result = result as? String, result == "edge" {
                    viewDelegate?.displayRightDocument(animated: animated, completion: completion)
                } else {
                    completion()
                }
            }
        }
        return true
    }

    /// Update webview style to userSettings.
    /// To override in subclasses.
    func applyUserSettingsStyle() {
        assert(Thread.isMainThread, "User settings must be updated from the main thread")
    }
    
    
    // MARK: - Progression change
    
    private var progressionOriginPage: Int?

    // Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(body: Any) {
        guard documentLoaded, let bodyString = body as? String, let newProgression = Double(bodyString) else {
            return
        }
        
        if progressionOriginPage == nil {
            progressionOriginPage = currentPage()
        }
        
        progression = newProgression
    }
    
    @objc private func notifyDocumentPageChange() {
        let page = currentPage()
        guard progressionOriginPage != page, let pages = totalPages else {
            return
        }
        progressionOriginPage = nil
        viewDelegate?.documentPageDidChange(webView: self, currentPage: page, totalPage: pages)
    }

}

// MARK: - WKScriptMessageHandler for handling incoming message from the Bridge.js
// javascript code.
extension WebView: WKScriptMessageHandler {

    // Handles incoming calls from JS.
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let handler = jsEvents[message.name] {
            handler(message.body)
        }
    }

    /// Add a message handler for incoming javascript events.
    func addMessageHandlers() {
        if hasLoadedJsEvents { return }
        // Add the message handlers.
        for eventName in jsEvents.keys {
            webView.configuration.userContentController.add(self, name: eventName)
        }
        hasLoadedJsEvents = true
    }

    // Deinit message handlers (preventing strong reference cycle).
    func removeMessageHandlers() {
        for eventName in jsEvents.keys {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: eventName)
        }
        hasLoadedJsEvents = false
    }
}

extension WebView: WKNavigationDelegate {
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Do not remove: overriden in subclasses.
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let navigationType = navigationAction.navigationType

        if navigationType == .linkActivated {
            if let url = navigationAction.request.url {
                // TO/DO add URL normalisation.
                //check url if internal or external
                let publicationBaseUrl = viewDelegate?.publicationBaseUrl()

                if url.host == publicationBaseUrl?.host,
                    let baseUrlString = publicationBaseUrl?.absoluteString {
                    // Internal link.
                    let href = url.absoluteString.replacingOccurrences(of: baseUrlString, with: "")
                    viewDelegate?.handleTapOnInternalLink(with: href)
                } else {
                    viewDelegate?.handleTapOnLink(with: url)
                }
            }
        }

        decisionHandler(navigationType == .other ? .allow : .cancel)
    }
}

extension WebView: UIScrollViewDelegate {

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isUserInteractionEnabled = true
        viewDelegate?.didEndPageAnimation()
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        viewDelegate?.didEndPageAnimation()
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        viewDelegate?.didEndPageAnimation()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Makes sure we always receive the "ending scroll" event.
        // ie. https://stackoverflow.com/a/1857162/1474476
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyDocumentPageChange), object: nil)
        perform(#selector(notifyDocumentPageChange), with: nil, afterDelay: 0.3)
    }

}

extension WebView: WKUIDelegate {
    
    // The property allowsLinkPreview is default false in iOS9, so it should be safe to use @available(iOS 10.0, *)
    @available(iOS 10.0, *)
    func webView(_ webView: WKWebView, shouldPreviewElement elementInfo: WKPreviewElementInfo) -> Bool {
        let publicationBaseUrl = viewDelegate?.publicationBaseUrl()
        let url = elementInfo.linkURL
        if url?.host == publicationBaseUrl?.host {
            return false
        }
        return true
    }
}

private extension UIScrollView {
    
    func scrollToNextPage(animated: Bool, completion: () -> Void) {
        moveHorizontalContent(with: bounds.size.width, animated: animated, completion: completion)
    }
    
    func scrollToPreviousPage(animated: Bool, completion: () -> Void) {
        moveHorizontalContent(with: -bounds.size.width, animated: animated, completion: completion)
    }
    
    private func moveHorizontalContent(with offsetX: CGFloat, animated: Bool, completion: () -> Void) {
        isUserInteractionEnabled = false
        
        var newOffset = contentOffset
        newOffset.x += offsetX
        let rounded = round(newOffset.x / offsetX) * offsetX
        newOffset.x = rounded
        let area = CGRect.init(origin: newOffset, size: bounds.size)
        scrollRectToVisible(area, animated: animated)
        // FIXME: completion needs to be implemented using scroll view delegate
        completion()
    }
}

private extension WebView {

    func updateActivityIndicator(for userSettings: UserSettings) {
        guard let appearance = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.appearance.rawValue) as? Enumerable else { return }
        guard appearance.values.count > appearance.index else { return }
        let value = appearance.values[appearance.index]
        switch value {
        case "readium-night-on":
            createActivityIndicator(style: .white)
        default:
            createActivityIndicator(style: .gray)
        }
    }
    
    func createActivityIndicator(style: UIActivityIndicatorView.Style) {
        guard documentLoaded,
            activityIndicatorView?.style == style else
        {
            return
        }
        
        activityIndicatorView?.removeFromSuperview()
        let view = UIActivityIndicatorView(style: style)
        view.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(view)
        view.centerXAnchor.constraint(equalTo: self.centerXAnchor).isActive = true
        view.centerYAnchor.constraint(equalTo: self.centerYAnchor).isActive = true
        view.startAnimating()
        activityIndicatorView = view
    }
    
    func setupDragAndDrop() {
        if !editingActions.canCopy {
            guard #available(iOS 11.0, *),
                let webScrollView = subviews.compactMap( { $0 as? UIScrollView }).first,
                let contentView = webScrollView.subviews.first(where: { $0.interactions.count > 1 }),
                let dragInteraction = contentView.interactions.compactMap({ $0 as? UIDragInteraction }).first else
            {
                return
            }
            contentView.removeInteraction(dragInteraction)
        }
    }
    
}
