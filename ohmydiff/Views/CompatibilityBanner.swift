import OhMyDiffCore
import SwiftUI

extension View {
    /// A note above the list when the installed GitButler is unsupported and the plain git view is
    /// shown, or, dismissibly, when it is a release ohmydiff was not tested against.
    func butCompatibilityBanner(_ session: ProjectSession) -> some View {
        modifier(CompatibilityBannerInset(incompatibility: session.butIncompatibility, mismatch: session.butVersionMismatch))
    }
}

private struct CompatibilityBannerInset: ViewModifier {
    let incompatibility: ButIncompatibility?
    let mismatch: ButVersionMismatch?
    @AppStorage(AppSettings.dismissedButMismatchKey) private var dismissed = ""

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            Group {
                if let incompatibility {
                    CompatibilityBanner(incompatibility: incompatibility)
                } else if let mismatch, dismissed != Self.key(mismatch) {
                    MismatchBanner(mismatch: mismatch) { dismissed = Self.key(mismatch) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
    }

    /// Comes back when either side changes: another `but` install or an ohmydiff tested against another release.
    private static func key(_ mismatch: ButVersionMismatch) -> String {
        "\(mismatch.installed?.description ?? "unknown")/\(mismatch.tested)"
    }
}

/// GitButler's output no longer matches what ohmydiff reads, so the workspace shows as plain git.
private struct CompatibilityBanner: View {
    let incompatibility: ButIncompatibility

    var body: some View {
        Notice(
            title: "GitButler \(incompatibility.version?.description ?? "") isn’t supported yet",
            message: "ohmydiff shows this workspace as plain git until it supports this release. Your branches and lanes are untouched."
        ) {
            Chip("git (fallback)", systemImage: "circle.and.line.horizontal")
        }
        .hoverCard(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unexpected `but --json status` output")
                    .font(.caption.weight(.semibold))
                ForEach(incompatibility.violations, id: \.self) { violation in
                    Text(violation)
                        .font(.code(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A GitButler release ohmydiff was not tested against; everything still runs through `but`.
private struct MismatchBanner: View {
    let mismatch: ButVersionMismatch
    let dismiss: () -> Void

    var body: some View {
        Notice(
            title: "GitButler \(mismatch.installed?.description ?? "") isn’t tested yet",
            message: "ohmydiff was tested with \(mismatch.tested). Branches and lanes keep working; some commands may have changed."
        ) {
            IconButton("Dismiss", systemImage: "xmark", size: 24, action: dismiss)
        }
    }
}

/// The inline warning strip: an icon, a title and a line of explanation, and its actions.
private struct Notice<Accessory: View>: View {
    let title: String
    let message: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.warnFg)
                .frame(width: 15, height: 15)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.row.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.detail)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(Theme.warnBg, in: .rect(cornerRadius: 10))
    }
}
