import ApplicationServices
import CoreGraphics
import Foundation

/// Where the window server keeps a window right now.
enum WindowServerPlacement: Equatable {
    /// On a Space that is visible on some display.
    case onScreen
    /// Still open but not visible: another desktop, a full-screen Space, minimized or a hidden app.
    case offScreen
    /// Closed, or the number now belongs to another process.
    case missing
}

enum WindowServerFocusResult: Equatable {
    case focused
    case unavailable
    case failed(step: String, code: Int32)
}

/// Window-server facts and focus for a single CoreGraphics window. Replaceable so tests never
/// touch real windows.
struct WindowServerWindowAccess {
    var windowInfo: (UInt32) -> [String: Any]?
    var focus: (UInt32, Int32) -> WindowServerFocusResult

    static let live = WindowServerWindowAccess(
        windowInfo: { windowID in
            (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]])?.first
        },
        focus: { windowID, processIdentifier in
            WindowServerFocus.focus(windowID: windowID, processIdentifier: processIdentifier)
        }
    )

    func placement(of windowID: UInt32, ownedBy processIdentifier: Int32) -> WindowServerPlacement {
        WindowServerPlacement(windowInfo: windowInfo(windowID), processIdentifier: processIdentifier)
    }
}

extension WindowServerPlacement {
    init(windowInfo: [String: Any]?, processIdentifier: Int32) {
        guard let windowInfo,
              (windowInfo[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier
        else {
            self = .missing
            return
        }
        // The key is only present while the window is on a visible Space.
        let isOnScreen = (windowInfo[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
        self = isOnScreen ? .onScreen : .offScreen
    }
}

/// Brings one window, and the Space that holds it, to the front through SkyLight, the window
/// server's private client framework. AX only reaches windows of the current Space, so this is the
/// only way to switch to a full-screen window or one on another desktop. The sequence is the one
/// AltTab and yabai use: make the owner frontmost for that window, then post the two
/// "make key window" event records. Symbols are resolved at runtime; if a macOS release drops
/// them, activation falls back to the AX path and app activation.
enum WindowServerFocus {
    private typealias GetProcessForPIDFunction = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus
    private typealias SetFrontProcessFunction = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError
    private typealias PostEventRecordFunction = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError

    private struct Functions {
        let getProcessForPID: GetProcessForPIDFunction
        let setFrontProcess: SetFrontProcessFunction
        let postEventRecord: PostEventRecordFunction
    }

    /// kCPSUserGenerated: the switch is treated as user intent, so macOS follows it to the window's Space.
    private static let userGeneratedMode: UInt32 = 0x200

    private static let functions: Functions? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let getProcess = dlsym(defaultHandle, "GetProcessForPID"),
              let setFront = dlsym(defaultHandle, "_SLPSSetFrontProcessWithOptions"),
              let postEvent = dlsym(defaultHandle, "SLPSPostEventRecordTo")
        else { return nil }
        return Functions(
            getProcessForPID: unsafeBitCast(getProcess, to: GetProcessForPIDFunction.self),
            setFrontProcess: unsafeBitCast(setFront, to: SetFrontProcessFunction.self),
            postEventRecord: unsafeBitCast(postEvent, to: PostEventRecordFunction.self)
        )
    }()

    static func focus(windowID: UInt32, processIdentifier: Int32) -> WindowServerFocusResult {
        guard let functions else { return .unavailable }

        var process = ProcessSerialNumber()
        let processStatus = functions.getProcessForPID(processIdentifier, &process)
        guard processStatus == 0 else { return .failed(step: "process", code: processStatus) }

        let frontError = functions.setFrontProcess(&process, CGWindowID(windowID), userGeneratedMode)
        guard frontError == .success else { return .failed(step: "front-process", code: frontError.rawValue) }

        for var record in makeKeyWindowRecords(windowID: windowID) {
            let postError = record.withUnsafeMutableBufferPointer { bytes in
                functions.postEventRecord(&process, bytes.baseAddress!)
            }
            guard postError == .success else { return .failed(step: "key-window", code: postError.rawValue) }
        }
        return .focused
    }

    /// Two 0xF8-byte event records (kinds 1 and 2) addressed to the window, as reverse-engineered by
    /// the Hammerspoon and yabai projects.
    static func makeKeyWindowRecords(windowID: UInt32) -> [[UInt8]] {
        [UInt8(0x01), UInt8(0x02)].map { kind in
            var bytes = [UInt8](repeating: 0, count: 0xF8)
            bytes[0x04] = 0xF8
            bytes[0x08] = kind
            bytes[0x3A] = 0x10
            withUnsafeBytes(of: windowID.littleEndian) { bytes.replaceSubrange(0x3C..<0x40, with: $0) }
            for index in 0x20..<0x30 { bytes[index] = 0xFF }
            return bytes
        }
    }
}
