import SwiftUI

public struct DebugOverlayView: View {
    @Bindable var timingStore: BodyTracker
    var initialOffset: CGSize = .zero
    
    @State private var offset: CGSize
    @State private var isExpanded = true
    
    @State private var dragOffset: CGSize = .zero
    
    // Custom initializer to set initial offset
    public init(timingStore: BodyTracker, initialOffset: CGSize = .zero) {
        self.timingStore = timingStore
        self.initialOffset = initialOffset
        _offset = State(initialValue: initialOffset)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("🩻 View Debugger")
                    .bold()
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.primary)
                }.buttonStyle(.plain)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Most Recent")
                        .font(.caption)
                        .foregroundStyle(.primary)
                  ForEach(timingStore.entries.suffix(3).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            HStack {
                                Text("Renders:")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Text("\(entry.recentDurations.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("Avg:")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Text(String(format: "%.1f ms", entry.average))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slowest")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    ForEach(timingStore.entries.sorted(by: { $0.average > $1.average }).prefix(3), id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.caption)
                                .foregroundStyle(.primary)
                            HStack {
                                Text("Renders:")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Text("\(entry.recentDurations.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("Avg:")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                Text(String(format: "%.1f ms", entry.average))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.4), lineWidth: 1)
        )
        .shadow(radius: 7)
        .frame(maxWidth: 260, alignment: .topLeading)
        // Apply offset including drag offset
        .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    offset.width += value.translation.width
                    offset.height += value.translation.height
                    dragOffset = .zero
                }
        )
//        .padding([.top, .leading], 18)
    }
}

#if DEBUG
#Preview {
    DebugOverlayView(timingStore: BodyTracker(), initialOffset: .zero)
}
#endif

