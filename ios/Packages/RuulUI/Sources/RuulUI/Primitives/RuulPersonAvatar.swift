import SwiftUI

/// DS v3 §3.10 alias para `RuulAvatar` (avatar de persona/miembro).
/// Distinto de `RuulGroupAvatar` (avatar del grupo con color ramp automático
/// según la categoría del grupo).
///
/// El typealias `RuulAvatarView = RuulAvatar` ya existía en
/// `Patterns/RuulStatePatterns+Aliases.swift`; éste agrega el segundo nombre
/// canonico per DS v3 sin tocar callsites existentes.
public typealias RuulPersonAvatar = RuulAvatar
