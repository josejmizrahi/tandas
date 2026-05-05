import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { parseEnumFile } from "../parser.ts";

const FIXTURES = new URL("./fixtures/", import.meta.url);

Deno.test("parser: extracts enum name and case names from sample-input.swift", async () => {
  const result = await parseEnumFile(new URL("sample-input.swift", FIXTURES).pathname);
  assertEquals(result, {
    typeName: "SampleType",
    cases: ["alpha", "beta", "gammaRay"],
    sourceRelative: "scripts/codegen/test/fixtures/sample-input.swift",
  });
});

Deno.test("parser: rejects file without @codegen:enum marker", async () => {
  const tmp = await Deno.makeTempFile({ suffix: ".swift" });
  await Deno.writeTextFile(tmp, "public enum X { case a; case unknown(String) }\n");
  await assertRejects(
    () => parseEnumFile(tmp),
    Error,
    "missing // @codegen:enum marker",
  );
});

Deno.test("parser: rejects associated values other than trailing unknown(String)", async () => {
  await assertRejects(
    () => parseEnumFile(new URL("divergent-input.swift", FIXTURES).pathname),
    Error,
    "associated value",
  );
});

Deno.test("parser: rejects file missing trailing case unknown(String)", async () => {
  const tmp = await Deno.makeTempFile({ suffix: ".swift" });
  await Deno.writeTextFile(
    tmp,
    "// @codegen:enum\npublic enum X: Codable {\n  case a\n}\n",
  );
  await assertRejects(
    () => parseEnumFile(tmp),
    Error,
    "missing 'case unknown(String)'",
  );
});
