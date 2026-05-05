import { assertEquals } from "jsr:@std/assert@1";
import { emitTs } from "../emit-ts.ts";

const FIXTURES = new URL("./fixtures/", import.meta.url);

Deno.test("emit-ts: produces expected output for SampleType", async () => {
  const expected = await Deno.readTextFile(
    new URL("expected-output.ts", FIXTURES).pathname,
  );
  const actual = emitTs({
    typeName: "SampleType",
    cases: ["alpha", "beta", "gammaRay"],
    sourceRelative: "scripts/codegen/test/fixtures/sample-input.swift",
  });
  assertEquals(actual, expected);
});
