import SwiftUI

enum GroupCamTheme {
    static let ink = Color(red: 0.09, green: 0.08, blue: 0.07)
    static let paper = Color(red: 0.95, green: 0.91, blue: 0.83)
    static let brass = Color(red: 0.72, green: 0.53, blue: 0.25)
    static let safe = Color(red: 0.36, green: 0.72, blue: 0.49)
    static let warning = Color(red: 0.91, green: 0.62, blue: 0.22)

    static let controlGradient = LinearGradient(
        colors: [Color.white.opacity(0.22), Color.black.opacity(0.18)],
        startPoint: .top,
        endPoint: .bottom
    )
}

struct RaisedButtonStyle: ButtonStyle {
    let tint: Color

    init(tint: Color = GroupCamTheme.brass) {
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint)
                    .overlay(GroupCamTheme.controlGradient.clipShape(RoundedRectangle(cornerRadius: 16)))
                    .shadow(
                        color: .black.opacity(configuration.isPressed ? 0.14 : 0.32),
                        radius: configuration.isPressed ? 1 : 4,
                        y: configuration.isPressed ? 1 : 4
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
