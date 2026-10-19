import AppKit
import SwiftUI

/// A small floating panel under the menu bar (top right) that shows conversions in progress,
/// then "Done" for a moment before fading away. It never takes focus from the app you're using.
final class ProgressHUD {
    private let model: AppModel
    private var panel: NSPanel?
    private var hostingView: NSHostingView<HUDView>?
    private var hideTask: Task<Void, Never>?

    /// How long a finished conversion stays visible.
    static let lingerSeconds: Double = 3

    init(model: AppModel) {
        self.model = model
    }

    /// Call when a job starts or finishes. Quick conversions finish before the panel would appear,
    /// so it only shows for jobs still running after a moment.
    func jobStarted() {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if model.jobs.contains(where: \.isActive) { refresh() }
        }
    }

    func jobFinished() {
        guard panel?.isVisible == true else { return }
        refresh()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Self.lingerSeconds + 0.1))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func refresh() {
        model.refreshHUD()
        guard model.showProgressPopup, !model.hudJobs.isEmpty else {
            hide()
            return
        }
        let panel = self.panel ?? makePanel()
        if let hostingView {
            let size = hostingView.fittingSize
            let screen = NSScreen.main?.visibleFrame ?? .zero
            panel.setFrame(NSRect(x: screen.maxX - size.width - 12, y: screen.maxY - size.height - 8,
                                  width: size.width, height: size.height), display: true)
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { _ in panel.animator().alphaValue = 1 }
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ _ in
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if self.model.hudJobs.isEmpty || !self.model.showProgressPopup { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let hostingView = NSHostingView(rootView: HUDView(model: model))
        panel.contentView = hostingView
        self.hostingView = hostingView
        self.panel = panel
        return panel
    }
}

private struct HUDView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.hudJobs) { job in
                HUDRow(job: job, model: model)
            }
        }
        .padding(12)
        .frame(width: 300)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
    }
}

private struct HUDRow: View {
    let job: Job
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch job.state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .cancelled, .undone: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                default: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
                }
            }
            .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text((job.resultURL ?? job.fileURL).lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch job.state {
                case .converting(let progress?):
                    HStack {
                        ProgressView(value: progress).controlSize(.small)
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                case .converting(nil), .waiting:
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                case .done:
                    Text("Done · \(job.from.displayName) → \(job.to.displayName)").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case .undone:
                    Text("Undone").font(.caption).foregroundStyle(.secondary)
                }
            }

            if job.isActive {
                Button { model.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel")
            } else if job.state == .done {
                Button { model.reveal(job) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show in Finder")
            }
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Menu-bar icon: the usual arrows when idle, a filling ring while converting.
enum StatusIcon {
    static func ring(progress: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * max(0.04, progress), clockwise: true)
            arc.lineWidth = 2.4
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()

            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
            NSColor.black.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = true   // Lets macOS tint it to match the menu bar
        return image
    }
}
