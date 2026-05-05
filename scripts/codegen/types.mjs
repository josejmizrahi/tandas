#!/usr/bin/env node
// Generates Swift enum files + a TS string-union file from the platform
// type catalog. Run via `node scripts/codegen/types.mjs` (Node 18+).
//
// Source of truth: platform/types/catalog.json
// Outputs:
//   - One Swift file per enum at the path declared in `swiftFile`.
//   - A single TS file at supabase/functions/_shared/platformEnums.generated.ts.
//
// CI runs this and fails the build if `git diff` is non-empty after.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "..", "..");
const catalogPath = resolve(repoRoot, "platform/types/catalog.json");
const tsOutputPath = resolve(
  repoRoot,
  "supabase/functions/_shared/platformEnums.generated.ts",
);

const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
const headerLine = catalog.generatedHeader;

function docLines(text) {
  if (!text) return [];
  return text.split("\n").map((l) => (l ? `/// ${l}` : "///"));
}

function plainCommentLines(text) {
  if (!text) return [];
  return text.split("\n").map((l) => (l ? `// ${l}` : "//"));
}

function indent(lines, spaces) {
  const pad = " ".repeat(spaces);
  return lines.map((l) => (l ? pad + l : l));
}

function renderSwiftEnum(name, def) {
  const protocols = def.swiftProtocols.join(", ");
  const access = def.swiftAccessLevel ?? "public";
  const useImplicit = def.swiftRawValuesImplicit === true;
  const out = [];

  out.push("import Foundation");
  out.push("");
  out.push(`// ${headerLine}`);
  out.push("");

  if (def.doc) {
    out.push(...docLines(def.doc));
  }
  out.push(`${access} enum ${name}: ${protocols} {`);

  // Pad raw values for alignment when explicit raws are used.
  const maxNameLen = useImplicit
    ? 0
    : Math.max(...def.values.map((v) => v.name.length));
  // Pad case names so trailing comments line up when implicit raws are used.
  const maxImplicitNameLen = useImplicit
    ? Math.max(
        ...def.values
          .filter((v) => v.trailingComment)
          .map((v) => v.name.length),
        0,
      )
    : 0;

  let prevCategory = null;
  let firstValue = true;
  const body = [];

  for (const v of def.values) {
    const categoryChanged = v.category && v.category !== prevCategory;
    // Blank separator only before category MARK or preceding multi-line comment.
    const needsSeparator =
      !firstValue && (categoryChanged || v.precedingComment);

    if (needsSeparator) body.push("");

    if (categoryChanged) {
      body.push(`// MARK: - ${v.category}`);
      body.push("");
      prevCategory = v.category;
    }

    if (v.precedingComment) {
      body.push(...plainCommentLines(v.precedingComment));
    }

    if (v.doc) {
      body.push(...docLines(v.doc));
    }

    let caseLine;
    if (useImplicit) {
      const pad = v.trailingComment
        ? " ".repeat(Math.max(2, maxImplicitNameLen - v.name.length + 2))
        : "";
      caseLine = `case ${v.name}${pad}`;
    } else {
      const pad = " ".repeat(Math.max(1, maxNameLen - v.name.length + 1));
      const raw = v.rawValue ?? v.name;
      caseLine = `case ${v.name}${pad}= "${raw}"`;
    }
    if (v.trailingComment) {
      caseLine += `// ${v.trailingComment}`;
    }
    body.push(caseLine);

    firstValue = false;
  }

  // Blank line after enum opener only when first body element is a category
  // MARK — matches the project's existing Swift style.
  if (body.length > 0) {
    const firstStartsWithMark = body[0].startsWith("// MARK: ");
    if (firstStartsWithMark) out.push("");
    out.push(...indent(body, 4));
  }

  if (def.emitIsImplementedInV1) {
    const yes = def.values
      .filter((v) => v.implementedV1 === true)
      .map((v) => `.${v.name}`);
    const no = def.values
      .filter((v) => v.implementedV1 !== true)
      .map((v) => `.${v.name}`);

    out.push("");
    const body = [];
    body.push("/// True if Sprint 1a / V1 has an evaluator implementation.");
    body.push("public var isImplementedInV1: Bool {");
    body.push("    switch self {");
    if (yes.length > 0) {
      body.push(...wrapCases(yes, "    "));
      body.push("        return true");
    }
    if (no.length > 0) {
      body.push(...wrapCases(no, "    "));
      body.push("        return false");
    }
    body.push("    }");
    body.push("}");
    out.push(...indent(body, 4));
  }

  out.push("}");
  out.push("");
  return out.join("\n");
}

// Wrap a list of `.caseName` into multi-line `case .a, .b, .c,` blocks.
function wrapCases(cases, indentInside) {
  if (cases.length === 0) return [];
  const max = 80;
  const lines = [];
  let current = `${indentInside}case `;
  for (let i = 0; i < cases.length; i++) {
    const isLast = i === cases.length - 1;
    const piece = isLast ? cases[i] + ":" : cases[i] + ", ";
    if (
      current.length + piece.length > max &&
      current !== `${indentInside}case `
    ) {
      lines.push(current.trimEnd());
      current = `${indentInside}     `;
    }
    current += piece;
  }
  lines.push(current);
  return lines;
}

function renderTsFile() {
  const out = [];
  out.push(`// ${headerLine}`);
  out.push("");
  out.push(
    "// String unions and runtime arrays for every platform enum. The rule",
  );
  out.push(
    "// engine and edge functions import from here. Decoders that encounter",
  );
  out.push(
    "// a value not present in the matching `_ALL` array log a warning and",
  );
  out.push("// skip the row instead of crashing.");
  out.push("");

  for (const [name, def] of Object.entries(catalog.enums)) {
    if (def.doc) {
      out.push(...plainCommentLines(def.doc));
    }
    const literals = def.values
      .map((v) => `"${v.rawValue ?? v.name}"`)
      .join("\n  | ");
    out.push(`export type ${name} =`);
    out.push(`  | ${literals};`);
    out.push("");

    out.push(`export const ${name}_ALL = [`);
    for (const v of def.values) {
      out.push(`  "${v.rawValue ?? v.name}",`);
    }
    out.push(`] as const satisfies readonly ${name}[];`);
    out.push("");

    out.push(
      `export function is${name}(value: unknown): value is ${name} {`,
    );
    out.push(
      `  return typeof value === "string" && (${name}_ALL as readonly string[]).includes(value);`,
    );
    out.push("}");
    out.push("");
  }

  return out.join("\n");
}

function ensureDir(filePath) {
  mkdirSync(dirname(filePath), { recursive: true });
}

let wrote = 0;

for (const [name, def] of Object.entries(catalog.enums)) {
  const outPath = resolve(repoRoot, def.swiftFile);
  ensureDir(outPath);
  const source = renderSwiftEnum(name, def);
  writeFileSync(outPath, source, "utf8");
  console.log(`  wrote ${relative(repoRoot, outPath)}`);
  wrote++;
}

ensureDir(tsOutputPath);
writeFileSync(tsOutputPath, renderTsFile(), "utf8");
console.log(`  wrote ${relative(repoRoot, tsOutputPath)}`);
wrote++;

console.log(`gen-types: wrote ${wrote} files`);
