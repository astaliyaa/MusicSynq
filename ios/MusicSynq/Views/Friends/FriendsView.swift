import MusicSynqKit
import SwiftUI

/** Find people by username, answer requests, and see what friends are up to. */
struct FriendsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [UserSearchResult] = []
    @State private var searching = false
    @State private var joining: JoinTarget?
    @State private var removing: Friend?

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else {
                    content
                }
            }
            .navigationTitle("Friends")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Add friends by username")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .task(id: query) { await search() }
            .refreshable { await model.refreshEverything() }
            .sheet(item: $joining) { target in
                JoinPartySheet(summary: target.summary)
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog(
                "Remove \(removing?.user.displayName ?? "friend")?",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                titleVisibility: .visible,
                presenting: removing
            ) { friend in
                Button("Remove friend", role: .destructive) { Task { await model.removeFriend(friend) } }
            } message: { _ in
                Text("You won't see each other's parties any more.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let me = model.user {
            Section {
                HStack(spacing: 12) {
                    Avatar(user: me, size: 44)
                    VStack(alignment: .leading) {
                        Text(me.displayName).font(.headline)
                        Text("@\(me.username)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShareLink(item: "Add me on MusicSynq so we can listen together! My username is @\(me.username)") {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share your username")
                }
            } footer: {
                Text("Friends add you by your username.")
            }
        }

        if !model.friends.incoming.isEmpty {
            Section("Friend requests") {
                ForEach(model.friends.incoming) { request in
                    HStack(spacing: 12) {
                        Avatar(user: request.from, size: 40)
                        UserLabel(user: request.from)
                        Spacer()
                        Button {
                            Task { await model.removeRequest(id: request.id) }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Decline")
                        Button("Accept") { Task { await model.accept(request) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }

        Section(model.friends.friends.isEmpty ? "Friends" : "Friends (\(model.friends.friends.count))") {
            if model.friends.friends.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No friends yet")
                        .font(.headline)
                    Text("Search for a friend's username above and send them a request. Once they accept, you can join each other's parties.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            ForEach(model.friends.friends) { friend in
                FriendRow(friend: friend) {
                    if let party = friend.party { joining = JoinTarget(summary: party) }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { removing = friend }
                }
            }
        }

        if !model.friends.outgoing.isEmpty {
            Section("Sent requests") {
                ForEach(model.friends.outgoing) { request in
                    HStack(spacing: 12) {
                        Avatar(user: request.to, size: 40)
                        UserLabel(user: request.to)
                        Spacer()
                        Button("Cancel") { Task { await model.removeRequest(id: request.id) } }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        Section {
            if searching && results.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if results.isEmpty {
                Text("No one with a username starting with “\(query)”.")
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { result in
                HStack(spacing: 12) {
                    Avatar(user: result.user, size: 40)
                    UserLabel(user: result.user)
                    Spacer()
                    relationshipButton(result)
                }
            }
        } header: {
            Text("People")
        }
    }

    @ViewBuilder
    private func relationshipButton(_ result: UserSearchResult) -> some View {
        switch result.relationship {
        case .friend:
            Label("Friends", systemImage: "checkmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .outgoing:
            Text("Requested")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .incoming:
            Button("Accept") {
                Task {
                    if let id = result.requestId { await model.acceptRequest(id: id) }
                    await search()
                }
            }
            .buttonStyle(.borderedProminent)
        case .none, .unknown:
            Button("Add") {
                Task {
                    do {
                        _ = try await model.addFriend(username: result.user.username)
                    } catch {
                        model.notice = AppModel.Notice(title: "Couldn't add friend", message: error.localizedDescription)
                    }
                    await search()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else {
            results = []
            return
        }
        searching = true
        // Debounce typing.
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        let found = await model.searchUsers(term)
        guard !Task.isCancelled else { return }
        results = found
        searching = false
    }
}

private struct UserLabel: View {
    let user: User

    var body: some View {
        VStack(alignment: .leading) {
            Text(user.displayName).font(.subheadline.weight(.semibold))
            Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FriendRow: View {
    let friend: Friend
    let join: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Avatar(user: friend.user, size: 40, showsOnline: friend.online)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.user.displayName).font(.subheadline.weight(.semibold))
                if let party = friend.party {
                    HStack(spacing: 4) {
                        EqualizerIcon(isAnimating: party.isPlaying)
                        Text(party.nowPlaying.map { "Hosting · \($0.title)" } ?? "Hosting a party")
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.tint)
                } else {
                    Text("@\(friend.user.username)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if friend.party != nil {
                Button("Join", action: join)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}
