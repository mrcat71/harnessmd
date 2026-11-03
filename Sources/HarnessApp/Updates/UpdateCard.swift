import Foundation
import Observation
import SwiftUI

/// A floating card at the top of a window's content, after Rex's notices:
/// update progress, a Git error, anything that happened while you worked.
/// Notices never block the window. One that needs an answer keeps its buttons
/// until you choose; the others close with their close button or by themselves.
struct UpdateCard: Identifiable {
    enum Tone: Equatable {
        case info
        case success
        case warning
        case error

        var color: Color {
            switch self {
            case .info: return Color.accentColor
            case .success: return Color.green
            case .warning: return Color.orange
            case .error: return Color.red
            }
        }
    }

    enum Progress: Equatable {
        case indeterminate
        /// From 0 to 1.
        case fraction(Double)
    }

    /// A button under the message. Notices take no Return or Escape: the
    /// window under them keeps its keys.
    struct Action: Identifiable {
        enum Role {
            case primary
            case secondary
            case destructive
        }

        let title: String
        var role: Role = .secondary
        let perform: @MainActor () -> Void

        var id: String {
            title
        }
    }

    /// More text behind a disclosure under the message, such as release notes.
    struct Details {
        let title: String
        let content: AnyView
    }

    var id: String
    var tone: Tone = .info
    var symbol: String
    var title: String
    var message: String?
    var details: Details?
    var progress: Progress?
    var actions: [Action] = []
    /// What the close button does; nil leaves the notice without one.
    var onDismiss: (@MainActor () -> Void)?
    /// Closes the notice after this long, counted while the pointer is away.
    var autoDismiss: Duration?
}

/// Notices that belong to the app rather than one window, such as the
/// update's. The window you work in shows them; a window's own notices, its
/// Git errors, come from that window's state.
@MainActor
@Observable
final class UpdateCardCenter {
    static let shared = UpdateCardCenter()

    private(set) var notices: [UpdateCard] = []
    /// Bumped to make a notice draw attention to itself again.
    private(set) var attention: [String: Int] = [:]
    var onPresent: @MainActor () -> Void = {}

    init() {}

    /// Shows `notice`, or replaces the one with its id where it stands.
    func show(_ notice: UpdateCard) {
        if let index = notices.firstIndex(where: { $0.id == notice.id }) {
            notices[index] = notice
        } else {
            notices.append(notice)
            onPresent()
        }
    }

    func dismiss(id: String) {
        notices.removeAll { $0.id == id }
        attention[id] = nil
    }

    func callAttention(to id: String) {
        guard notices.contains(where: { $0.id == id }) else { return }
        attention[id, default: 0] += 1
    }
}
