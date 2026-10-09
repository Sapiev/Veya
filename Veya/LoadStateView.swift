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
                ContentUnavailableView(empty.title, systemImage: empty.systemImage, description: Text(empty.message))
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
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text("Check your connection and try again.")
        } actions: {
            Button("Try Again", action: retry)
        }
    }
}
