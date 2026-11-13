import AppKit
import SwiftUI

enum NylaiPalette {
    static let pine = NSColor(srgbRed: 66.0 / 255.0, green: 102.0 / 255.0, blue: 91.0 / 255.0, alpha: 1)
    static let palePine = NSColor(srgbRed: 163.0 / 255.0, green: 193.0 / 255.0, blue: 180.0 / 255.0, alpha: 1)
    static let paper = NSColor(srgbRed: 247.0 / 255.0, green: 247.0 / 255.0, blue: 242.0 / 255.0, alpha: 1)
    static let charcoal = NSColor(srgbRed: 28.0 / 255.0, green: 32.0 / 255.0, blue: 30.0 / 255.0, alpha: 1)
    static let ink = NSColor(srgbRed: 41.0 / 255.0, green: 45.0 / 255.0, blue: 43.0 / 255.0, alpha: 1)
    static let terracotta = NSColor(srgbRed: 204.0 / 255.0, green: 134.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)

    static let accentNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? palePine
            : pine
    }

    static let accent = Color(nsColor: accentNSColor)
}
