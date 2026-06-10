# Visión Fundacional de Ruul

> North star del proyecto. Complementa `Docs/Ruul-Social-Primitives-and-Product-Logic.md` (primitivas sociales y lógica de producto) y los Plans activos. El Audit manda sobre prioridades técnicas inmediatas; este documento define hacia dónde va todo.

Ruul debe construirse como un **ecosistema social escalable para digitalizar el mundo social**.

No es solo una app de grupos, eventos o gastos. Ruul debe ser una capa operativa donde actores —personas, grupos, familias, comunidades, organizaciones, fondos, recursos y entidades colectivas— puedan interactuar dentro de contextos, espacios o grupos con reglas claras, permisos, memoria, recursos, dinero, decisiones, gobernanza y automatización.

La meta es convertir acciones sociales reales en flujos digitales simples, seguros y trazables.

Ruul debe permitir desde lo más sencillo:

- crear un grupo
- invitar amigos
- organizar una cena
- dividir un gasto
- crear una regla
- votar una decisión
- reservar un recurso
- marcar asistencia
- registrar una multa
- liquidar saldos

hasta lo más robusto:

- vender un recurso con un click
- transferir ownership vía gobernanza
- manejar fondos colectivos
- administrar recursos compartidos
- automatizar check-in por ubicación del iPhone
- disparar reglas según presencia, tiempo, deuda, rol o evento
- ejecutar decisiones aprobadas
- generar liquidaciones automáticas
- conservar memoria institucional
- fomentar desarrollo social, cooperación, confianza y responsabilidad colectiva

Ruul debe facilitar todas las acciones del usuario y eliminar procesos manuales innecesarios.

## Principio de producto

Cada flujo debe responder:

1. ¿Qué quiere lograr el usuario en la vida real?
2. ¿Qué actor está actuando?
3. ¿En qué contexto, espacio o grupo ocurre?
4. ¿Qué recurso, regla, evento, dinero o decisión está involucrado?
5. ¿Qué permisos se requieren?
6. ¿Debe pasar por gobernanza?
7. ¿Qué se automatiza?
8. ¿Qué queda auditado?
9. ¿Qué debe ver el usuario de forma simple?
10. ¿Qué debe resolver el backend sin exponer complejidad?

## UX/UI

Ruul debe tener UX y UI de primer nivel.

Debe seguir las mejores prácticas actuales de diseño de productos iOS:

- claridad antes que complejidad
- acciones evidentes
- navegación simple
- lenguaje humano
- estados vacíos útiles
- errores accionables
- feedback inmediato
- jerarquía visual clara
- accesibilidad desde la base
- diseño responsive para distintos tamaños
- componentes reutilizables
- flujos cortos
- automatización visible pero no invasiva
- progressive disclosure: mostrar lo simple primero y lo avanzado cuando haga falta

El usuario no debe sentir que usa un sistema de gobernanza, permisos, RPCs, resources o ledgers.

Debe sentir:

- "sé qué está pasando"
- "sé qué tengo que hacer"
- "sé quién debe qué"
- "sé quién puede usar qué"
- "sé qué decidimos"
- "sé qué regla aplica"
- "sé qué pasó antes"
- "puedo resolverlo rápido"

El lenguaje visual debe usar términos amigables:

- grupos, espacios, círculos o comunidades en vez de "contextos" si eso ayuda
- cosas, recursos, fondos, eventos y acuerdos en vez de términos técnicos
- "quién puede usarlo" en vez de resource_rights
- "quién es dueño" en vez de ownership internamente técnico
- "lo que se decidió" en vez de decision execution
- "historial" en vez de audit log

## Swift / iOS / WWDC26

El frontend debe modernizarse usando las mejores prácticas actuales del ecosistema Apple y las novedades disponibles en Swift, SwiftUI, SwiftData, App Intents, Apple Intelligence, Foundation Models, Core Spotlight, Live Activities, Location, Wallet, App Shortcuts, Swift Testing, Instruments y Xcode anunciadas o actualizadas en WWDC26 cuando sean estables y compatibles con el deployment target del proyecto.

