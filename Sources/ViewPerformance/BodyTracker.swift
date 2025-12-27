import ViewPerformanceObjC
import Darwin

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
  public let isDebuggerConnected: Bool
  
  var entries: [Entry] {
    timingMap.map { (name, durations) in
      Entry(name: name, recentDurations: durations)
    }
    .filter { !$0.recentDurations.isEmpty }
    .sorted { $0.average > $1.average }
  }
  
  private static func debuggerIsAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let count = name.count
    let result = name.withUnsafeMutableBufferPointer { ptr -> Int32 in
      return sysctl(ptr.baseAddress, u_int(count), &info, &size, nil, 0)
    }
    if result != 0 {
      return false
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0
  }
  
  public init() {
    self.isDebuggerConnected = BodyTracker.debuggerIsAttached()
    // If a debugger is attached, skip setting up the Hook so we don't interfere with debugging sessions.
    guard !isDebuggerConnected else { return }

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
