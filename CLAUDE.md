@AGENTS.md

# Claude-specific overlay

The full project context lives in `AGENTS.md` (imported above). This file
is reserved for Claude-only tweaks — defer to `AGENTS.md` for everything
project-wide so Cursor / Aider / other agents stay in sync.

## Trabajo con MCP Supabase

- `mcp__supabase__list_tables` antes de proponer cambios de schema.
- `mcp__supabase__get_advisors` antes de cualquier migración no trivial
  (chequea security + performance advisors).
- `mcp__supabase__apply_migration` con SQL revisado, jamás autogenerado
  sin pasada manual.
- Naming: `NNNNN_descripcion_corta.sql` con `N` monotónico. Si dos PRs
  paralelos quedan con el mismo número, renombrar antes de mergear.
