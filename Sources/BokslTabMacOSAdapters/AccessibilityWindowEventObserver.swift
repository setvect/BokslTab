import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

struct AccessibilityEventObservedAppDescriptor: Hashable {
    let processIdentifier: Int32
    let ownerName: String?

    init(processIdentifier: Int32, ownerName: String? = nil) {
        self.processIdentifier = processIdentifier
        self.ownerName = ownerName?.nonBlankCatalogTitle
    }
}

/// Watches apps with native window tabs for the window that takes focus.
///
/// An unselected tab (an IntelliJ project, a Finder tab) is a window AX no longer lists. The moment it
/// is focused is the only time its number, title and handle can be read, also when the switcher was
/// never opened meanwhile. They go to the shared window registry and handle cache, where the window
/// stays known by its number once it is a tab again.
final class AccessibilityWindowEventObserver {
    private weak var accessibility: MacOSAccessibilityService?

    init(accessibility: MacOSAccessibilityService) {
        self.accessibility = accessibility
        self.workerQueue = accessibility.workerQueue
    }

    deinit {
        let registrations = Array(observersByPID.values)
        // Keep callback contexts alive until removal on the callback's run loop.
        DispatchQueue.main.async {
            for registration in registrations {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), registration.source, .commonModes)
            }
        }
    }

    private final class ObserverContext {
        weak var observer: AccessibilityWindowEventObserver?
        init(observer: AccessibilityWindowEventObserver) { self.observer = observer }
    }

    private struct ObserverRegistration {
        let observer: AXObserver
        let appElement: AXUIElement
        let source: CFRunLoopSource
        let context: ObserverContext
    }

    private static let notifications: [CFString] = [
        kAXMainWindowChangedNotification as CFString,
        kAXFocusedWindowChangedNotification as CFString,
        kAXWindowCreatedNotification as CFString
    ]
    /// An app is often too busy to answer right when it changes windows; the event is tried again.
    private static let maximumEventAttempts = 4

    let workerQueue: DispatchQueue
    private let lock = NSLock()
    private var pendingEventPIDs = Set<Int32>()
    private var observersByPID: [Int32: ObserverRegistration] = [:]
    private var ownerNameByPID: [Int32: String] = [:]

    func scheduleObserverPruning(to desiredPIDs: Set<Int32>) {
        workerQueue.async { [weak self] in self?.removeObserversMissing(from: desiredPIDs) }
    }

    func ensureObserver(for descriptor: AccessibilityEventObservedAppDescriptor, query: AccessibilityQueryBudget) {
        if let ownerName = descriptor.ownerName {
            setOwnerName(ownerName, for: descriptor.processIdentifier)
        }
        guard observersByPID[descriptor.processIdentifier] == nil else { return }
        addObserver(for: descriptor, query: query)
    }

    /// Records the windows the app lists right now; called when its details are refreshed.
    func recordCurrentWindows(for processIdentifier: Int32, query: AccessibilityQueryBudget) {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        let windows = currentWindows(from: appElement, query: query).windows
        guard !query.isExhausted else { return }
        record(windows: windows, processIdentifier: processIdentifier, source: "refresh", query: query)
    }

    private func addObserver(for descriptor: AccessibilityEventObservedAppDescriptor, query: AccessibilityQueryBudget) {
        let appElement = AXUIElementCreateApplication(descriptor.processIdentifier)
        var rawObserver: AXObserver?
        let createError = AXObserverCreate(
            descriptor.processIdentifier,
            AccessibilityWindowEventObserver.observerCallback,
            &rawObserver
        )
        guard createError == .success, let observer = rawObserver else {
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-event.observer failed pid=\(descriptor.processIdentifier) error=\(createError.rawValue)"
            )
            return
        }

        let context = ObserverContext(observer: self)
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        var addedNotifications: [String] = []
        for notification in Self.notifications {
            let addError = query.withTimeout(on: appElement) {
                AXObserverAddNotification(observer, appElement, notification, refcon)
            }
            if query.isExhausted { break }
            if addError == .success {
                addedNotifications.append(notification as String)
            } else {
                BokslTabDiagnosticLog.debug(
                    "window-catalog.ax-event.notification failed pid=\(descriptor.processIdentifier) name=\(notification) error=\(addError.rawValue)"
                )
            }
        }

        guard !addedNotifications.isEmpty else {
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-event.observer skipped pid=\(descriptor.processIdentifier) reason=no-notifications"
            )
            return
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        observersByPID[descriptor.processIdentifier] = ObserverRegistration(
            observer: observer,
            appElement: appElement,
            source: source,
            context: context
        )
        BokslTabDiagnosticLog.debug(
            "window-catalog.ax-event.observer added pid=\(descriptor.processIdentifier) notifications=\(addedNotifications.joined(separator: ","))"
        )
    }

    private static let observerCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
        context.observer?.scheduleEvent(element: element, notification: notification as String)
    }

    private func scheduleEvent(element: AXUIElement, notification: String) {
        var processIdentifier: pid_t = 0
        let pidError = AXUIElementGetPid(element, &processIdentifier)
        guard pidError == .success, processIdentifier > 0 else {
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-event skipped notification=\(notification) reason=pid-unavailable error=\(pidError.rawValue)"
            )
            return
        }

        let pid = Int32(processIdentifier)
        lock.lock()
        let shouldSchedule = pendingEventPIDs.insert(pid).inserted
        lock.unlock()
        guard shouldSchedule, accessibility != nil else { return }
        workerQueue.async { [weak self] in
            self?.deliverEvent(element: element, notification: notification, processIdentifier: pid, attempt: 1)
        }
    }

    /// While an event waits for another attempt, later events of the app are folded into it: the
    /// attempt reads the app's windows as they are then.
    private func deliverEvent(element: AXUIElement, notification: String, processIdentifier pid: Int32, attempt: Int) {
        func finish() {
            lock.lock()
            pendingEventPIDs.remove(pid)
            lock.unlock()
        }
        guard let accessibility, observersByPID[pid] != nil else { return finish() }
        let handled: Bool? = accessibility.perform(for: pid) { query in
            self.handleEvent(element: element, notification: notification, processIdentifier: pid, query: query)
            return true
        }
        guard handled == nil, attempt < Self.maximumEventAttempts else { return finish() }
        workerQueue.asyncAfter(deadline: .now() + accessibility.secondsUntilRetry(pid) + 0.05) { [weak self] in
            self?.deliverEvent(element: element, notification: notification, processIdentifier: pid, attempt: attempt + 1)
        }
    }

    /// Not private so tests can deliver an event without a live AX observer.
    func handleEvent(element: AXUIElement, notification: String, processIdentifier pid: Int32, query: AccessibilityQueryBudget) {
        var windows: [AXUIElement] = []
        if isWindowElement(element, query: query) {
            windows.append(element)
        }
        let current = currentWindows(from: AXUIElementCreateApplication(pid), query: query)
        windows.append(contentsOf: current.windows)
        guard !query.isExhausted else { return }
        record(windows: windows, processIdentifier: pid, source: notification, query: query)

        // The app's focused window is asked for, not taken from the event: a retried or folded event
        // may be older than the window that has focus now.
        guard let focusedWindow = current.focused,
              let windowID = query.windowID(of: focusedWindow)
        else { return }
        accessibility?.windowFocusHandler?(windowID, pid)
    }

    private func currentWindows(
        from appElement: AXUIElement,
        query: AccessibilityQueryBudget
    ) -> (windows: [AXUIElement], focused: AXUIElement?) {
        var windows: [AXUIElement] = []
        var focused: AXUIElement?
        var rawWindows: CFTypeRef?
        let windowsError = query.copyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        )
        if windowsError == .success, let axWindows = rawWindows as? [AXUIElement] {
            windows.append(contentsOf: axWindows)
        }

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var rawWindow: CFTypeRef?
            let error = query.copyAttributeValue(appElement, attribute as CFString, &rawWindow)
            guard error == .success,
                  let rawWindow,
                  CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
            else { continue }
            let window = rawWindow as! AXUIElement
            windows.append(window)
            if focused == nil { focused = window }
        }
        return (windows, focused)
    }

    /// A window without a readable number cannot be told apart from its siblings and is left out.
    private func record(
        windows: [AXUIElement],
        processIdentifier: Int32,
        source: String,
        query: AccessibilityQueryBudget
    ) {
        guard let accessibility else { return }
        var recordedWindowIDs = Set<UInt32>()
        for window in windows {
            guard let windowID = query.windowID(of: window),
                  recordedWindowIDs.insert(windowID).inserted,
                  let title = AccessibilityWindowSnapshot.title(of: window, query: query)?.nonBlankCatalogTitle,
                  !TabTitlePolicy.isPlaceholderTitle(title),
                  let frame = query.reader.frame(of: window),
                  WindowSnapshot.isReasonableWindowBounds(frame)
            else { continue }
            let isMinimized = query.reader.bool(from: window, attribute: kAXMinimizedAttribute)
            guard !query.isExhausted else { return }
            accessibility.knownWindows.record(
                windowID: windowID,
                processIdentifier: processIdentifier,
                title: title,
                ownerName: ownerName(for: processIdentifier),
                isMinimized: isMinimized
            )
            accessibility.windowElements.record(window, windowID: windowID, processIdentifier: processIdentifier)
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-event.record pid=\(processIdentifier) window=\(windowID) source=\(source) title=\(title.catalogDiagnosticValue)"
            )
        }
    }

    private func setOwnerName(_ ownerName: String, for processIdentifier: Int32) {
        lock.lock()
        ownerNameByPID[processIdentifier] = ownerName
        lock.unlock()
    }

    private func ownerName(for processIdentifier: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return ownerNameByPID[processIdentifier]
    }

    private func removeObserversMissing(from desiredPIDs: Set<Int32>) {
        let stalePIDs = observersByPID.keys.filter { !desiredPIDs.contains($0) }
        for processIdentifier in stalePIDs {
            removeObserver(processIdentifier: processIdentifier, reason: "not-eligible")
        }
    }

    private func removeObserver(processIdentifier: Int32, reason: String) {
        guard let registration = observersByPID.removeValue(forKey: processIdentifier) else { return }
        DispatchQueue.main.async {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), registration.source, .commonModes)
            _ = registration.context
        }
        lock.lock()
        ownerNameByPID.removeValue(forKey: processIdentifier)
        lock.unlock()
        BokslTabDiagnosticLog.debug(
            "window-catalog.ax-event.observer removed pid=\(processIdentifier) reason=\(reason)"
        )
    }

    private func isWindowElement(_ element: AXUIElement, query: AccessibilityQueryBudget) -> Bool {
        var rawRole: CFTypeRef?
        guard query.copyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
              let role = rawRole as? String
        else { return false }
        return role == kAXWindowRole
    }
}
