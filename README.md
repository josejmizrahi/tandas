# Tandas

Versión "amigos" de Federa: una app simple para administrar **tandas rotativas**, **reglas del grupo**, **multas** y **gastos compartidos** (estilo Splitwise) entre un grupo pequeño de amigos.

## Stack

- React 19 + Vite 7 + TypeScript
- Supabase (auth + Postgres con RLS)
- Tailwind CSS v4 + shadcn/ui
- TanStack Query
- React Router 7

## Arranque local

```bash
cp .env.example .env       # llenar credenciales de Supabase
npm install
npm run dev
```

## Funcionalidades

1. **Grupos** — crea un grupo con código de invitación, monto, frecuencia y moneda.
2. **Miembros** — únete con código, asigna orden de turno, roles admin/miembro.
3. **Reglas** — define las reglas del grupo (ej. "no llegar tarde") con multa opcional.
4. **Tandas (eventos)** — programa rondas con un anfitrión rotativo.
5. **Multas** — aplica multas por reglas; cada miembro las marca como pagadas.
6. **Splitwise** — registra gastos y divide entre miembros (igual / exacto / porcentaje); calcula balances netos.

## Esquema

Migraciones SQL en `supabase/migrations/`. Aplicarlas con `psql` contra el proyecto de Supabase, o con la CLI.
