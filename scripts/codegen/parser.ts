// Minimal Swift enum parser for codegen.
//
// Recognized shape:
//
//   // @codegen:enum
//   public enum <Name>: <conformances> {
//       case <name1>
//       case <name2>
//       ...
//       case unknown(String)
//   }
//
// Anything else fails with a helpful message that includes a line number
// when one is locally derivable.

import { relative } from "jsr:@std/path@1";

export interface EnumDecl {
  typeName: string;
  cases: string[];
  /** Path relative to repo root, used in generated header comments. */
  sourceRelative: string;
}

const MARKER = "// @codegen:enum";
const MARKER_WINDOW = 20; // first N lines must contain the marker
const ENUM_HEADER_RE = /^public\s+enum\s+(?<name>[A-Z][A-Za-z0-9_]*)\s*:[^{]*\{\s*$/;
const CASE_RE = /^case\s+(?<name>[a-z][A-Za-z0-9_]*)\s*$/;
const UNKNOWN_CASE_RE = /^case\s+unknown\s*\(\s*String\s*\)\s*$/;

export async function parseEnumFile(path: string): Promise<EnumDecl> {
  const text = await Deno.readTextFile(path);
  return parseEnumText(text, path);
}

export function parseEnumText(text: string, path: string): EnumDecl {
  const rawLines = text.split(/\r?\n/);

  // 1. Marker check — must appear in first 20 lines.
  const markerIdx = rawLines.slice(0, MARKER_WINDOW).findIndex((l) => l.trim() === MARKER);
  if (markerIdx < 0) {
    throw new Error(`${path}: missing // @codegen:enum marker in first ${MARKER_WINDOW} lines`);
  }

  // 2. Find `public enum X: ... {` somewhere after the marker.
  let headerLineIdx = -1;
  let typeName = "";
  for (let i = markerIdx + 1; i < rawLines.length; i++) {
    const m = rawLines[i].match(ENUM_HEADER_RE);
    if (m && m.groups) {
      headerLineIdx = i;
      typeName = m.groups.name;
      break;
    }
  }
  if (headerLineIdx < 0) {
    throw new Error(`${path}: could not find 'public enum <Name>: ... {' after marker`);
  }

  // 3. Walk body until matching closing brace at column 0.
  const cases: string[] = [];
  let sawUnknown = false;
  let bodyEnded = false;

  for (let i = headerLineIdx + 1; i < rawLines.length; i++) {
    const trimmed = rawLines[i].trim();
    if (trimmed === "}") {
      bodyEnded = true;
      break;
    }
    if (trimmed === "" || trimmed.startsWith("//") || trimmed.startsWith("///")) {
      continue;
    }

    const unknownMatch = trimmed.match(UNKNOWN_CASE_RE);
    if (unknownMatch) {
      if (sawUnknown) {
        throw new Error(
          `${path}:${i + 1}: duplicate 'case unknown(String)'`,
        );
      }
      sawUnknown = true;
      continue;
    }

    const caseMatch = trimmed.match(CASE_RE);
    if (caseMatch && caseMatch.groups) {
      if (sawUnknown) {
        throw new Error(
          `${path}:${i + 1}: 'case unknown(String)' must be the last case`,
        );
      }
      cases.push(caseMatch.groups.name);
      continue;
    }

    // Reject everything else (raw values, associated values, nested types).
    if (trimmed.includes("(") || trimmed.includes("=")) {
      throw new Error(
        `${path}:${i + 1}: unsupported associated value or raw value in '${trimmed}'`,
      );
    }
    throw new Error(`${path}:${i + 1}: unrecognized enum body line: '${trimmed}'`);
  }

  if (!bodyEnded) {
    throw new Error(`${path}: enum body did not close with '}' on its own line`);
  }
  if (cases.length === 0) {
    throw new Error(`${path}: enum has no known cases (besides unknown)`);
  }
  if (!sawUnknown) {
    throw new Error(`${path}: enum is missing 'case unknown(String)' as last case`);
  }

  // Compute repo-relative path for the generated header comment.
  const repoRoot = findRepoRoot(path);
  const sourceRelative = relative(repoRoot, path);

  return { typeName, cases, sourceRelative };
}

function findRepoRoot(fromPath: string): string {
  // Walk up until we see a .git directory (or reach /). Falls back to cwd.
  let dir = fromPath;
  for (let i = 0; i < 20; i++) {
    dir = dir.replace(/\/[^/]+\/?$/, "");
    if (!dir) break;
    try {
      const stat = Deno.statSync(`${dir}/.git`);
      if (stat.isDirectory) return dir;
    } catch (_) {
      // keep walking
    }
  }
  return Deno.cwd();
}
