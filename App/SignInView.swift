import SwiftUI

struct SignInView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 28) {
      VStack(spacing: 10) {
        Image(systemName: "envelope.fill")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 64, height: 64)
          .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .shadow(color: Theme.accent.opacity(0.3), radius: 12, y: 6)
        Text("Raven")
          .font(.system(size: 28, weight: .bold))
          .padding(.top, 6)
        Text("Fast, keyboard-first email for your Mac.")
          .foregroundStyle(Theme.tertiary)
      }

      VStack(spacing: 10) {
        if model.oauth != nil {
          Button {
            model.signIn()
          } label: {
            HStack(spacing: 8) {
              if model.phase == .signingIn {
                ProgressView().controlSize(.small).tint(.white)
                Text("Waiting for your browser…")
              } else {
                Text("Sign in with Google")
              }
            }
            .frame(width: 260, height: 40)
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(model.phase == .signingIn)
          if model.phase == .signingIn {
            Button("Cancel") { model.cancelSignIn() }
              .buttonStyle(.plain)
              .font(.system(size: 12))
              .foregroundStyle(Theme.secondary)
              .transition(.opacity)
          }
        } else {
          #if DEBUG
            Text("Google sign-in isn't set up in this build.\nAdd your OAuth client to Config/Secrets.xcconfig.")
              .multilineTextAlignment(.center)
              .font(.callout)
              .foregroundStyle(Theme.secondary)
              .frame(maxWidth: 360)
          #endif
        }
        Button("Explore with sample mail") { Task { await model.startDemo() } }
          .buttonStyle(SecondaryButtonStyle())
      }

      if let error = model.errorMessage {
        Text(error)
          .font(.callout)
          .foregroundStyle(Color(hex: 0xB91C1C))
          .frame(maxWidth: 420)
          .multilineTextAlignment(.center)
      }

      Text("Your mail syncs straight to this Mac. Nothing goes through a Raven server.")
        .font(.footnote)
        .foregroundStyle(Theme.tertiary)
    }
    .animation(Motion.state, value: model.phase)
    .padding(48)
    .frame(width: 520)
    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .shadow(color: .black.opacity(0.06), radius: 24, y: 8)
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.white)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(Theme.accent)
          .brightness(configuration.isPressed ? -0.08 : 0)
          .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(Motion.hover, value: configuration.isPressed)
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, 14)
      .frame(height: 34)
      .background(configuration.isPressed ? Theme.fill : .white, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
      .animation(Motion.hover, value: configuration.isPressed)
  }
}

/// Icon-only toolbar button, 32×32 like the designs.
struct IconButton: View {
  let systemName: String
  let label: String
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(hovered ? Theme.ink : Theme.secondary)
        .frame(width: 32, height: 32)
        .background(hovered ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
    .buttonStyle(PressableStyle())
    .help(label)
    .accessibilityLabel(label)
    .onHover { h in withAnimation(Motion.hover) { hovered = h } }
  }
}
