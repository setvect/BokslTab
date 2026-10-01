import ApplicationServices
import AppKit
import BokslTabCore
import CoreGraphics
import Foundation

final class AccessibilityWindowEventCache {
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

    private struct StoredWindow {
        let entry: AccessibilityEventWindowCacheEntry
        let element: AXUIElement
    }

    private final class ObserverContext {
        weak var cache: AccessibilityWindowEventCache?
        init(cache: AccessibilityWindowEventCache) { self.cache = cache }
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
    private static let maximumEntriesPerProcess = 32

    let workerQueue: DispatchQueue
    private let lock = NSLock()
    private var pendingEventPIDs = Set<Int32>()
    private var windowsByPID: [Int32: [UInt32: StoredWindow]] = [:]
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

    func seedCurrentWindows(for processIdentifiers: Set<Int32>, query: AccessibilityQueryBudget) {
        guard AXIsProcessTrusted(), !processIdentifiers.isEmpty else { return }
        for processIdentifier in processIdentifiers.sorted() {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            let windows = currentWindows(from: appElement, processIdentifier: processIdentifier, query: query)
            guard !query.isExhausted else { continue }
            replace(windows: windows, processIdentifier: processIdentifier, source: "seed", query: query)
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-event-cache.seed pid=\(processIdentifier) windows=\(windows.count)"
            )
        }
    }

    func snapshots(
        for eligiblePIDs: Set<Int32>,
        excluding includedSnapshots: [WindowSnapshot]
    ) -> [WindowSnapshot] {
        let entries = cachedEntries()
        return AccessibilityEventWindowSnapshotPolicy.snapshots(
            from: entries,
            eligiblePIDs: eligiblePIDs,
            excluding: includedSnapshots
        )
    }

    func window(matching window: WindowIdentity, app: AppIdentity) -> AXUIElement? {
        lock.lock()
        let storedWindows = windowsByPID[app.processIdentifier].map { Array($0.values) } ?? []
        lock.unlock()

        guard !storedWindows.isEmpty else { return nil }
        if let exact = storedWindows.first(where: { $0.entry.windowID == window.windowID }) {
            return exact.element
        }

        guard let targetTitle = window.title?.nonBlankCatalogTitle else { return nil }
        let titleMatches = storedWindows.filter {
            $0.entry.title.nonBlankCatalogTitle == targetTitle
        }
        guard titleMatches.count == 1 else { return nil }
        return titleMatches[0].element
    }

    private func addObserver(for descriptor: AccessibilityEventObservedAppDescriptor, query: AccessibilityQueryBudget) {
        let appElement = AXUIElementCreateApplication(descriptor.processIdentifier)
        var rawObserver: AXObserver?
        let createError = AXObserverCreate(
            descriptor.processIdentifier,
            AccessibilityWindowEventCache.observerCallback,
            &rawObserver
        )
        guard createError == .success, let observer = rawObserver else {
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-event-cache.observer failed pid=\(descriptor.processIdentifier) error=\(createError.rawValue)"
            )
            return
        }