Referencias relevantes de WWDC26 a revisar e incorporar cuando aplique:

- What's new in Swift
- What's new in SwiftUI
- What's new in SwiftData
- Explore advanced App Intents features for Siri and Apple Intelligence
- Build intelligent Siri experiences with App Schemas
- What's new in the Foundation Models framework
- Build agentic app experiences with the Foundation Models framework
- LLM search using Core Spotlight
- Live Activities essentials
- Migrate to Swift Testing
- Profile, fix, and verify: Improve app responsiveness with Instruments
- Principles of great design
- App Attest / security sessions
- Trust Insights / privacy and safety sessions

El equipo debe revisar las sesiones oficiales de WWDC26 antes de adoptar APIs nuevas. Apple documenta Apple Intelligence y Foundation Models como capacidades para construir funciones inteligentes dentro de apps, incluyendo prompts multimodales y modelos compatibles con el protocolo Language Model.

### Regla importante

No usar tecnología nueva por moda.

Usarla solo si mejora:

- facilidad de uso
- automatización
- seguridad
- velocidad
- accesibilidad
- contexto inteligente
- reducción de fricción
- escalabilidad
- calidad del código
- mantenibilidad

## AI en Ruul

Ruul debe integrar AI desde la fundación, pero de forma responsable, privada, explicable y útil.

AI debe ayudar a:

- sugerir reglas para un grupo
- resumir historial
- explicar quién debe qué
- detectar conflictos
- sugerir settlements
- recomendar acciones
- convertir lenguaje natural en acciones
- crear eventos desde texto
- crear recursos desde texto
- crear decisiones desde texto
- encontrar información dentro del grupo
- detectar tareas pendientes
- sugerir próximos pasos
- explicar permisos
- generar reportes del grupo
- automatizar procesos repetitivos

Ejemplos:

- "Crea una cena cada jueves y rota el host."
- "Divide esta cuenta entre los que fueron."
- "¿Quién falta de pagar?"
- "Vende este recurso y reparte el dinero según ownership."
- "Haz check-in automático cuando llegue al lugar."
- "Resume lo que decidimos en el viaje."
- "Qué reglas aplican si alguien llega tarde."
- "Sugiere cómo liquidar todo el grupo."
- "Convierte esta conversación en reglas."
- "Crea un fondo para el viaje y pide aportaciones."

**AI no debe ejecutar acciones críticas sin confirmación.**

AI puede sugerir, preparar, explicar y automatizar pasos de baja sensibilidad, pero acciones como pagos, transferencias, ventas de recursos, cambios de ownership, expulsiones, sanciones o cambios de reglas deben requerir confirmación, permisos y gobernanza cuando aplique.

## Automatización

Ruul debe automatizar procesos manuales innecesarios:

- check-in por ubicación del iPhone
- RSVP inteligente
- recordatorios de pago
- recordatorios de evento
- rotación automática de host
- sugerencia de lugar usado previamente
- creación de próximo evento recurrente
- aplicación de reglas simples
- multas automáticas cuando sean aceptadas por el grupo
- settlements automáticos
- clasificación automática de recursos
- acciones sugeridas según contexto
- resumen automático de actividad
- alertas cuando algo requiere decisión
- notificaciones cuando alguien debe actuar

Automatizar no significa quitar control.

Toda automatización debe ser:

- visible
- configurable
- reversible cuando aplique
- auditada
- gobernada por permisos
- fácil de apagar
- explicable para el usuario

## Escalabilidad

Ruul debe diseñarse desde la fundación para escalar en producto, datos y arquitectura.

Debe soportar:

