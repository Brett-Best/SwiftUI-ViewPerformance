//
//  ViewPerformanceDemoApp.swift
//  ViewPerformanceDemo
//
//  Created by Noah Martin on 12/27/25.
//

import SwiftUI
import ViewPerformance

@main
struct ViewPerformanceDemoApp: App {

   var bodyTracker: BodyTracker

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
