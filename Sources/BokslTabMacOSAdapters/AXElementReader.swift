import ApplicationServices
import CoreGraphics
import Foundation

enum AXElementReader {
    static func firstString(from element: AXUIElement, attributes: [String]) -> String? {
        attributes.lazy.compactMap { attribute in
            rawAccessibilityValue(element, attribute: attribute) as? String
        }.compactMap(\.nonBlankAXValue).first
    }

    static func bool(from element: AXUIElement, attribute: String) -> Bool {
        let rawValue = rawAccessibilityValue(element, attribute: attribute)
        if let value = rawValue as? Bool { return value }
        return (rawValue as? NSNumber)?.boolValue ?? false
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let origin: CGPoint = accessibilityValue(element, attribute: kAXPositionAttribute),
              let size: CGSize = accessibilityValue(element, attribute: kAXSizeAttribute)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func accessibilityValue<T>(_ element: AXUIElement, attribute: String) -> T? {
        rawAccessibilityValue(element, attribute: attribute).flatMap(convert)
    }

    private static func rawAccessibilityValue(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var rawValue: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success ? rawValue : nil
    }

    private static func convert<T>(_ rawValue: CFTypeRef) -> T? {
        guard CFGetTypeID(rawValue) == AXValueGetTypeID(), let type = T.self as? AXValueConvertible.Type else {
            return rawValue as? T
        }
        return type.value(from: rawValue as! AXValue) as? T
    }
}

private protocol AXValueConvertible { static func value(from axValue: AXValue) -> Any? }

extension CGPoint: AXValueConvertible {
    fileprivate static func value(from axValue: AXValue) -> Any? {
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }
}

extension CGSize: AXValueConvertible {
    fileprivate static func value(from axValue: AXValue) -> Any? {
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}

private extension String {
    var nonBlankAXValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
