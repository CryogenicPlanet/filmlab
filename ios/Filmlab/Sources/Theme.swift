import SwiftUI

/// Tokens drawn from negative film: the orange-brown base, amber edge printing, print paper.
enum Theme {
    static let black = Color.black
    static let base = Color(red: 0x3A / 255, green: 0x24 / 255, blue: 0x16 / 255)
    static let baseDeep = Color(red: 0x24 / 255, green: 0x16 / 255, blue: 0x0D / 255)
    static let edge = Color(red: 0xF2 / 255, green: 0xA9 / 255, blue: 0x3B / 255)
    static let paper = Color(red: 0xED / 255, green: 0xE7 / 255, blue: 0xDC / 255)
    static let fog = Color(red: 0x8C / 255, green: 0x85 / 255, blue: 0x7C / 255)

    /// Camera-marking numerals and look names.
    static func din(_ size: CGFloat) -> Font { .custom("DINCondensed-Bold", size: size) }
}

extension View {
    /// Small round control on the viewfinder.
    func chip() -> some View {
        frame(width: 38, height: 38)
            .background(.black.opacity(0.35), in: .circle)
            .foregroundStyle(Theme.paper)
    }
}
