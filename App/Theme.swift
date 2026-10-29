import RavenCore
import SwiftUI

/// Colors from the v0.1 designs: soft gray window, white content panel, one indigo accent.
enum Theme {
  static let window = Color(hex: 0xF3F3F6)
  static let panel = Color.white
  static let ink = Color(hex: 0x18181B)
  static let secondary = Color(hex: 0x52525B)
  static let tertiary = Color(hex: 0x71717A)
  static let hairline = Color(hex: 0xF0F0F3)
  static let border = Color(hex: 0xE4E4E7)
  static let fill = Color(hex: 0xF4F4F5)
  static let accent = Color(hex: 0x4F4FC9)
  static let accentSoft = Color(hex: 0xEEEEFB)
  static let accentInk = Color(hex: 0x3E3EA8)
  static let selection = Color(hex: 0xF4F4FB)
  static let selectionRing = Color(hex: 0xE0E0F7)
  static let success = Color(hex: 0x15803D)
  static let successSoft = Color(hex: 0xF0FDF4)

  /// Soft avatar colors, picked from the sender's address so a person keeps their color.
  static func avatar(for email: String) -> (background: Color, foreground: Color) {
    let palette: [(UInt32, UInt32)] = [
      (0xFDE7D9, 0x9A3412), (0xDCFCE7, 0x166534), (0xE0E7FF, 0x3730A3), (0xFCE7F3, 0x9D174D),
      (0xE0F2FE, 0x075985), (0xFEF3C7, 0x92400E), (0xEDE9FE, 0x5B21B6),
    ]
    let index = email.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff } % palette.count
    return (Color(hex: palette[index].0), Color(hex: palette[index].1))
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

struct Avatar: View {
  let address: Address
  var size: CGFloat = 32

  var body: some View {
    let colors = Theme.avatar(for: address.email)
    Text(address.initials)
      .font(.system(size: size * 0.38, weight: .semibold))
      .foregroundStyle(colors.foreground)
      .frame(width: size, height: size)
      .background(colors.background, in: Circle())
      .accessibilityHidden(true)
  }
}

/// A keycap like the ⌘K hint in the designs.
struct KeyCap: View {
  let label: String
  var body: some View {
    Text(label)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(Theme.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.white, in: RoundedRectangle(cornerRadius: 6))
      .shadow(color: .black.opacity(0.08), radius: 0.5, y: 1)
  }
}
