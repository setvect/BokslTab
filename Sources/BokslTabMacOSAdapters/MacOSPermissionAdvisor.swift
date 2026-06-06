import ApplicationServices
import BokslTabCore
import CoreGraphics
import Foundation

public final class MacOSPermissionAdvisor: PermissionAdvising {
    public init() {}

    @discardableResult
    public func requestAccessibilityPrompt() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public var accessibility: PermissionState {
        AXIsProcessTrusted()
            ? .allowed
            : .denied(reason: "시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 BokslTab을 허용해야 창 단위 전환을 시도할 수 있습니다.")
    }

    public var screenMetadata: PermissionState {
        guard let infoList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return .unknown
        }

        guard !infoList.isEmpty else { return .unknown }

        let hasSomeWindowTitle = infoList.contains { info in
            (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        return hasSomeWindowTitle
            ? .allowed
            : .denied(reason: "창 제목 메타데이터가 비어 있습니다. macOS 버전에 따라 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록 권한이 필요할 수 있습니다.")
    }
}
