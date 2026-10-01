import XCTest
import BokslTabCore
@testable import BokslTabApp
@testable import BokslTabMacOSAdapters

final class SwitcherCoordinatorTests: XCTestCase {
    func testPartialRegistrationFailureActuallyRestoresPrimaryHotkey() async {
        await MainActor.run {
            let carbon = FakeCarbon()
            let service = PrioritizedGlobalHotkeyService(commandTabEventTapService: FakeEventTap(), fallbackHotkeyService: carbon, nativeCommandTabHotkeyService: FakeNative())
            let coordinator = SwitcherCoordinator(runningAppProvider: FakeRunningApps(), windowCatalogProvider: FakeCatalog(), appActivator: FakeActivator(), windowActivator: FakeActivator(), permissionAdvisor: FakePermissions(), mruOrderingProvider: FakeMRU(), hotkeyService: service)
            coordinator.start()
            XCTAssertEqual(carbon.startCalls, 2)
            XCTAssertEqual(carbon.registrations, 1)
            coordinator.stop()
            XCTAssertEqual(carbon.registrations, 0)
        }
    }
}

final class FakeRunningApps: RunningAppProviding {
    func runningApps() -> [AppIdentity] { [] }
    func frontmostApp() -> AppIdentity? { nil }
}
final class FakeCatalog: WindowCatalogProviding {
    func windowsForAllApps() -> [WindowIdentity] { [] }
    func windows(for app: AppIdentity) -> [WindowIdentity] { [] }
}
final class FakeActivator: AppActivating, WindowActivating {
    func activate(app: AppIdentity, intent: AppActivationIntent) -> SwitchResult { .appActivationSuccess }
    @MainActor func activate(window: WindowIdentity, app: AppIdentity) async -> SwitchResult { .exactWindowSuccess }
}
final class FakePermissions: PermissionAdvising {
    var accessibility: PermissionState { .allowed }
    var screenMetadata: PermissionState { .allowed }
}
final class FakeMRU: SwitcherMRUOrderingProviding {
    func orderingContext(for mode: SwitcherMode, items: [SwitcherItem]) -> SwitcherMRUOrderingContext { .fallback(reason: "test") }
}
final class FakeCarbon: GlobalHotkeyServicing {
    var registrations = 0
    var startCalls = 0
    func start(definitions: [HotkeyDefinition], onTrigger: @escaping @Sendable (SwitcherMode) -> Void) throws {
        startCalls += 1
        registrations = definitions.filter { $0.mode == .allAppsAndWindows }.count
        if let option = definitions.first(where: { $0.mode == .activeAppWindows }) {
            throw HotkeyRegistrationError.partialRegistrationFailed(failures: [.init(definition: option, code: -1)])
        }
    }
    func stop() { registrations = 0 }
}
final class FakeEventTap: CommandTabEventTapHotkeyServicing {
    func start(definition: HotkeyDefinition, onTrigger: @escaping @Sendable (SwitcherMode) -> Void) throws {}
    func stop() {}
}
final class FakeNative: NativeCommandTabHotkeyServicing {
    func disableCommandTabPair() -> Bool { true }
    func restore() {}
}
