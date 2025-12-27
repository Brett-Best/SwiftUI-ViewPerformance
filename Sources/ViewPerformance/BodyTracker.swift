import ViewPerformanceObjC

@Observable
@MainActor
public class BodyTracker {
  
  struct Entry: Identifiable {
      var id: String {
        name
      }
      let name: String
      var recentDurations: [Double]
      var average: Double { recentDurations.reduce(0, +) / Double(recentDurations.count) }
  }
  
  private var timingMap: [String: [Double]] = [:]
  
  var entries: [Entry] {
    timingMap.map { (name, durations) in
      Entry(name: name, recentDurations: durations)
    }
    .filter { !$0.recentDurations.isEmpty }
    .sorted { $0.average > $1.average }
  }
  
  public init() {
    let hook = Hook { name, duration in
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }

          print("The duration \(duration)ms \(name)")
          var samples = self.timingMap[name, default: []]
          samples.append(duration)
          self.timingMap[name] = samples
        }
    }
    getViews().forEach { name, _, bodyThunk in
      if !name.contains("DebugOverlayView") {
        hook.add(bodyThunk, named: name)
      }
    }
  }
}
