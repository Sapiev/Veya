import SpotCoreKit
import SwiftUI
import Playgrounds

struct ContentView: View {
    var body: some View {
        Text("spotcore \(version())")
            .padding()
    }
}

#Preview {
    ContentView()
}

#Playground {
    _ = 1 + 2
}
