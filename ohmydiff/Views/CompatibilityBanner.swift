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

private struct CompatibilityBanner: View {
    let incompatibility: ButIncompatibility

    var body: some View {
        BannerLabel(text: incompatibility.description)
            .hoverCard(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unexpected `but --json status` output")
                        .font(.caption.weight(.semibold))
                    ForEach(incompatibility.violations, id: \.self) { violation in
                        Text(violation)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
    }
}

private struct MismatchBanner: View {
    let mismatch: ButVersionMismatch
    let dismiss: () -> Void

    var body: some View {
        BannerLabel(text: mismatch.description) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassTooltip("Dismiss", edge: .top)
        }
        .hoverCard(edge: .bottom) {
            Text("ohmydiff was tested with GitButler \(mismatch.tested). Commands or output may have changed since.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BannerLabel<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label {
                Text(text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.yellow.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

extension BannerLabel where Accessory == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}
