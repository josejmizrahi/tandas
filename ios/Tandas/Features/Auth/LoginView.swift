import SwiftUI
import AuthenticationServices
import CryptoKit

struct LoginView: View {
    @Environment(AppState.self) private var app
    @State private var vm: AuthViewModel?
    @State private var nonce: String = AppleNonce.generate()

    var body: some View {
        NavigationStack {
            ZStack {
                MeshBackground()
                ScrollView {
                    VStack(spacing: Brand.Spacing.xl) {
                        Spacer().frame(height: Brand.Spacing.xxl * 2)
                        header
                        appleButton
                        divider
                        methodPicker
                        inputField
                        sendButton
                        if let error = vm?.errorMessage {
                            Text(error).font(.tandaCaption).foregroundStyle(.red)
                        }
                        Spacer().frame(height: Brand.Spacing.xl)
                        footer
                    }
                    .padding(.horizontal, Brand.Spacing.xl)
                }
            }
            .navigationDestination(item: bindingForChannel()) { channel in
                OTPInputView(channel: channel)
            }
        }
        .onAppear {
            if vm == nil { vm = AuthViewModel(auth: app.auth) }
        }
    }

    private var header: some View {
        VStack(spacing: Brand.Spacing.s) {
            Text("Tandas")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("La vida en grupo, sin pleitos.")
                .font(.tandaBody)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.continue) { request in
            request.requestedScopes = [.fullName, .email]
            request.nonce = AppleNonce.sha256(nonce)
        } onCompletion: { result in
            handleAppleCompletion(result)
        }
        .signInWithAppleButtonStyle(.white)
        .frame(height: 52)
        .clipShape(Capsule())
    }

    private var divider: some View {
        HStack {
            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
            Text("o").font(.tandaCaption).foregroundStyle(.white.opacity(0.5))
            Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5)
        }
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
                Field(label: "Tu número", description: "Te mandamos un código de 6 dígitos por SMS.") {
                    TextField("+5215555551234", text: $bvm.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .foregroundStyle(.white)
                }
            case .email:
                Field(label: "Tu email", description: "Te mandamos un código de 6 dígitos por correo.") {
                    TextField("tu@email.com", text: $bvm.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                }
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if let vm {
            GlassCapsuleButton(vm.isSending ? "Enviando…" : "Enviarme código") {
                Task { await vm.sendOTP() }
            }
            .disabled(vm.isSending)
        }
    }

    private var footer: some View {
        Text("Al continuar aceptas las reglas que tu grupo defina.")
            .font(.tandaCaption)
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
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
            break  // user cancelled; no-op
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
