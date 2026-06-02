// Structured logging helper for edge functions.
//
// Single concern: emit one JSON object per log line so production logs are
// queryable. Tests swap the sink via `_setLogSink` to capture entries
// without touching stdout.
//
// Schema convention:
//   - `level`: "error" | "warn" | "info"
//   - `code`:  dot-separated namespace, e.g. `rule_engine.condition_not_implemented`
//   - `message`: human-readable, never the source of truth (parse `code` + fields)
//   - any other top-level fields are domain context
//
// `phase_target` is the conventional field that distinguishes
// "this is a real bug" from "this feature is reserved for Fase X". When a
// future dev sees `phase_target: "phase_2"` they know the failure mode is
// expected until the shared-resource template ships.

export interface StructuredEntry {
  level: "error" | "warn" | "info";
  code: string;
  message: string;
  [key: string]: unknown;
}

let _sink: (entry: StructuredEntry) => void = defaultSink;

function defaultSink(entry: StructuredEntry): void {
  const line = JSON.stringify(entry);
  if (entry.level === "error") {
    console.error(line);
  } else if (entry.level === "warn") {
    console.warn(line);
  } else {
    console.log(line);
  }
}

export function logStructured(entry: StructuredEntry): void {
  _sink(entry);
}

/** Test-only: install a sink that captures entries instead of writing them. */
export function _setLogSink(fn: (entry: StructuredEntry) => void): void {
  _sink = fn;
}

/** Test-only: restore the default console-writing sink. */
export function _resetLogSink(): void {
  _sink = defaultSink;
}
