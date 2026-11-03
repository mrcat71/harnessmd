import Accessibility
import SwiftUI

struct UpdateCardStack: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let center = UpdateCardCenter.shared
        VStack(spacing: 8) {
            ForEach(center.notices) { notice in
                UpdateCardView(notice: notice, attention: center.attention[notice.id] ?? 0)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
            }
        }
        .padding(12)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: center.notices.map(\.id))
    }
}

private struct UpdateCardView: View {
    let notice: UpdateCard
    let attention: Int
    @State private var showsDetails = false
    @State private var hovering = false
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                UpdateBadge(symbol: notice.symbol, tint: notice.tone.color, progress: notice.progress)
                VStack(alignment: .leading, spacing: 4) {
                    ZStack(alignment: .leading) {
                        Text(notice.title)
                            .font(.system(size: 13, weight: .semibold))
                            .id(notice.title)
                            .transition(reduceMotion ? .opacity : .push(from: .bottom))
                    }
                    .clipped()
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: notice.title)
                    if let message = notice.message {
                        Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let dismiss = notice.onDismiss {
                    Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Close").accessibilityLabel("Close update notice")
                }
            }
            if let details = notice.details {
                DisclosureGroup(details.title, isExpanded: $showsDetails) {
                    ScrollView { details.content.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) }
                        .frame(maxHeight: 200)
                }.font(.system(size: 12))
            }
            if !notice.actions.isEmpty {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ForEach(notice.actions) { action in
                        if action.role == .primary {
                            Button(action.title, action: action.perform).buttonStyle(.borderedProminent)
                        } else {
                            Button(action.title, action: action.perform).buttonStyle(.bordered)
                        }
                    }
                }.controlSize(.small)
            }
        }
        .padding(14).frame(width: 400)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            if reduceTransparency { shape.fill(Color(nsColor: .windowBackgroundColor)) }
            else { shape.fill(.regularMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
        .scaleEffect(pulsing ? 1.025 : 1)
        .onHover { hovering = $0 }
        .task(id: attention) {
            guard attention > 0, !reduceMotion else { return }
            withAnimation(.snappy) { pulsing = true }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            withAnimation(.spring(response: 0.35)) { pulsing = false }
        }
        .task(id: DismissKey(title: notice.title, paused: hovering || showsDetails)) {
            guard let delay = notice.autoDismiss, let dismiss = notice.onDismiss, !hovering, !showsDetails else { return }
            do { try await Task.sleep(for: delay) } catch { return }
            dismiss()
        }
        .onAppear { AccessibilityNotification.Announcement(notice.title).post() }
        .onChange(of: notice.title) { _, title in AccessibilityNotification.Announcement(title).post() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.title)
        .accessibilityValue(progressDescription)
        .tint(accent)
    }

    private struct DismissKey: Equatable {
        let title: String
        let paused: Bool
    }

    private var progressDescription: String {
        switch notice.progress {
        case .fraction(let value): "\(Int((min(max(value, 0), 1) * 100).rounded())) percent"
        case .indeterminate: "In progress"
        case nil: ""
        }
    }
}

private struct UpdateBadge: View {
    let symbol: String
    let tint: Color
    let progress: UpdateCard.Progress?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            if let progress {
                Circle().inset(by: 1.25).stroke(tint.opacity(0.18), lineWidth: 2.5)
                switch progress {
                case .fraction(let value):
                    arc(fraction: min(max(value, 0.02), 1), rotation: 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
                case .indeterminate:
                    if reduceMotion { arc(fraction: 0.28, rotation: 0) }
                    else {
                        TimelineView(.animation) { context in
                            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                            arc(fraction: 0.28, rotation: turn * 360)
                        }
                    }
                }
            }
            Image(systemName: symbol).font(.system(size: progress == nil ? 13 : 11, weight: .semibold)).foregroundStyle(tint)
        }.frame(width: 30, height: 30).accessibilityHidden(true)
    }

    private func arc(fraction: Double, rotation: Double) -> some View {
        Circle().inset(by: 1.25).trim(from: 0, to: fraction)
            .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(rotation - 90))
    }
}
