import SwiftUI

/// The first screen, and the only one before the app.
///
/// One form, two modes. Sign-in and sign-up are the same two fields and differ
/// by one word on a button — separate screens for them is a tab bar's worth of
/// chrome around an email and a password.
///
/// It says what the app is before it asks for anything. Someone who just
/// downloaded a boxing app knows what a password is; what they don't know yet is
/// whether this thing is a timer or a coach.
struct SignInView: View {

    let auth: AuthController

    @State private var isRegistering = false
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                mark
                form
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 60)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.Palette.background)
    }

    private var mark: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.Palette.accent)
                .frame(width: 76, height: 76)
                .overlay {
                    Image(systemName: "figure.boxing")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.white)
                }

            Text("Corner")
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(.primary)
                .padding(.top, 20)

            Text("A cornerman who writes the session,\ncalls the rounds, and remembers.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        }
        .padding(.bottom, 40)
    }

    private var form: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .submitLabel(.next)
                .onSubmit { focus = .password }
                .padding(14)
                .background(Theme.Palette.surface, in: .rect(cornerRadius: 14))

            SecureField("Password", text: $password)
                // `.newPassword` on the register path so the keychain offers to
                // generate one, `.password` on sign-in so it offers to fill the
                // saved one. The same field asking for two different things.
                .textContentType(isRegistering ? .newPassword : .password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit { submit() }
                .padding(14)
                .background(Theme.Palette.surface, in: .rect(cornerRadius: 14))

            if let problem = auth.problem {
                message(problem, color: .red)
            }
            if let notice = auth.notice {
                message(notice, color: Theme.Palette.accent)
            }

            Button(action: submit) {
                Group {
                    if auth.isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text(isRegistering ? "Create account" : "Sign in")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Theme.Palette.accent, in: .capsule)
                .foregroundStyle(.white)
            }
            .disabled(auth.isWorking)
            .padding(.top, 4)
        }
    }

    private var footer: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isRegistering.toggle() }
        } label: {
            Text(isRegistering ? "Already have an account? Sign in" : "New here? Create an account")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func submit() {
        focus = nil
        Task {
            if isRegistering {
                await auth.signUp(email: email, password: password)
            } else {
                await auth.signIn(email: email, password: password)
            }
        }
    }
}

#Preview {
    SignInView(auth: AuthController())
        .preferredColorScheme(.dark)
}
