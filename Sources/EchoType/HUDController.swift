import AppKit
import SwiftUI

/// A floating, non-activating HUD near the bottom of the screen, styled like
/// ChatGPT/Wispr's dictation pill: ✕ cancel — live waveform — ✓ submit.
/// Buttons are clickable without stealing focus from the target app.
final class HUDController {
    enum HUDState {
        case starting                    // webview waking up before the mic can open
        case listening(handsFree: Bool)  // hands-free = double-tap mode, tap again to stop
        case transcribing
        case error(String)
    }

    /// Wired by AppDelegate: ✕ and ✓ taps on the pill.
    var onCancel: (() -> Void)?
    var onSubmit: (() -> Void)?

    private var panel: NSPanel?
    private var autoHideTimer: Timer?

    func show(state: HUDState) {
        autoHideTimer?.invalidate()
        autoHideTimer = nil

        let content = HUDView(state: state,
                              onCancel: { [weak self] in self?.onCancel?() },
                              onSubmit: { [weak self] in self?.onSubmit?() })
        if panel == nil {
            let panel = NonFocusPanel(
                contentRect: .zero,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        guard let panel else { return }

        // Only the listening pill has buttons; other states pass clicks through.
        if case .listening = state {
            panel.ignoresMouseEvents = false
        } else {
            panel.ignoresMouseEvents = true
        }

        let hosting = FirstMouseHostingView(rootView: content)
        panel.contentView = hosting
        let size = hosting.fittingSize
        panel.setContentSize(size)

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()

        // Errors auto-dismiss; other states are hidden explicitly by the state machine.
        if case .error = state {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                self?.hide()
            }
        }
    }

    func hide() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        panel?.orderOut(nil)
    }
}

/// Lets pill buttons react to the first click even though the panel never
/// becomes the key window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A panel that can never take keyboard focus: clicking ✕/✓ must leave the
/// user's text field focused so the paste lands where they were typing.
private final class NonFocusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Views

private struct HUDView: View {
    let state: HUDController.HUDState
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        Group {
            switch state {
            case .starting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("Waking up…")
                        .foregroundStyle(.white)
                }
            case .listening(let handsFree):
                HStack(spacing: 8) {
                    PillButton(symbol: "xmark", prominent: false, action: onCancel)
                        .help("Cancel dictation")
                    VStack(spacing: 1) {
                        WaveformView()
                        if handsFree {
                            Text("tap hotkey to stop")
                                .font(.system(size: 8))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    PillButton(symbol: "checkmark", prominent: true, action: onSubmit)
                        .help("Finish & paste")
                }
            case .transcribing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("Transcribing…")
                        .foregroundStyle(.white)
                }
            case .error(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .foregroundStyle(.white)
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.88), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .fixedSize()
    }
}

/// Round ✕ / ✓ button matching ChatGPT's dictation pill.
private struct PillButton: View {
    let symbol: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(prominent ? .black : .white)
                .frame(width: 21, height: 21)
                .background(prominent ? Color.white : Color.white.opacity(0.22), in: Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}

/// Animated audio-style bars. Purely decorative (the real audio lives inside
/// the webview), but gives the Wispr-like "it's hearing you" feedback.
private struct WaveformView: View {
    private let barCount = 11

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = Double(i) * 1.7
                    let wobble = (sin(t * 9.0 + phase) + sin(t * 5.3 + phase * 2.1)) / 2
                    let height = 3.5 + abs(wobble) * heightCap(i)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white)
                        .frame(width: 2.5, height: height)
                }
            }
            .frame(height: 14)
        }
    }

    /// Taller in the middle, shorter at the edges — mic-meter silhouette.
    private func heightCap(_ index: Int) -> Double {
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        return 9 * (1.0 - distance * 0.7)
    }
}
