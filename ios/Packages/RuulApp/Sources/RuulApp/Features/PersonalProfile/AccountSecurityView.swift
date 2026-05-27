import SwiftUI
import RuulCore

/// Read-only surface that exposes the caller's `auth.users` contact
/// (email/phone) + user id. The real change flow (start* + confirm*
/// OTP from `AuthService.startPhoneChange/startEmailChange`) is a
/// future slice with its own validation, OTP entry and error mapping —
/// for now the surface is discoverable and the buttons surface a
/// neutral "Próximamente" hint instead of dead-ending.
struct AccountSecurityView: View {
    let session: AppSession?

    @State private var isShowingComingSoon: Bool = false

    var body: some View {
        Form {
            contactSection
            changeSection
            if let session {
                identifierSection(session: session)
            }
        }
        .navigationTitle(L10n.AccountSecurity.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            Text(L10n.AccountSecurity.comingSoonTitle),
            isPresented: $isShowingComingSoon
        ) {
            Button(String(localized: L10n.AccountSecurity.close)) {
                isShowingComingSoon = false
            }
        } message: {
            Text(L10n.AccountSecurity.comingSoonBody)
        }
    }

    @ViewBuilder
    private var contactSection: some View {
        Section(L10n.AccountSecurity.contactSection) {
            LabeledContent {
                Text(session?.user.email ?? String(localized: L10n.AccountSecurity.noEmail))
                    .foregroundStyle(session?.user.email == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Label {
                    Text(L10n.AccountSecurity.emailLabel)
                } icon: {
                    Image(systemName: "envelope")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent {
                Text(session?.user.phone ?? String(localized: L10n.AccountSecurity.noPhone))
                    .foregroundStyle(session?.user.phone == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Label {
                    Text(L10n.AccountSecurity.phoneLabel)
                } icon: {
                    Image(systemName: "phone")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var changeSection: some View {
        Section(L10n.AccountSecurity.changeSection) {
            Button {
                isShowingComingSoon = true
            } label: {
                Label(L10n.AccountSecurity.changePhone, systemImage: "phone.arrow.up.right")
            }
            Button {
                isShowingComingSoon = true
            } label: {
                Label(L10n.AccountSecurity.changeEmail, systemImage: "envelope.arrow.triangle.branch")
            }
        }
    }

    @ViewBuilder
    private func identifierSection(session: AppSession) -> some View {
        Section(L10n.AccountSecurity.userIdSection) {
            LabeledContent {
                Text(session.user.id.uuidString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                Text(L10n.AccountSecurity.userIdLabel)
            }
        }
    }
}
