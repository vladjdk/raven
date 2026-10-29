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
            Task { await model.signIn() }
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
        } else {
          Text("Google sign-in isn't configured in this build.\nAdd your OAuth client to Config/Secrets.xcconfig.")
            .multilineTextAlignment(.center)
            .font(.callout)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: 360)
        }
        Button("Explore with sample mail") { Task { await model.startDemo() } }
          .buttonStyle(SecondaryButtonStyle())
      }

      if let error = model.errorMessage {
        Text(error)
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: 420)
          .multilineTextAlignment(.center)
      }

      Text("Your mail syncs straight to this Mac. Nothing goes through a Raven server.")
        .font(.footnote)
        .foregroundStyle(Theme.tertiary)
    }
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
      .background(Theme.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 10))
      .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
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
  }
}

/// Icon-only toolbar button, 32×32 like the designs.
struct IconButton: View {
  let systemName: String
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Theme.secondary)
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }
}