- grupos pequeños de amigos
- familias
- roomies
- viajes
- cenas recurrentes
- comunidades
- cooperativas
- organizaciones
- fondos colectivos
- propiedades compartidas
- recursos físicos y digitales
- gobernanza avanzada
- reputación
- automatizaciones
- AI
- múltiples contextos
- actores colectivos
- relaciones entre grupos
- marketplace futuro de recursos
- venta, renta, reserva o transferencia de recursos
- integraciones externas

El modelo debe ser genérico, pero la UX debe ser simple.

### Backend escalable

El backend debe mantenerse como fuente de verdad.

Debe tener:

- PostgreSQL/Supabase bien normalizado
- RLS real
- RPCs canónicos
- SECURITY DEFINER bien protegido
- catálogos declarativos
- permisos claros
- idempotencia
- audit trail
- activity events
- migraciones defensivas
- smoke tests
- compat layers cuando haga falta
- `available_actions[]` para que iOS no invente permisos
- separación clara entre core primitives y resource envelopes
- no duplicación de primitivas
- soporte para eventos, dinero, reglas, decisiones, recursos y gobernanza como sistemas conectados

### Frontend escalable

El frontend iOS debe tener arquitectura limpia:

- SwiftUI moderno
- componentes reutilizables
- view models claros
- estado predecible
- networking centralizado
- manejo consistente de errores
- loading states consistentes
- empty states útiles
- navegación robusta
- permisos guiados por backend
- diseño accesible
- soporte para búsqueda
- soporte para AI actions
- soporte para App Intents
- soporte para notificaciones
- soporte para ubicación cuando el usuario lo permita
- testing con Swift Testing
- performance validada con Instruments

El frontend no debe contener reglas críticas de negocio. Puede anticipar UX, pero el backend decide.

## Actores y contextos

Ruul debe modelar actores de forma robusta.

Un actor puede ser:

- persona
- grupo
- espacio
- comunidad
- familia
- organización
- fondo
- recurso con agencia limitada
- entidad colectiva
- rol operativo

Los actores interactúan dentro de contextos.

Un contexto puede ser:

- grupo de amigos
- viaje
- cena recurrente
- casa compartida
- comunidad
- proyecto
- fondo
- evento
- propiedad compartida
- espacio social
- organización

La arquitectura debe permitir relaciones entre actores, recursos y contextos sin rehacer el sistema.

## Capacidades futuras

Ruul debe estar preparado para:

- vender recurso con un click
- rentar recurso
- reservar recurso
- transferir ownership
- crear marketplace interno
- generar contratos o acuerdos
- conectar pagos
- conectar Wallet
- usar ubicación para check-in
- usar AI para acciones contextuales
- usar búsqueda semántica
- usar reputación
- usar scoring social
- usar reglas ejecutables
- usar gobernanza avanzada
- usar automatizaciones
- usar integraciones externas
- crear reportes
- crear memoria social consultable

**PERO: no construir todo de golpe.**

Diseñar la fundación para soportarlo sin romper después.

## Prioridad de implementación

Primero:

1. Primitivas sólidas.
2. Modelo de actores/contextos/recursos claro.
3. Permisos y RLS.
4. Resources/event/money/rules/decisions conectados.
5. iOS simple y estable.
6. Activity/audit.
7. Idempotencia.
8. Smokes.
9. UX clara.
10. Automatizaciones básicas.

Después:

1. AI assistive.
2. App Intents.
3. Check-in por ubicación.
4. Rule engine más robusto.
5. Venta/renta/transferencia avanzada de recursos.
6. Marketplace.
7. Reputación.
8. Integraciones.
9. Reportes inteligentes.
10. Ecosistema social completo.

## Criterio final

Ruul debe sentirse simple como usar WhatsApp o Splitwise para un usuario normal, pero internamente debe tener la robustez de una plataforma social, financiera y de gobernanza.

La experiencia debe ser:

- fácil
- rápida
- confiable
- inteligente
- automatizada
- transparente
- segura
- escalable
- socialmente útil

La arquitectura debe permitir que Ruul crezca de una app de grupos a un ecosistema social completo.
