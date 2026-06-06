import AppKit
import BokslTabCore
import SwiftUI

public struct SwitcherPanelView: View {
    private let mode: SwitcherMode
    private let items: [SwitcherItem]
    private let selectedIndex: Int
    private let warning: String?
    private let iconProvider: (SwitcherItem) -> NSImage?
    private let onOpenSettings: (() -> Void)?

    public init(
        mode: SwitcherMode,
        items: [SwitcherItem],
        selectedIndex: Int,
        warning: String?,
        iconProvider: @escaping (SwitcherItem) -> NSImage?,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.items = items
        self.selectedIndex = selectedIndex
        self.warning = warning
        self.iconProvider = iconProvider
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            SwitcherRowView(
                                item: item,
                                icon: iconProvider(item),
                                isSelected: index == selectedIndex
                            )
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            if let warning {
                WarningBanner(message: warning, onOpenSettings: onOpenSettings)
            }

            Text("↑↓/Tab 이동 · Enter 전환 · Esc 닫기")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 560, alignment: .leading)
        .background(.black.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var header: some View {
        HStack {
            Text(mode.displayTitle)
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Text("\(items.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        Text("표시할 앱 또는 창이 없습니다.")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 96)
    }
}

private struct WarningBanner: View {
    let message: String
    let onOpenSettings: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.yellow)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let onOpenSettings {
                Button("설정 열기", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}

private struct SwitcherRowView: View {
    let item: SwitcherItem
    let icon: NSImage?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon ?? NSImage(size: NSSize(width: 32, height: 32)))
                .resizable()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.subtitle ?? item.kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.78) : Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension SwitcherMode {
    var displayTitle: String {
        switch self {
        case .allAppsAndWindows:
            return "모든 앱/창 전환"
        case .activeAppWindows:
            return "활성 앱 창 전환"
        }
    }
}

private extension SwitcherItem {
    var kindLabel: String {
        isWindow ? "창" : "앱"
    }
}
