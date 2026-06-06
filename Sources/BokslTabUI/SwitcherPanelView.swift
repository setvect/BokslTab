import AppKit
import BokslTabCore
import SwiftUI

public struct SwitcherPanelView: View {
    private let items: [SwitcherItem]
    private let selectedIndex: Int
    private let warning: String?
    private let availableSize: CGSize
    private let iconProvider: (SwitcherItem) -> NSImage?
    private let onOpenSettings: (() -> Void)?
    private let onSelectIndex: (Int) -> Void
    private let onActivateIndex: (Int) -> Void

    public init(
        items: [SwitcherItem],
        selectedIndex: Int,
        warning: String?,
        availableSize: CGSize = CGSize(width: 1280, height: 800),
        iconProvider: @escaping (SwitcherItem) -> NSImage?,
        onOpenSettings: (() -> Void)? = nil,
        onSelectIndex: @escaping (Int) -> Void = { _ in },
        onActivateIndex: @escaping (Int) -> Void = { _ in }
    ) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.warning = warning
        self.availableSize = availableSize
        self.iconProvider = iconProvider
        self.onOpenSettings = onOpenSettings
        self.onSelectIndex = onSelectIndex
        self.onActivateIndex = onActivateIndex
    }

    public var body: some View {
        let metrics = SwitcherPanelLayout.metrics(itemCount: items.count, availableSize: availableSize)

        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                emptyState(metrics: metrics)
            } else {
                listBody(metrics: metrics)
            }

            if let warning {
                WarningBanner(message: warning, onOpenSettings: onOpenSettings)
            }
        }
        .padding(SwitcherPanelLayout.panelPadding)
        .frame(width: metrics.panelWidth, alignment: .leading)
        .background(.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func listBody(metrics: SwitcherPanelMetrics) -> some View {
        if metrics.usesScroll {
            ScrollViewReader { proxy in
                ScrollView {
                    rowStack(metrics: metrics)
                }
                .frame(height: metrics.listHeight)
                .onAppear { scrollSelectedIntoView(proxy: proxy) }
                .onChange(of: selectedIndex) { _ in scrollSelectedIntoView(proxy: proxy) }
            }
        } else {
            rowStack(metrics: metrics)
                .frame(height: metrics.listHeight)
        }
    }

    private func rowStack(metrics: SwitcherPanelMetrics) -> some View {
        LazyVStack(spacing: metrics.rowSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                SwitcherRowView(
                    item: item,
                    icon: iconProvider(item),
                    isSelected: index == selectedIndex,
                    metrics: metrics,
                    onSelect: { onSelectIndex(index) },
                    onActivate: { onActivateIndex(index) }
                )
                .id(item.id)
            }
        }
    }

    private func emptyState(metrics: SwitcherPanelMetrics) -> some View {
        Text("표시할 앱 또는 창이 없습니다.")
            .font(.system(size: metrics.fontSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: metrics.panelWidth - SwitcherPanelLayout.panelPadding * 2, height: metrics.rowHeight * 2)
    }

    private func scrollSelectedIntoView(proxy: ScrollViewProxy) {
        guard !items.isEmpty, selectedIndex >= 0, selectedIndex < items.count else { return }
        proxy.scrollTo(items[selectedIndex].id, anchor: .center)
    }
}

struct SwitcherPanelMetrics: Equatable, Sendable {
    let usesScroll: Bool
    let panelWidth: CGFloat
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let iconSize: CGFloat
    let fontSize: CGFloat
    let listHeight: CGFloat

    var panelHeight: CGFloat {
        listHeight + SwitcherPanelLayout.panelPadding * 2
    }
}

enum SwitcherPanelLayout {
    static let scrollThreshold = 30
    static let panelPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 0
    static let baseRowHeight: CGFloat = 56
    static let minimumRowHeight: CGFloat = 30
    static let baseIconSize: CGFloat = 36
    static let minimumIconSize: CGFloat = 18
    static let baseFontSize: CGFloat = 18
    static let minimumFontSize: CGFloat = 11
    static let screenEdgeMargin: CGFloat = 12
    static let defaultAvailableSize = CGSize(width: 1280, height: 800)

