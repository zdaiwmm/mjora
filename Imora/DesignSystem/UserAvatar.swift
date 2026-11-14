import SwiftUI

/// circular avatar for any server user, with an initials fallback.
struct UserAvatar: View {
    @Environment(SessionStore.self) private var session
    let user: User
    var size: CGFloat = 36

    var body: some View {
        Group {
            if user.id == session.user?.id,
               let image = session.optimisticProfileImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if user.profileImagePath?.isEmpty == false, let client = session.client {
                RemoteImage(url: profileImageURL(client: client), targetPixelSize: 120)
            } else {
                Circle()
                    .fill(fallbackColor.gradient)
                    .overlay {
                        Text(initials)
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private var initials: String {
        let parts = user.name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters)
    }

    private var fallbackColor: Color { Color(avatarColor: user.avatarColor) }

    private func profileImageURL(client: ImoraClient) -> URL {
        guard user.id == session.user?.id, let key = session.profileImageCacheKey else {
            return client.profileImageURL(userID: user.id)
        }
        return client.profileImageURL(userID: user.id)
            .appending(queryItems: [URLQueryItem(name: "c", value: key)])
    }
}

extension Color {
    /// the server's avatar color names, shared by users, spaces and groups.
    init(avatarColor name: String?) {
        switch name {
        case "red": self = .red
        case "orange": self = .orange
        case "yellow": self = .yellow
        case "green": self = .green
        case "blue": self = .blue
        case "purple": self = .purple
        case "pink": self = .pink
        case "amber": self = .orange
        case "gray": self = .gray
        default: self = .indigo
        }
    }
}
