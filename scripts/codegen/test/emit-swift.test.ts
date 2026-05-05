import { assertEquals } from "jsr:@std/assert@1";
import { emitSwift } from "../emit-swift.ts";

const FIXTURES = new URL("./fixtures/", import.meta.url);

Deno.test("emit-swift: produces expected output for SampleType", async () => {
  const expected = await Deno.readTextFile(
    new URL("expected-output.swift", FIXTURES).pathname,
  );
  const actual = emitSwift({
    typeName: "SampleType",
    cases: ["alpha", "beta", "gammaRay"],
    sourceRelative: "scripts/codegen/test/fixtures/sample-input.swift",
  });
  assertEquals(actual, expected);
});
