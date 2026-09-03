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

    /// One of the captures behind the newest one.
    struct EarlierCapture: Identifiable {
        let id: UUID
        let capturedAt: Date
        let windowCount: Int
        let matchesCurrentScreens: Bool
    }

    let capturedAt: Date?
    let windowCount: Int
    let screenName: String?
    let matchesCurrentScreens: Bool
    let tint: Color
    let language: AppLanguage
    let onRestore: () -> Void
    /// The rest of the ring, newest first. Empty hides the control entirely.
    var earlier: [EarlierCapture] = []
    var onRestoreEarlier: (UUID) -> Void = { _ in }

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
                    .accessibilityLabel(Text(String(format: "Captured %@".localized(language),
                                                    age(of: capturedAt))))

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

                if !earlier.isEmpty {
                    earlierCaptures
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
        // Spelled "Restore" because the card it sits in is headed AUTO LAYOUT,
        // which is the only thing that separates it from the toolbar's Restore.
        // That reads correctly on screen and not at all through accessibility,
        // where both are a button described as "Restore", so the distinction
        // has to be stated there explicitly.
        let label = Text("Restore".localized(language)).frame(maxWidth: .infinity)
        if isStale {
            Button(action: onRestore) { label }
                .controlSize(.large).buttonStyle(.bordered)
                .tint(tint).disabled(!matchesCurrentScreens)
                .accessibilityLabel(Text("Restore the auto layout".localized(language)))
        } else {
            Button(action: onRestore) { label }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .tint(tint).disabled(!matchesCurrentScreens)
                .accessibilityLabel(Text("Restore the auto layout".localized(language)))
        }
    }

    /// The rest of the ring.
    ///
    /// Five captures are kept precisely so a bad one can be stepped back past,
    /// and by the time the user notices a bad arrangement the auto-save has
    /// usually recorded it into the newest slot already. Keeping four more on
    /// disk with no way to reach them is not a safeguard.
    private var earlierCaptures: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(earlier) { capture in
                    EarlierRow(age: age(of: capture.capturedAt),
                               windowCount: capture.windowCount,
                               isApplicable: capture.matchesCurrentScreens,
                               tint: tint,
                               language: language,
                               action: { onRestoreEarlier(capture.id) })
                }
            }
            .padding(.top, 3)
        } label: {
            Text(earlier.count == 1 ? "1 earlier capture" : "\(earlier.count) earlier captures")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    /// A row that restores one earlier capture.
    ///
    /// Rendered first as plain text with the age and the count, which looked
    /// exactly like the two static lines above it and gave no sign it could be
    /// clicked. It carries the restore glyph and a hover fill for that reason.
    private struct EarlierRow: View {
        let age: String
        let windowCount: Int
        let isApplicable: Bool
        let tint: Color
        let language: AppLanguage
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: isApplicable
                          ? "arrow.uturn.backward"
                          : "display.trianglebadge.exclamationmark")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 10)
                    Text(age)
                    Spacer(minLength: 8)
                    Text(windowCount == 1 ? "1 window" : "\(windowCount) windows")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(isApplicable ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tint.opacity(isHovering && isApplicable ? 0.12 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isApplicable)
            .onHover { isHovering = $0 }
            .help(isApplicable
                  ? Text("Restore this capture".localized(language))
                  : Text("Captured on a different display setup.".localized(language)))
            // Four rows all described as "Restore" would be no more use through
            // accessibility than no rows at all.
            .accessibilityLabel(Text(String(format: "Restore the capture from %@, %d windows".localized(language),
                                            age, windowCount)))
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
        guard let capturedAt else { return "" }
        return age(of: capturedAt)
    }

    private func age(of date: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = 1
        f.allowedUnits = seconds < 3600 ? [.minute] : (seconds < 86_400 ? [.hour] : [.day])
        let spelled = f.string(from: max(seconds, 60)) ?? ""
        // The formatter localises the quantity; the suffix has to be localised
        // too, or a Hebrew system reads "5 דקות ago" in the largest text on the
        // card. A format string rather than concatenation, because the suffix
        // does not follow the quantity in every language.
        guard !spelled.isEmpty else { return "just now".localized(language) }
        return String(format: "%@ ago".localized(language), spelled)
    }
}
