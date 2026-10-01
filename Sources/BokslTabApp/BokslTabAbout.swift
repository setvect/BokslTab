import AppKit

@MainActor
enum BokslTabAbout {
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 2
        let credits = NSAttributedString(
            string: "BokslTab은 키보드로 앱과 창을 빠르게 전환하는\nmacOS 메뉴바 프로그램입니다.\n\nCommand + Tab · 모든 앱/창 전환\nOption + Tab · 활성 앱 창 전환\n\n빌드 날짜: \(buildDateDescription)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "BokslTab",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            .version: "",
            .credits: credits
        ]
        let resources = Bundle.main.url(forResource: "BokslTab_BokslTabApp", withExtension: "bundle")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
        if let url = resources.url(forResource: "AboutBoksl", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            options[.applicationIcon] = image
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static var buildDateDescription: String {
        // Packaged apps carry a build timestamp. Direct SwiftPM runs use the linked binary's date.
        let timestamp = Bundle.main.object(forInfoDictionaryKey: "BokslTabBuildDate") as? String
        let packagedDate = timestamp.flatMap { ISO8601DateFormatter().date(from: $0) }
        let executableDate = Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        guard let date = packagedDate ?? executableDate else { return "확인할 수 없음" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월 d일 HH:mm (zzz)"
        return formatter.string(from: date)
    }
}
