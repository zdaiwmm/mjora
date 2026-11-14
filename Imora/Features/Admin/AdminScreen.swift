import SwiftUI

/// entry to the server administration pages, shown to admin accounts only.
struct AdminScreen: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AdminUsersScreen()
                } label: {
                    Label("Users", systemImage: "person.2")
                }
                .accessibilityIdentifier("admin-users")

                NavigationLink {
                    AdminQueuesScreen()
                } label: {
                    Label("Job Queues", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("admin-queues")

                NavigationLink {
                    AdminServerStatisticsScreen()
                } label: {
                    Label("Server Statistics", systemImage: "chart.bar")
                }
                .accessibilityIdentifier("admin-statistics")
            } footer: {
                Text("Manage the accounts and background jobs of your \(session.serverProduct?.displayName ?? "Imora") server.")
            }
        }
        .navigationTitle("Administration")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// GET /server/statistics: what the library holds, in total and per user.
struct AdminServerStatisticsScreen: View {
    @Environment(SessionStore.self) private var session
    @State private var statistics: ServerStatistics?
    @State private var loadFailed = false

    var body: some View {
        List {
            if let statistics {
                Section("Total") {
                    LabeledContent("Photos", value: statistics.photos.formatted())
                    LabeledContent("Videos", value: statistics.videos.formatted())
                    LabeledContent("Storage", value: statistics.usage.formatted(.byteCount(style: .file)))
                }
                Section("Users") {
                    ForEach(statistics.usageByUser.sorted { $0.usage > $1.usage }) { user in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(user.userName)
                                Spacer()
                                Text(user.usage.formatted(.byteCount(style: .file)))
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(user.photos.formatted()) photos, \(user.videos.formatted()) videos")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let quota = user.quotaSizeInBytes, quota > 0 {
                                ProgressView(value: min(Double(user.usage) / Double(quota), 1)) {
                                    Text("\(user.usage.formatted(.byteCount(style: .file))) of \(quota.formatted(.byteCount(style: .file)))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("Server Statistics")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if statistics == nil {
                if loadFailed {
                    ContentUnavailableView {
                        Label("Couldn't Load Statistics", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView()
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            statistics = try await session.client?.serverStatistics()
            loadFailed = false
        } catch {
            loadFailed = statistics == nil
        }
    }
}
