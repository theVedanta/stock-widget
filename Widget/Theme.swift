import SwiftUI

enum Theme {
    static let background = Color(hex: 0x000000)     // OLED black
    static let card = Color(hex: 0x18181B)           // zinc-900
    static let border = Color(hex: 0x27272A)         // zinc-800
    static let textPrimary = Color(hex: 0xFAFAFA)    // zinc-50
    static let textSecondary = Color(hex: 0xA1A1AA)  // zinc-400
    static let textTertiary = Color(hex: 0x71717A)   // zinc-500
    static let gain = Color(hex: 0x10B981)           // emerald-500
    static let loss = Color(hex: 0xE5484D)           // muted crimson
    static let warning = Color(hex: 0xF5A524)

    static func trend(_ value: Double) -> Color {
        value > 0 ? gain : (value < 0 ? loss : textSecondary)
    }

    /// Neutral identity dots so the two brokers are distinguishable without
    /// colliding with the green/red P&L semantics.
    static func broker(_ id: BrokerID) -> Color {
        switch id {
        case .groww: Color(hex: 0xA78BFA)  // violet-400
        case .ibkr: Color(hex: 0x38BDF8)   // sky-400
        default: textSecondary
        }
    }
}

extension Font {
    /// SF Pro Rounded — used for every number.
    static func numeric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// SF Pro (Display at large sizes) — labels and tickers.
    static func label(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
