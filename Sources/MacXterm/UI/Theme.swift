import AppKit
import SwiftUI
import SwiftTerm

/// Цветовые темы терминала.
enum TerminalTheme: String, CaseIterable, Identifiable {
    case defaultDark, solarizedDark, light
    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultDark: "Default Dark"
        case .solarizedDark: "Solarized"
        case .light: "Light"
        }
    }

    var background: NSColor {
        switch self {
        case .defaultDark: .init(hex: 0x1E1F24)
        case .solarizedDark: .init(hex: 0x002B36)
        case .light: .init(hex: 0xFBFBFA)
        }
    }

    var foreground: NSColor {
        switch self {
        case .defaultDark: .init(hex: 0xDCDFE4)
        case .solarizedDark: .init(hex: 0x93A1A1)
        case .light: .init(hex: 0x24292F)
        }
    }

    var cursor: NSColor {
        switch self {
        case .defaultDark: .init(hex: 0x7AA2F7)
        case .solarizedDark: .init(hex: 0x93A1A1)
        case .light: .init(hex: 0x0969DA)
        }
    }

    var selection: NSColor {
        switch self {
        case .defaultDark: .init(hex: 0x3A4259)
        case .solarizedDark: .init(hex: 0x0B4A5A)
        case .light: .init(hex: 0xC8DDF8)
        }
    }

    private var ansiHex: [UInt32] {
        switch self {
        case .defaultDark:
            [0x2A2C33, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xC8CCD4,
             0x5C6370, 0xFF7A85, 0xB5E08F, 0xFFD58F, 0x82C4FF, 0xDA92F0, 0x6FD3DE, 0xFFFFFF]
        case .solarizedDark:
            [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
             0x586E75, 0xCB4B16, 0x93A1A1, 0x839496, 0x657B83, 0x6C71C4, 0x93A1A1, 0xFDF6E3]
        case .light:
            [0x24292F, 0xCF222E, 0x116329, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
             0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F]
        }
    }

    var ansi: [SwiftTerm.Color] {
        ansiHex.map { h in
            SwiftTerm.Color(red: UInt16((h >> 16) & 0xFF) * 257, green: UInt16((h >> 8) & 0xFF) * 257, blue: UInt16(h & 0xFF) * 257)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Настройки терминала (UserDefaults / @AppStorage).
enum Prefs {
    static let fontName = "fontName"
    static let fontSize = "fontSize"
    static let theme = "theme"
    static let copyOnSelect = "copyOnSelect"
    static let pasteOnRightClick = "pasteOnRightClick"
    static let sftpHeight = "sftpHeight"
    static let systemMono = "SF Mono"

    static func register() {
        UserDefaults.standard.register(defaults: [
            fontName: systemMono, fontSize: 13.0, theme: TerminalTheme.defaultDark.rawValue,
            copyOnSelect: false, pasteOnRightClick: false, sftpHeight: 300.0,
        ])
    }

    static var font: NSFont {
        let d = UserDefaults.standard
        let size = CGFloat(max(8, min(32, d.double(forKey: fontSize))))
        let name = d.string(forKey: fontName) ?? systemMono
        if name != systemMono, let f = NSFont(name: name, size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static var currentTheme: TerminalTheme {
        TerminalTheme(rawValue: UserDefaults.standard.string(forKey: theme) ?? "") ?? .defaultDark
    }

    static var monospacedFonts: [String] {
        [systemMono] + NSFontManager.shared.availableFontFamilies.filter { fam in
            guard let f = NSFont(name: fam, size: 13) else { return false }
            return f.isFixedPitch && !fam.hasPrefix(".")
        }
    }
}

extension SessionColor {
    var color: SwiftUI.Color? {
        switch self {
        case .none: nil
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}
