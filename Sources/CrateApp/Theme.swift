import SwiftUI

enum Theme {
    struct Palette {
        let ground, chrome, sidebar, ink, dim, faint, rule, ruleStrong, selection, accent: Color
    }

    /// The interface is strictly neutral greyscale. Brick appears only as the accent,
    /// never tinted into a surface, so no background is a darker version of it.
    /// Every text tier meets WCAG AA against every surface it sits on. Do not adjust
    /// these without rechecking contrast.
    static let dark = Palette(
        ground: .hex("0D0D0D"), chrome: .hex("141414"), sidebar: .hex("101010"),
        ink: .hex("FFFFFF"), dim: .hex("8C8C8C"), faint: .hex("828282"),
        rule: .hex("242424"), ruleStrong: .hex("353535"),
        selection: .hex("1E1E1E"), accent: .hex("C0826A")
    )

    /// The light accent is darker than the dark-mode one because brick at C0826A
    /// reaches only 3.7:1 on a light ground, and 914F37 also clears AA on the
    /// selected-row background.
    static let light = Palette(
        ground: .hex("F2F2F2"), chrome: .hex("E9E9E9"), sidebar: .hex("EDEDED"),
        ink: .hex("000000"), dim: .hex("565656"), faint: .hex("666666"),
        rule: .hex("DCDCDC"), ruleStrong: .hex("C2C2C2"),
        selection: .hex("E8E8E8"), accent: .hex("914F37")
    )

    static func palette(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }
}

extension Color {
    static func hex(_ s: String) -> Color {
        let v = UInt32(s, radix: 16) ?? 0
        return Color(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

extension Font {
    /// Departure Mono ships Regular only. Never pair this with .bold() or a fontWeight
    /// modifier: macOS would synthesise a faux bold and break the pixel grid the face
    /// is drawn on.
    static func crate(_ size: CGFloat) -> Font {
        .custom("DepartureMono-Regular", size: size)
    }
}

/// Every control in the app: a 1px stroke on transparent, square corners, no fill.
struct OutlineButtonStyle: ButtonStyle {
    let palette: Theme.Palette
    var active = false
    var size: CGFloat = 27

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(active ? palette.accent : palette.ink)
            .background(Rectangle().fill(configuration.isPressed
                ? palette.ruleStrong.opacity(0.25) : Color.clear))
            .overlay(Rectangle().strokeBorder(
                active ? palette.accent : palette.ruleStrong, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct TextOutlineStyle: ButtonStyle {
    let palette: Theme.Palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.crate(11)).tracking(1)
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Rectangle().fill(configuration.isPressed
                ? palette.ruleStrong.opacity(0.25) : Color.clear))
            .overlay(Rectangle().strokeBorder(palette.ruleStrong, lineWidth: 1))
    }
}
