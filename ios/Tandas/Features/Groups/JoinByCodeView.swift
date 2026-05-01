import SwiftUI

struct JoinByCodeView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var vm: GroupsViewModel?
    @State private var feedback: Int = 0

    var body: some View {
        ZStack {
            Brand.Surface.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Brand.Layout.sectionGap) {
                Spacer().frame(height: 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Unirme con código")
                        .font(Brand.Typography.heroTitle)
                        .foregroundStyle(Brand.Surface.textPrimary)
                    Text("Pega los 8 caracteres del invite code.")
                        .font(Brand.Typography.body)
                        .foregroundStyle(Brand.Surface.textSecondary)
                }

                if let vm {
                    @Bindable var bvm = vm
                    LumaField(label: "Código", error: vm.joinError) {
                        TextField("abc12345", text: $bvm.joinCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .onChange(of: bvm.joinCode) { _, new in
                                bvm.joinCode = String(new.prefix(8))
                            }
                    }

                    Button {
                        Task {
                            await vm.join()
                            if vm.joinedGroup != nil {
                                feedback &+= 1
                                await app.refreshProfileAndGroups()
                            }
                        }
                    } label: {
                        Text(vm.isJoining ? "Uniéndome…" : "Unirme")
                            .frame(maxWidth: .infinity)
                            .lumaPrimaryPill()
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isJoining || vm.joinCode.count < 8)
                }

                Spacer()
            }
            .padding(.horizontal, Brand.Layout.pagePadH)
            .padding(.bottom, 32)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Brand.Surface.textPrimary)
                }
            }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Brand.Surface.canvas, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .navigationDestination(item: bindingForJoined()) { group in
            WelcomeView(group: group)
        }
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
