import CodenessCore
import Foundation
import SwiftUI

struct CompanyAvatarView: View {
    let person: CompanyPerson
    let size: CGFloat

    private var source: CompanyAvatarSource {
        CompanyAvatarSource(identity: [
            person.profile.fullName,
            person.position.title,
            person.profile.background,
            person.profile.workingStyle,
            person.profile.personalStake
        ].joined(separator: "|"))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.quaternary)
            if person.positionID == .chiefExecutive {
                Circle()
                    .fill(Color.orange)
            }

            AsyncImage(url: source.url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: innerSize, height: innerSize)
            .clipShape(Circle())
        }
        .frame(width: size, height: size)
        .overlay {
            if person.positionID != .chiefExecutive {
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }
        }
        .accessibilityHidden(true)
    }

    private var innerSize: CGFloat {
        if person.positionID == .chiefExecutive {
            return max(1, size - max(5, size * 0.16))
        }
        return max(1, size - max(3, size * 0.08))
    }
}

struct CompanyAvatarSource: Equatable {
    let seed: String

    init(identity: String) {
        let hash = identity.utf8.reduce(14_695_981_039_346_656_037) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let hexadecimal = String(hash, radix: 16)
        seed = String(repeating: "0", count: max(0, 16 - hexadecimal.count)) + hexadecimal
    }

    var url: URL {
        var components = URLComponents(
            string: "https://api.dicebear.com/10.x/adventurer-neutral/png"
        )!
        components.queryItems = [
            URLQueryItem(name: "seed", value: seed),
            URLQueryItem(name: "size", value: "128"),
            URLQueryItem(name: "radius", value: "50")
        ]
        return components.url!
    }
}
