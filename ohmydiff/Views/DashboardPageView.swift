import AppKit
import OhMyDiffCore
import SwiftUI

/// The Dashboard page: what landed on the main line in the last 30 days. On the left the activity by day, the
/// latest commits and the people behind them; on the right the totals, releases, folders and largest pull requests.
struct DashboardPageView: View {
    let model: AppModel
    let session: ProjectSession

    var body: some View {
        Group {
            if let dashboard = session.dashboard {
                content(dashboard)
            } else if let error = session.dashboardError {
                EmptyState("Could not load the dashboard", systemImage: "exclamationmark.triangle", description: error) {
                    Button("Try Again") { Task { await session.refreshDashboard() } }
                        .buttonStyle(.pill())
                }
            } else {
                DelayedProgress()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: session.lastRefreshed) { await session.refreshDashboard() }
    }

    private func content(_ dashboard: Dashboard) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ActivitySection(dashboard: dashboard)
                    .padding(16)
                Rectangle().fill(Theme.lineSubtle).frame(height: 1)
                CommitsSection(dashboard: dashboard) { commit in
                    model.open(.history)
                    session.log.reveal(commit.sha)
                }
                Rectangle().fill(Theme.lineSubtle).frame(height: 1)
                PeopleSection(people: dashboard.people)
                    .padding(16)
            }
            .frame(width: 300)
            Rectangle().fill(Theme.lineSubtle).frame(width: 1)
            ScrollView {
                ShippedSection(dashboard: dashboard, hasGitHub: session.history.canManagePullRequests)
                    .padding(20)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Dashboard: the page's title, the line it counts and the window.
struct DashboardTopBar: View {
    let session: ProjectSession

    var body: some View {
        PageTitle(title: "Dashboard")
        if let dashboard = session.dashboard {
            Chip(dashboard.mainLine, systemImage: "arrow.triangle.branch")
                .padding(.leading, 4)
        }
        Spacer(minLength: 8)
        IconButton("Refresh", systemImage: "arrow.clockwise") {
            Task { await session.refreshDashboard() }
        }
    }
}

// MARK: - Left column

/// `Activity  337 commits, 45 in the last week`, a bar per day, and the window's ends.
private struct ActivitySection: View {
    let dashboard: Dashboard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Activity", trailing: "\(dashboard.commits.count) commits, \(dashboard.commitsLastWeek) in the last week")
            DayBars(counts: dashboard.commitsPerDay)
                .frame(height: 44)
            HStack {
                Text("\(dashboard.days) days ago")
                Spacer()
                Text("Today")
            }
            .font(.caption11)
            .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// One bar per day, from the baseline up; the last week full strength, earlier days lighter. Empty days keep a
/// stub on the baseline, so the days stay countable.
private struct DayBars: View {
    let counts: [Int]

    var body: some View {
        let peak = max(counts.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(counts.enumerated()), id: \.offset) { index, count in
                let isLastWeek = index >= counts.count - 7
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if count > 0 {
                            UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                                .fill(Theme.infoFg.opacity(isLastWeek ? 1 : 0.45))
                                .frame(height: max(geometry.size.height * CGFloat(count) / CGFloat(peak), 3))
                        } else {
                            Rectangle().fill(Theme.lineStrong).frame(height: 1)
                        }
                    }
                }
                .contentShape(.rect)
                .help(label(day: index, count: count))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Commits per day")
        .accessibilityValue(counts.map(String.init).joined(separator: ", "))
    }

    private func label(day index: Int, count: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: index - (counts.count - 1), to: .now) ?? .now
        return "\(date.formatted(.dateTime.month(.abbreviated).day())): \(count == 1 ? "1 commit" : "\(count) commits")"
    }
}

/// `On origin/main`: the window's commits, newest first; a click shows one in History.
private struct CommitsSection: View {
    let dashboard: Dashboard
    let open: (CommitInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("On \(dashboard.mainLine)")
                .padding(.horizontal, 16)
                .padding(.top, 12)
            if dashboard.commits.isEmpty {
                Text("No commits in the last \(dashboard.days) days.")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(dashboard.commits) { commit in
                            Button { open(commit) } label: { row(commit) }
                                .buttonStyle(.row(isSelected: false))
                                .focusEffectDisabled()
                                .help("Show in History")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ commit: CommitInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.and.line.horizontal")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 14, height: 14)
            Text(commit.summary)
                .font(.control)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Avatar(login: commit.authorName)
                .help(commit.authorName)
            Text(commit.date.map { RelativeAge.short($0) } ?? "")
                .font(.caption11)
                .foregroundStyle(Theme.textTertiary)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .rowHeight(28)
    }
}

/// `People  commits · 30 days`: who committed, with a bar against the busiest.
private struct PeopleSection: View {
    let people: [Dashboard.Person]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("People", trailing: "commits")
            if people.isEmpty {
                Text("Nobody committed lately.")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
            }
            let peak = people.first?.commits ?? 1
            ForEach(people.prefix(5)) { person in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Avatar(login: person.name)
                        Text(person.name)
                            .font(.control.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(person.commits)")
                            .font(.caption11)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ShareBar(value: person.commits, peak: peak)
                }
                .help(person.email)
            }
            if people.count > 5 {
                Text("and \(people.count - 5) more")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Right column

/// `Shipped  Last 30 days`: the totals, the releases, the folders the commits landed in, and the largest pull requests.
private struct ShippedSection: View {
    let dashboard: Dashboard
    let hasGitHub: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shipped")
                    .font(.panelTitle)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("Last \(dashboard.days) days")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                StatTile(title: "Pull requests", value: hasGitHub ? "\(dashboard.landed.count)" : "–",
                         help: hasGitHub ? "Merged on GitHub" : "Needs the GitHub CLI")
                StatTile(title: "Commits", value: "\(dashboard.commits.count)", help: "On \(dashboard.mainLine)")
                StatTile(title: "People", value: "\(dashboard.people.count)", help: "Who committed")
                StatTile(title: "Time to land", value: dashboard.medianTimeToLand.map(Self.duration) ?? "–",
                         help: "Median time from opening a pull request to merging it")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    releases.frame(minWidth: 240)
                    areas.frame(minWidth: 280)
                }
                VStack(alignment: .leading, spacing: 20) {
                    releases
                    areas
                }
            }
            if !dashboard.landed.isEmpty {
                largest
            }
        }
    }

