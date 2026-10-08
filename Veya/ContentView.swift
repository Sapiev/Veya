import SpotCoreKit
import SwiftUI

struct ContentView: View {
    @State private var signIn = SignInModel(browser: WebAuthenticationBrowser())

    var body: some View {
        if signIn.state == .signedIn {
            SignedInView()
        } else {
            SignInView(model: signIn)
        }
    }
}

private struct SignedInView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("You're signed in.")
                .font(.title2)
            Text("spotcore \(version())")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
