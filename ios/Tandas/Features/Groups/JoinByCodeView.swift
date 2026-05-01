import SwiftUI

struct JoinByCodeView: View {
    @Environment(AppState.self) private var app
    @State private var vm: GroupsViewModel?
    @State private var feedback: Int = 0

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: Brand.Spacing.xl) {
                Spacer().frame(height: Brand.Spacing.xl)
                VStack(spacing: Brand.Spacing.s) {
                    Text("Unirme con código").font(.tandaHero).foregroundStyle(.white)
                    Text("Pega los 8 caracteres del invite code.")
                        .font(.tandaBody).foregroundStyle(.white.opacity(0.7))
                }
                if let vm {
                    @Bindable var bvm = vm
                    Field(label: "Código", error: vm.joinError) {
                        TextField("abc12345", text: $bvm.joinCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.tandaTitle.monospaced())
                            .foregroundStyle(.white)
                            .onChange(of: bvm.joinCode) { _, new in
                                bvm.joinCode = String(new.prefix(8))
                            }
                    }
                    GlassCapsuleButton(vm.isJoining ? "Uniéndome…" : "Unirme") {
                        Task {
                            await vm.join()
                            if vm.joinedGroup != nil {
                                feedback &+= 1
                                await app.refreshProfileAndGroups()
                            }
                        }
                    }
                    .disabled(vm.isJoining || vm.joinCode.count < 8)
                }
                Spacer()
            }
            .padding(.horizontal, Brand.Spacing.xl)
        }
        .navigationDestination(item: bindingForJoined()) { group in
            WelcomeView(group: group)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: feedback)
        .onAppear { if vm == nil { vm = GroupsViewModel(groupsRepo: app.groupsRepo) } }
    }

    private func bindingForJoined() -> Binding<Group?> {
        Binding(
            get: { vm?.joinedGroup },
            set: { vm?.joinedGroup = $0 }
        )
    }
}

// WelcomeView stub — implemented in T15
struct WelcomeView: View {
    let group: Group
    var body: some View { Text("Welcome to \(group.name) (stub)").foregroundStyle(.white) }
}