        let context = ObserverContext(cache: self)
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
                    "window-catalog.ax-event-cache.notification failed pid=\(descriptor.processIdentifier) name=\(notification) error=\(addError.rawValue)"
                )
            }
        }

        guard !addedNotifications.isEmpty else {
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-event-cache.observer skipped pid=\(descriptor.processIdentifier) reason=no-notifications"
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
            "window-catalog.ax-event-cache.observer added pid=\(descriptor.processIdentifier) notifications=\(addedNotifications.joined(separator: ","))"
        )
    }

    private static let observerCallback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
        context.cache?.scheduleEvent(element: element, notification: notification as String)
    }

    private func scheduleEvent(element: AXUIElement, notification: String) {
        var processIdentifier: pid_t = 0
        let pidError = AXUIElementGetPid(element, &processIdentifier)
        guard pidError == .success, processIdentifier > 0 else {
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-event-cache.event skipped notification=\(notification) reason=pid-unavailable error=\(pidError.rawValue)"
            )
            return
        }

        let pid = Int32(processIdentifier)
        lock.lock()
        let shouldSchedule = pendingEventPIDs.insert(pid).inserted
        lock.unlock()
        guard shouldSchedule, let accessibility else { return }
        workerQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.pendingEventPIDs.remove(pid)
                self.lock.unlock()
            }
            guard self.observersByPID[pid] != nil else { return }
            let _: Void? = accessibility.perform(for: pid) { query in
                self.handleEvent(element: element, notification: notification, processIdentifier: pid, query: query)
            }
        }
    }

    private func handleEvent(element: AXUIElement, notification: String, processIdentifier pid: Int32, query: AccessibilityQueryBudget) {
        var windows: [AXUIElement] = []
        if isWindowElement(element, query: query) {
            windows.append(element)
        }
        windows.append(contentsOf: currentWindows(
            from: AXUIElementCreateApplication(pid),
            processIdentifier: pid, query: query
        ))
        let uniqueWindows = deduplicatedElements(windows, query: query)
        guard !query.isExhausted else { return }
        replace(windows: uniqueWindows, processIdentifier: pid, source: notification, query: query)
        BokslTabDiagnosticLog.debug(
            "window-catalog.ax-event-cache.event notification=\(notification) pid=\(pid) windows=\(uniqueWindows.count)"
        )
    }

    private func currentWindows(
        from appElement: AXUIElement,
        processIdentifier: Int32,
        query: AccessibilityQueryBudget
    ) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        var rawWindows: CFTypeRef?
        let windowsError = query.copyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        )
        if windowsError == .success, let axWindows = rawWindows as? [AXUIElement] {
            windows.append(contentsOf: axWindows)
        }

        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var rawWindow: CFTypeRef?
            let error = query.copyAttributeValue(appElement, attribute as CFString, &rawWindow)
            guard error == .success,
                  let rawWindow,
                  CFGetTypeID(rawWindow) == AXUIElementGetTypeID()
            else { continue }
            windows.append(rawWindow as! AXUIElement)
        }

        let uniqueWindows = deduplicatedElements(windows, query: query)
        BokslTabDiagnosticLog.debug(
            "window-catalog.ax-event-cache.current pid=\(processIdentifier) raw=\(windows.count) unique=\(uniqueWindows.count)"
        )
        return uniqueWindows
    }

    private func replace(
        windows: [AXUIElement],
        processIdentifier: Int32,
        source: String,
        query: AccessibilityQueryBudget
    ) {
        let now = Date()
        var nextEntries: [UInt32: StoredWindow] = [:]
        for window in windows {
            guard let entry = cacheEntry(
                for: window,
                processIdentifier: processIdentifier,
                source: source,
                updatedAt: now, query: query
            ) else { continue }
            nextEntries[entry.windowID] = StoredWindow(entry: entry, element: window)
            BokslTabDiagnosticLog.debug(
                "window-catalog.ax-event-cache.record pid=\(processIdentifier) window=\(entry.windowID) source=\(source) title=\(entry.title.catalogDiagnosticValue) frame=\(entry.frame.catalogDiagnosticDescription)"
            )
        }
        guard !query.isExhausted else { return }
        lock.lock()
        let previousCount = windowsByPID[processIdentifier]?.count ?? 0
        let currentEntries = nextEntries.values.map(\.entry)
        let preservedEntries = (windowsByPID[processIdentifier] ?? [:]).filter { windowID, storedWindow in
            guard nextEntries[windowID] == nil else { return false }
            return AccessibilityEventWindowHistoryPolicy.shouldPreserve(
                previous: storedWindow.entry,
                currentEntries: currentEntries
            )
        }
        let prunedEntries = prune(preservedEntries.merging(nextEntries) { _, current in current })
        if prunedEntries.isEmpty {
            windowsByPID.removeValue(forKey: processIdentifier)
        } else {
            windowsByPID[processIdentifier] = prunedEntries
        }
        lock.unlock()
        BokslTabDiagnosticLog.debug(
            "window-catalog.ax-event-cache.replace pid=\(processIdentifier) previous=\(previousCount) current=\(prunedEntries.count) preserved=\(preservedEntries.count) source=\(source)"
        )
    }

    private func cacheEntry(
        for window: AXUIElement,
        processIdentifier: Int32,
        source: String,
        updatedAt: Date,
        query: AccessibilityQueryBudget
    ) -> AccessibilityEventWindowCacheEntry? {
        guard let title = AccessibilityWindowSnapshot.title(of: window, query: query)?.nonBlankCatalogTitle,
              !TabExpandedWindowCatalogPolicy.isPlaceholderTitle(title),
              let frame = query.reader.frame(of: window),
              WindowSnapshot.isReasonableWindowBounds(frame)
        else { return nil }

        let windowID = SyntheticWindowID.accessibilityEvent(
            processIdentifier: processIdentifier,
            title: title,
            frame: frame,
            index: 0
        )
        return AccessibilityEventWindowCacheEntry(
            processIdentifier: processIdentifier,
            windowID: windowID,
            title: title,
            frame: frame,
            ownerName: ownerName(for: processIdentifier),
            source: source,
            updatedAt: updatedAt
        )
    }

    private func cachedEntries() -> [AccessibilityEventWindowCacheEntry] {
        lock.lock()
        defer { lock.unlock() }
        return windowsByPID.values.flatMap { $0.values.map(\.entry) }
    }

    private func setOwnerName(_ ownerName: String, for processIdentifier: Int32) {
        lock.lock()
        ownerNameByPID[processIdentifier] = ownerName
        lock.unlock()
    }

    private func ownerName(for processIdentifier: Int32) -> String? {
        lock.lock()
        let cached = ownerNameByPID[processIdentifier]
        lock.unlock()
        if let cached { return cached }
        return NSRunningApplication(processIdentifier: processIdentifier)?.localizedName
            ?? NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
    }

    private func prune(_ entries: [UInt32: StoredWindow]) -> [UInt32: StoredWindow] {
        guard entries.count > Self.maximumEntriesPerProcess else { return entries }
        let kept = entries.values
            .sorted { lhs, rhs in lhs.entry.updatedAt > rhs.entry.updatedAt }
            .prefix(Self.maximumEntriesPerProcess)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.entry.windowID, $0) })
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
        windowsByPID.removeValue(forKey: processIdentifier)
        ownerNameByPID.removeValue(forKey: processIdentifier)
        lock.unlock()
        BokslTabDiagnosticLog.debug(
            "window-catalog.ax-event-cache.observer removed pid=\(processIdentifier) reason=\(reason)"
        )
    }

    private func isWindowElement(_ element: AXUIElement, query: AccessibilityQueryBudget) -> Bool {
        var rawRole: CFTypeRef?
        guard query.copyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
              let role = rawRole as? String
        else { return false }
        return role == kAXWindowRole
    }

    private func deduplicatedElements(_ elements: [AXUIElement], query: AccessibilityQueryBudget) -> [AXUIElement] {
        var seen = Set<String>()
        return elements.filter { element in
            let title = AccessibilityWindowSnapshot.title(of: element, query: query)?.nonBlankCatalogTitle ?? ""
            let frame = query.reader.frame(of: element)?.catalogDiagnosticDescription ?? ""
            let key = "\(title)|\(frame)"
            return seen.insert(key).inserted
        }
    }
}
