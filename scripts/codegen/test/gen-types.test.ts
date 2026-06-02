import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { generate } from "../gen-types.ts";

Deno.test("gen-types: discovers marked sources, writes Swift + TS", async () => {
  const tmp = await Deno.makeTempDir();
  const swiftDir = `${tmp}/ios/Tandas/Platform/Models`;
  const swiftGen = `${swiftDir}/Generated`;
  const tsDir = `${tmp}/supabase/functions/_shared/types`;
  await Deno.mkdir(swiftDir, { recursive: true });
  await Deno.mkdir(swiftGen, { recursive: true });
  await Deno.mkdir(tsDir, { recursive: true });

  await Deno.writeTextFile(
    `${swiftDir}/SampleType.swift`,
    `import Foundation\n\n// @codegen:enum\npublic enum SampleType: Codable {\n  case alpha\n  case beta\n  case unknown(String)\n}\n`,
  );
  await Deno.writeTextFile(
    `${swiftDir}/Plain.swift`,
    `import Foundation\npublic enum Plain { case x }\n`, // no marker — must skip
  );

  const result = await generate({
    repoRoot: tmp,
    sourceDir: swiftDir,
    swiftOutDir: swiftGen,
    tsOutDir: tsDir,
    mode: "write",
  });

  assertEquals(result.processed.sort(), ["SampleType"]);
  assertEquals(result.skipped.length, 1);

  const swiftOut = await Deno.readTextFile(`${swiftGen}/SampleType+Codable.swift`);
  assertStringIncludes(swiftOut, "extension SampleType");
  assertStringIncludes(swiftOut, ".alpha,");

  const tsOut = await Deno.readTextFile(`${tsDir}/sampleType.ts`);
  assertStringIncludes(tsOut, "export const sampleTypeValues");
  assertStringIncludes(tsOut, '"alpha"');
});

Deno.test("gen-types: --check returns non-zero exit code when output is stale", async () => {
  const tmp = await Deno.makeTempDir();
  const swiftDir = `${tmp}/ios/Tandas/Platform/Models`;
  const swiftGen = `${swiftDir}/Generated`;
  const tsDir = `${tmp}/supabase/functions/_shared/types`;
  await Deno.mkdir(swiftDir, { recursive: true });
  await Deno.mkdir(swiftGen, { recursive: true });
  await Deno.mkdir(tsDir, { recursive: true });

  await Deno.writeTextFile(
    `${swiftDir}/SampleType.swift`,
    `import Foundation\n\n// @codegen:enum\npublic enum SampleType: Codable {\n  case alpha\n  case unknown(String)\n}\n`,
  );

  // No generated files exist — check should report stale.
  const result = await generate({
    repoRoot: tmp,
    sourceDir: swiftDir,
    swiftOutDir: swiftGen,
    tsOutDir: tsDir,
    mode: "check",
  });

  assertEquals(result.stale.length, 2); // missing Swift + TS
});

Deno.test("gen-types: missing source dir is a no-op, not a crash", async () => {
  const tmp = await Deno.makeTempDir();
  const swiftDir = `${tmp}/ios/Tandas/Platform/Models`; // never created
  const swiftGen = `${swiftDir}/Generated`;
  const tsDir = `${tmp}/supabase/functions/_shared/types`;

  for (const mode of ["write", "check"] as const) {
    const result = await generate({
      repoRoot: tmp,
      sourceDir: swiftDir,
      swiftOutDir: swiftGen,
      tsOutDir: tsDir,
      mode,
    });

    assertEquals(result.processed, []);
    assertEquals(result.skipped, []);
    assertEquals(result.stale, []);
  }
});
