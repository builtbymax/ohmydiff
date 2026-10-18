import OhMyDiffCore
import SwiftUI

extension View {
    /// A note above the list, below the floating toolbar, when the installed GitButler is unsupported
    /// and the plain git view is shown. Lists keep `Theme.toolbarInset` of top margin only without it.
    func butCompatibilityBanner(_ incompatibility: ButIncompatibility?) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let incompatibility {
                CompatibilityBanner(incompatibility: incompatibility)
                    .padding(.horizontal, 12)
                    .padding(.top, Theme.toolbarInset)
                    .padding(.bottom, 6)
            }
        }
    }
}

private struct CompatibilityBanner: View {
    let incompatibility: ButIncompatibility

    var body: some View {
        Label {
            Text(incompatibility.description)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.yellow.opacity(0.12), in: .rect(cornerRadius: 10))
        .help("Unexpected `but --json status` output:\n" + incompatibility.violations.joined(separator: "\n"))
    }
}
