import SpotCoreKit
import SwiftUI

/// What a list shows when it has nothing in it.
struct EmptyState {
    let title: LocalizedStringKey
    let systemImage: String
    let message: LocalizedStringKey
}

/// A list's content once it has rows; otherwise its loading, failed or empty state, never a blank page.
struct LoadStateView<Content: View>: View {
    let state: LibraryLoadState?
    let isEmpty: Bool
    let empty: EmptyState
    let failureTitle: LocalizedStringKey
    let retry: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if !isEmpty {
            content()
        } else {
            switch state {
            case .loaded:
                EmptyStateView(title: empty.title, systemImage: empty.systemImage, message: empty.message) {}
            case .failed:
                FailedState(title: failureTitle, retry: retry)
            case .loading, nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A fetch failed and there is nothing cached to show instead.
struct FailedState: View {
    let title: LocalizedStringKey
    let retry: () -> Void

    var body: some View {
        EmptyStateView(title: title, systemImage: "exclamationmark.triangle", message: "Check your connection and try again.") {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
        }
    }
}

/// The design's centered empty state (`.empty`): icon, title, message and an optional action.
struct EmptyStateView<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let message: LocalizedStringKey
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: Theme.s3) {
            Image(systemName: systemImage)
                .scaledFont(size: 40)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .scaledFont(size: 17, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            actions()
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Theme.s8)
        .padding(.vertical, Theme.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
