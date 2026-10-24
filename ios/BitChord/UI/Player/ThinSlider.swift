import AVFoundation
import MediaPlayer
import SwiftUI

/**
 * ThinSlider: a thumbless capsule, 7pt idle and 12pt under the finger, in a
 * touch area 22pt taller. A touch jumps to the finger; release commits.
 */
struct ThinSlider: View {
    let value: Double
    var idleHeight: CGFloat = 7
    var activeHeight: CGFloat = 12
    var onChanged: ((Double) -> Void)? = nil
    let onCommit: (Double) -> Void

    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geometry in
            let shown = dragging ?? value
            let height = dragging == nil ? idleHeight : activeHeight
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.26))
                Capsule().fill(.white.opacity(0.92))
                    .frame(width: max(0, min(1, shown)) * geometry.size.width)
            }
            .frame(height: height)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fraction = min(1, max(0, drag.location.x / max(1, geometry.size.width)))
                        if dragging == nil {
                            withAnimation(.compose(dampingRatio: 0.5, stiffness: 400)) { dragging = fraction }
                        } else {
                            dragging = fraction
                        }
                        onChanged?(fraction)
                    }
                    .onEnded { _ in
                        guard let final = dragging else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        onCommit(final)
                        // Hold the drop point until the player reports it.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(.compose(dampingRatio: 0.5, stiffness: 400)) { dragging = nil }
                        }
                    }
            )
        }
        .frame(height: activeHeight + 22)
    }
}

/** The system volume: follows the finger, glides when the hardware keys move it. */
struct VolumeSlider: View {
    var tint: Color
    @State private var volume = Double(AVAudioSession.sharedInstance().outputVolume)
    @State private var observation: NSKeyValueObservation?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 14)).foregroundStyle(tint.opacity(0.5)).frame(width: 20)
            ThinSlider(value: volume, idleHeight: 6, activeHeight: 10, onChanged: { set($0) }, onCommit: { set($0) })
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 14)).foregroundStyle(tint.opacity(0.5)).frame(width: 20)
        }
        .frame(height: 32)
        .background { SystemVolumeView().frame(width: 1, height: 1).opacity(0.01) }
        .onAppear {
            observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { _, change in
                guard let new = change.newValue else { return }
                Task { @MainActor in withAnimation(.fastOutSlowIn(0.22)) { volume = Double(new) } }
            }
        }
        .onDisappear { observation = nil }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(volume * 100))%")
        .accessibilityAdjustableAction { direction in
            set(direction == .increment ? min(1, volume + 0.0625) : max(0, volume - 0.0625))
        }
    }

    private func set(_ value: Double) {
        volume = value
        SystemVolumeView.set(Float(value))
    }
}

/** MPVolumeView's slider is the one public way to set the system volume. */
private struct SystemVolumeView: UIViewRepresentable {
    nonisolated(unsafe) private static weak var slider: UISlider?

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = true
        Self.slider = view.subviews.compactMap { $0 as? UISlider }.first
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        if Self.slider == nil { Self.slider = view.subviews.compactMap { $0 as? UISlider }.first }
    }

    @MainActor
    static func set(_ value: Float) {
        slider?.value = value
    }
}