    private var releases: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("Releases", trailing: "\(dashboard.releaseCount()) in \(dashboard.days) days")
                .padding(.bottom, 4)
            if dashboard.releases.isEmpty {
                Text("No tags yet.")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(dashboard.releases.prefix(4)) { release in
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 14)
                    Text(release.name)
                        .font(.control.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let commits = release.commits {
                        Text(commits == 1 ? "1 commit" : "\(commits) commits")
                            .font(.caption11)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Text(release.date.map { RelativeAge.short($0) } ?? "")
                        .font(.caption11)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(minWidth: 26, alignment: .trailing)
                }
                .frame(height: 26)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var areas: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("Where it landed", trailing: "commits")
                .padding(.bottom, 4)
            if dashboard.areas.isEmpty {
                Text("Nothing landed lately.")
                    .font(.detail)
                    .foregroundStyle(Theme.textTertiary)
            }
            let peak = dashboard.areas.first?.commits ?? 1
            ForEach(dashboard.areas.prefix(6)) { area in
                HStack(spacing: 10) {
                    Text(area.path ?? "Top level")
                        .font(.control)
                        .foregroundStyle(area.path == nil ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(width: 170, alignment: .leading)
                    ShareBar(value: area.commits, peak: peak)
                    Text("\(area.commits)")
                        .font(.caption11)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 26, alignment: .trailing)
                }
                .frame(height: 26)
                .help(area.path ?? "Files at the top level")
            }
            if dashboard.areas.count > 6 {
                Text("and \(dashboard.areas.count - 6) more")
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var largest: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("Largest", trailing: "changed lines · time to land")
                .padding(.bottom, 4)
            ForEach(dashboard.largest()) { pullRequest in
                Button { NSWorkspace.shared.open(pullRequest.url) } label: {
                    HStack(spacing: 8) {
                        PullRequestGlyph(size: 12)
                            .foregroundStyle(Theme.mergedFg)
                        Text(pullRequest.title)
                            .font(.control)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Avatar(login: pullRequest.author)
                            .help(pullRequest.author)
                        LineStatsLabel(stats: LineStats(additions: pullRequest.additions, deletions: pullRequest.deletions))
                        Text(pullRequest.mergedAt.map { Self.duration($0.timeIntervalSince(pullRequest.createdAt)) } ?? "")
                            .font(.caption11)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .rowHeight(28)
                }
                .buttonStyle(.row(isSelected: false))
                .focusEffectDisabled()
                .help("Open #\(pullRequest.number) on GitHub")
            }
            .padding(.horizontal, -8)
        }
    }

    /// `45m`, `5h`, `3d`.
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval / 60), 1)
        switch minutes {
        case ..<60: return "\(minutes)m"
        case ..<(48 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
    }
}

// MARK: - Pieces

/// A section's name, and what its numbers count on the right.
private struct SectionHeader: View {
    let title: String
    let trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.sectionLabel)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.caption11)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// A total with its name above it.
private struct StatTile: View {
    let title: String
    let value: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption11)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .help(help)
    }
}

/// A thin bar for a share of the largest value, on a faint track.
private struct ShareBar: View {
    let value: Int
    let peak: Int

    var body: some View {
        Capsule().fill(Theme.hover)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(Theme.infoFg)
                        .frame(width: max(geometry.size.width * CGFloat(value) / CGFloat(max(peak, 1)), 4))
                }
            }
            .accessibilityHidden(true)
    }
}
