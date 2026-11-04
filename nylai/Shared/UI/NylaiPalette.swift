import AppKit
import SwiftUI

enum NylaiPalette {
    static let deepOlive = NSColor(srgbRed: 63.0 / 255.0, green: 81.0 / 255.0, blue: 47.0 / 255.0, alpha: 1)
    static let olive = NSColor(srgbRed: 89.0 / 255.0, green: 100.0 / 255.0, blue: 72.0 / 255.0, alpha: 1)
    static let cream = NSColor(srgbRed: 244.0 / 255.0, green: 240.0 / 255.0, blue: 230.0 / 255.0, alpha: 1)
    static let terracotta = NSColor(srgbRed: 204.0 / 255.0, green: 134.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)

    static let accentNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 174.0 / 255.0, green: 193.0 / 255.0, blue: 140.0 / 255.0, alpha: 1)
            : deepOlive
    }

    static let accent = Color(nsColor: accentNSColor)
}
