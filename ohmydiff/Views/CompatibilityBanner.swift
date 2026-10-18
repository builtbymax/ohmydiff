import OhMyDiffCore
import SwiftUI

extension View {
    /// A thin bar above the list when the installed GitButler is unsupported and the plain git view is shown.
    func butCompatibilityBanner(_ incompatibility: ButIncompatibility?) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let incompatibility { CompatibilityBanner(incompatibility: incompatibility) }
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
        .padding(.vertical, 6)
        .background(.bar)
        .help("Unexpected `but --json status` output:\n" + incompatibility.violations.joined(separator: "\n"))
    }
}
