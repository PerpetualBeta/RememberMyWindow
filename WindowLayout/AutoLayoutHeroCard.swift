import SwiftUI

/// The Auto layout's place in the sidebar.
///
/// A one-button restore of an arrangement nobody saved by hand has to show
/// what it is about to do, or there is no reason to trust it. So the card
/// leads with three facts: when the capture was taken, how many windows it
/// holds, and which display setup it came from.
///
/// Takes plain values rather than reaching into `WindowManager`, so it can be
/// rendered on its own and looked at.
struct AutoLayoutHeroCard: View {
    let capturedAt: Date?
    let windowCount: Int
    let screenName: String?
    let matchesCurrentScreens: Bool
    let tint: Color
    let language: AppLanguage
    let onRestore: () -> Void

    /// How old a capture may be before the card stops looking confident.
    /// Restoring a days-old layout is worse than not restoring, so past this
    /// the card mutes rather than raising a warning nobody asked for.
    static let staleAfter: TimeInterval = 60 * 60 * 12

    /// Injectable so the stale and fresh states can both be rendered.
    var now: Date = Date()

    private var age: TimeInterval? { capturedAt.map { now.timeIntervalSince($0) } }
    private var isStale: Bool { (age ?? .infinity) > Self.staleAfter }
    private var hasCapture: Bool { capturedAt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let capturedAt {
                Text(relativeAge)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .accessibilityLabel(Text("Captured \(capturedAt, style: .relative) ago"))

                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                    Text(windowCount == 1 ? "1 window" : "\(windowCount) windows")
                    if let screenName {
                        Text("·").foregroundStyle(.tertiary)
                        Text(screenName).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                // A stale card mutes its heading and its age, so the button
                // must come down with them. Leaving the loudest element at full
                // strength undoes the point of muting the rest.
                restoreButton

                if !matchesCurrentScreens {
                    footnote("Captured on a different display setup.")
                } else if isStale {
                    footnote("This capture is old. Check it is the arrangement you want.")
                }
            } else {
                footnote("Nothing captured yet. Move a window and it will appear here.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var restoreButton: some View {
        let label = Text("Restore".localized(language)).frame(maxWidth: .infinity)
        if isStale {
            Button(action: onRestore) { label }
                .controlSize(.large).buttonStyle(.bordered)
                .tint(tint).disabled(!matchesCurrentScreens)
        } else {
            Button(action: onRestore) { label }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .tint(tint).disabled(!matchesCurrentScreens)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
            Text("AUTO LAYOUT".localized(language))
                .font(.system(size: 11, weight: .bold))
            Spacer()
            if hasCapture && !matchesCurrentScreens {
                Text("OTHER DISPLAYS".localized(language))
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(!hasCapture || isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
    }

    private func footnote(_ text: String) -> some View {
        Text(text.localized(language))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Spelled out rather than using `Text(_:style:.relative)`, which cannot be
    /// given a reference date and so cannot be rendered for a chosen age.
    private var relativeAge: String {
        guard let age else { return "" }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 1
        f.allowedUnits = age < 3600 ? [.minute] : (age < 86_400 ? [.hour] : [.day])
        let spelled = f.string(from: max(age, 60)) ?? ""
        return spelled.isEmpty ? "just now" : "\(spelled) ago"
    }
}
