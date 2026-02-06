# ViewPerformance

A utility to track performance of SwiftUI views and layouts. It automatically tracks:
- The duration of view `body` accessors
- The duration of `Layout.sizeThatFits(proposal:subviews:cache:)` calls

![Screenshot of ViewPerformance in an app.](/images/example.png)

> [!IMPORTANT]
> The debugger must not be connected for this to work. You can disable it by unchecking "Debug executable" in your scheme’s run configuration. Although the debugger can’t be running the app needs to be signed with debug entitlements, it **does not work in production apps**.

This repo is a minimal example of how to automatically track SwiftUI performance, it’s meant as an example to spark your own ideas for how this tracking information can be used.

## Setup

Use the `DebugOverlayView` to show view performance information. Here’s a minimal example:

```
import ViewPerformance

@main
struct ViewPerformanceDemoApp: App {

   let bodyTracker = BodyTracker()

    var body: some Scene {
        WindowGroup {
            ZStack {
              ContentView()
              DebugOverlayView(timingStore: bodyTracker, initialOffset: CGSize(width: 0, height: 200))
            }
        }
    }
}
```

## Features

- **View Body Tracking**: Automatically measures the duration of SwiftUI `View.body` accessors
- **Layout Tracking**: Automatically measures the duration of custom `Layout.sizeThatFits(proposal:subviews:cache:)` calls  
- **Subviews Logging**: For Layout calls, logs the subviews pointer address to Console.app (subsystem: `com.sentry.viewperformance`, category: `layout`)
- **Debug Overlay**: Visual display showing the most recent and slowest view/layout operations

Layout entries in the overlay are prefixed with `Layout:` to distinguish them from regular View body calls.
