import SwiftUI

/// Load older notes only when the footer reaches the visible list viewport.
public struct HistoryPagingFooter: View {
    private let viewport: CGRect
    private let loading: Bool
    private let canLoadMore: Bool
    private let action: () -> Void
    @State private var frame = CGRect.zero

    public init(viewport: CGRect, loading: Bool, canLoadMore: Bool, action: @escaping () -> Void) {
        self.viewport = viewport; self.loading = loading; self.canLoadMore = canLoadMore; self.action = action
    }

    private var eligible: Bool {
        !frame.isEmpty && !viewport.isEmpty && frame.intersects(viewport) && canLoadMore && !loading
    }

    public var body: some View {
        Group {
            if loading { ProgressView("Loading earlier notes…") }
            else if canLoadMore {
                Button("Load earlier notes", action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { frame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, value in frame = value }
            }
        }
        .onChange(of: eligible) { _, eligible in
            if eligible { action() }
        }
    }
}
