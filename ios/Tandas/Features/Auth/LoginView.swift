import SwiftUI
import AuthenticationServices
import CryptoKit

/// Luma-style login: brand mark + SiwA + phone/email tabs + field + CTA.
struct LoginView: View {
    @Environment(AppState.self) private var app
    @State private var vm: AuthViewModel?
    @State private var nonce: String = AppleNonce.generate()

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.Surface.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Brand.Layout.sectionGap) {
                        Spacer().frame(height: 80)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkle")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(Brand.Surface.textPrimary)
                                Text("ruul")
                                    .font(.system(size: 36, weight: .bold))
                                    .foregroundStyle(Brand.Surface.textPrimary)
                            }
                            Text("La vida en grupo, sin pleitos.")
                                .font(Brand.Typography.body)
                                .foregroundStyle(Brand.Surface.textSecondary)
                        }

                        VStack(spacing: 12) {
                            appleButton
                            divider
                            methodPicker
                            inputField
                            sendButton
                            if let error = vm?.errorMessage {
                                Text(error)
                                    .font(Brand.Typography.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        Spacer()
                        footer
                    }
                    .padding(.horizontal, Brand.Layout.pagePadH)
                    .padding(.bottom, 32)
                }
            }
            .navigationDestination(item: bindingForChannel()) { channel in
                OTPInputView(channel: channel)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            if vm == nil { vm = AuthViewModel(auth: app.auth) }
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleNonce.sha256(nonce)
        } onCompletion: { result in
            handleAppleCompletion(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: Brand.Layout.primaryHeight)
        .clipShape(Capsule())
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Brand.Surface.border).frame(height: 1)
            Text("o")
                .font(Brand.Typography.caption)
                .foregroundStyle(Brand.Surface.textTertiary)
            Rectangle().fill(Brand.Surface.border).frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var methodPicker: some View {
        if let vm {
            @Bindable var bvm = vm
            Picker("Método", selection: $bvm.method) {
                ForEach(AuthMethod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: vm.method)
        }
    }

    @ViewBuilder
    private var inputField: some View {
        if let vm {
            @Bindable var bvm = vm
            switch vm.method {
            case .phone:
                LumaField(label: "Teléfono", helper: "Te mandamos un código por SMS.") {
                    TextField("+5215555551234", text: $bvm.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                }
            case .email:
                LumaField(label: "Email", helper: "Te mandamos un código por correo.") {
                    TextField("tu@email.com", text: $bvm.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if let vm {
            Button {
                Task { await vm.sendOTP() }
            } label: {
                Text(vm.isSending ? "Enviando…" : "Continuar")
                    .frame(maxWidth: .infinity)
                    .lumaPrimaryPill()
            }
            .buttonStyle(.plain)
            .disabled(vm.isSending)
        }
    }

    private var footer: some View {
        Text("Al continuar aceptas las reglas que tu grupo defina.")
            .font(Brand.Typography.caption)
            .foregroundStyle(Brand.Surface.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func bindingForChannel() -> Binding<OTPChannel?> {
        Binding(
            get: { vm?.pendingChannel },
            set: { vm?.pendingChannel = $0 }
        )
    }

    private func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let token = String(data: tokenData, encoding: .utf8)
            else { return }
            let captured = nonce
            Task {
                if let live = self.vm?.auth as? LiveAuthService {
                    _ = try? await live.signInWithApple(idToken: token, nonce: captured)
                } else {
                    _ = try? await self.vm?.auth.signInWithApple()
                }
            }
        case .failure:
            break
        }
    }
}

enum AppleNonce {
    static func generate() -> String {
        let chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        return String((0..<32).map { _ in chars.randomElement()! })
    }
    static func sha256(_ input: String) -> String {
        Data(input.utf8).sha256Hex
    }
}

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