    static func metrics(itemCount: Int, availableSize: CGSize) -> SwitcherPanelMetrics {
        let safeCount = max(itemCount, 1)
        let desiredPanelWidth = min(max(560, availableSize.width * 0.90), 1320)
        let maxPanelWidth = max(1, availableSize.width - screenEdgeMargin * 2)
        let panelWidth = min(desiredPanelWidth, maxPanelWidth)
        let maxPanelHeight = max(1, availableSize.height - screenEdgeMargin * 2)
        let maxListHeight = max(1, maxPanelHeight - panelPadding * 2)
        let minimumUsableRowHeight = min(minimumRowHeight, maxListHeight)
        let noScrollCandidateRowHeight = floor(maxListHeight / CGFloat(safeCount))
        let guardrailRequiresScroll = itemCount > 0 && itemCount < scrollThreshold && noScrollCandidateRowHeight < minimumUsableRowHeight
        let usesScroll = itemCount >= scrollThreshold || guardrailRequiresScroll
        let rowHeight: CGFloat
        let visibleRows: Int

        if usesScroll {
            rowHeight = min(baseRowHeight, max(minimumUsableRowHeight, floor(maxListHeight / CGFloat(min(safeCount, scrollThreshold - 1)))))
            visibleRows = max(1, min(safeCount, Int(floor(maxListHeight / rowHeight))))
        } else {
            rowHeight = min(baseRowHeight, max(minimumUsableRowHeight, noScrollCandidateRowHeight))
            visibleRows = safeCount
        }

        let scale = rowHeight / baseRowHeight
        let iconSize = max(minimumIconSize, floor(baseIconSize * scale))
        let fontSize = max(minimumFontSize, floor(baseFontSize * scale))
        let listHeight = CGFloat(visibleRows) * rowHeight + CGFloat(max(visibleRows - 1, 0)) * rowSpacing

        return SwitcherPanelMetrics(
            usesScroll: usesScroll,
            panelWidth: panelWidth,
            rowHeight: rowHeight,
            rowSpacing: rowSpacing,
            iconSize: iconSize,
            fontSize: fontSize,
            listHeight: listHeight
        )
    }

    static func panelFrame(
        itemCount: Int,
        warning: String?,
        visibleFrame: CGRect,
        fittingSize: CGSize = .zero
    ) -> CGRect {
        let metrics = metrics(itemCount: itemCount, availableSize: visibleFrame.size)
        let warningHeight: CGFloat = warning == nil ? 0 : 28
        let maxWidth = max(1, visibleFrame.width - screenEdgeMargin * 2)
        let maxHeight = max(1, visibleFrame.height - screenEdgeMargin * 2)
        let width = min(maxWidth, max(metrics.panelWidth, fittingSize.width))
        let height = min(maxHeight, max(metrics.panelHeight + warningHeight, fittingSize.height))
        let size = CGSize(width: width, height: height)
        let preferredOrigin = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY + min(80, visibleFrame.height * 0.12) - size.height / 2
        )
        let minX = visibleFrame.minX + screenEdgeMargin
        let maxX = visibleFrame.maxX - screenEdgeMargin - size.width
        let minY = visibleFrame.minY + screenEdgeMargin
        let maxY = visibleFrame.maxY - screenEdgeMargin - size.height
        let origin = CGPoint(
            x: clamped(preferredOrigin.x, lower: minX, upper: maxX),
            y: clamped(preferredOrigin.y, lower: minY, upper: maxY)
        )

        return CGRect(origin: origin, size: size)
    }

    private static func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }

    static func listHeight(itemCount: Int) -> CGFloat {
        metrics(itemCount: itemCount, availableSize: defaultAvailableSize).listHeight
    }
}

private struct WarningBanner: View {
    let message: String
    let onOpenSettings: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.yellow)
                .lineLimit(2)

            Spacer(minLength: 4)

            if let onOpenSettings {
                Button("설정", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
        }
        .padding(.top, 4)
    }
}

private struct SwitcherRowView: View {
    let item: SwitcherItem
    let icon: NSImage?
    let isSelected: Bool
    let metrics: SwitcherPanelMetrics
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: icon ?? NSImage(size: NSSize(width: metrics.iconSize, height: metrics.iconSize)))
                .resizable()
                .frame(width: metrics.iconSize, height: metrics.iconSize)
                .clipShape(RoundedRectangle(cornerRadius: max(4, metrics.iconSize * 0.18), style: .continuous))

            Text(item.title)
                .font(.system(size: metrics.fontSize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .frame(height: metrics.rowHeight)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onTapGesture(count: 2, perform: onActivate)
    }
}
