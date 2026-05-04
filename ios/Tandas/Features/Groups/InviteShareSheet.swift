import SwiftUI
import UIKit

/// Sheet shown when the user taps "Invitar gente" in GroupSwitcherSheet.
/// Surfaces the active group's invite code so it can be copied / shared
/// from inside the app — V1 didn't have any UI to access it, you had to
/// look at the DB. Now: tap to copy, system Share to send anywhere.
struct InviteShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let group: Group
    @State private var copied: Bool = false

    private var url: URL {
        InviteLinkGenerator.universal(code: group.inviteCode)
    }

    private var shareMessage: String {
        InviteLinkGenerator.shareMessage(groupName: group.name, code: group.inviteCode)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.s6) {
                    header
                    codeSection
                    linkSection
                    shareButton
                }
                .padding(.horizontal, RuulSpacing.s5)
                .padding(.top, RuulSpacing.s5)
                .padding(.bottom, RuulSpacing.s7)
            }
            .background(Color.ruulBackgroundCanvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text("Invitar")
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackgroundCanvas, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text(group.name)
                .ruulTextStyle(RuulTypography.sectionLabelLg)
                .foregroundStyle(Color.ruulTextSecondary)
            Text("Comparte el código")
                .ruulTextStyle(RuulTypography.title)
                .foregroundStyle(Color.ruulTextPrimary)
            Text("Quien lo tenga puede unirse a tu grupo. Si alguien aún no tiene Ruul, manda el link directo.")
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextSecondary)
        }
    }

    private var codeSection: some View {
        Button {
            UIPasteboard.general.string = group.inviteCode
            copyFeedback()
        } label: {
            VStack(alignment: .leading, spacing: RuulSpacing.s2) {
                Text("CÓDIGO")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextTertiary)
                HStack {
                    Text(group.inviteCode.uppercased())
                        .ruulTextStyle(RuulTypography.monoLarge)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Spacer()
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(copied ? Color.ruulSemanticSuccess : Color.ruulTextSecondary)
                }
            }
            .padding(RuulSpacing.s4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .fill(Color.ruulBackgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                    .stroke(Color.ruulBorderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copiar código")
        .sensoryFeedback(.success, trigger: copied)
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            Text("LINK")
                .ruulTextStyle(RuulTypography.footnote)
                .foregroundStyle(Color.ruulTextTertiary)
            Text(url.absoluteString)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
                .lineLimit(2)
                .padding(RuulSpacing.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                        .fill(Color.ruulBackgroundRecessed)
                )
        }
    }

    private var shareButton: some View {
        ShareLink(
            item: url,
            subject: Text("Te invito a \(group.name)"),
            message: Text(shareMessage)
        ) {
            HStack {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                Text("Compartir")
                    .ruulTextStyle(RuulTypography.body)
            }
            .foregroundStyle(Color.ruulTextInverse)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                Capsule().fill(Color.ruulAccentPrimary)
            )
        }
        .buttonStyle(.plain)
    }

    private func copyFeedback() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { copied = false }
        }
    }
}
