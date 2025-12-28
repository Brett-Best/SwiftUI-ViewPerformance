import SwiftUI
import ViewPerformance

@main
struct ViewPerformanceDemoApp: App {

   let bodyTracker: BodyTracker

   init() {
     bodyTracker = BodyTracker()
   }

    var body: some Scene {
        WindowGroup {
            ZStack {
              ContentView()
              DebugOverlayView(timingStore: bodyTracker, initialOffset: CGSize(width: 0, height: 200))
            }
        }
    }
}
