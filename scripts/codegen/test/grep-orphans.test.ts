import { assertEquals } from "jsr:@std/assert@1";
import { findOrphans } from "../grep-orphans.ts";

Deno.test("grep-orphans: flags string literal near event_type if not in catalog", async () => {
  const tmp = await Deno.makeTempDir();
  await Deno.writeTextFile(
    `${tmp}/sample.sql`,
    "INSERT INTO system_events (event_type) VALUES ('madeUpEvent');\n",
  );
  await Deno.writeTextFile(`${tmp}/contexts.txt`, "event_type\n");
  await Deno.writeTextFile(`${tmp}/allowlist.txt`, "");

  const orphans = await findOrphans({
    catalog: new Set(["eventClosed", "voteCast"]),
    targetFiles: [`${tmp}/sample.sql`],
    contextsFile: `${tmp}/contexts.txt`,
    allowlistFile: `${tmp}/allowlist.txt`,
  });

  assertEquals(orphans, [
    {
      file: `${tmp}/sample.sql`,
      line: 1,
      identifier: "madeUpEvent",
      context: "event_type",
    },
  ]);
});

Deno.test("grep-orphans: respects allowlist", async () => {
  const tmp = await Deno.makeTempDir();
  await Deno.writeTextFile(
    `${tmp}/sample.sql`,
    "INSERT INTO system_events (event_type) VALUES ('madeUpEvent');\n",
  );
  await Deno.writeTextFile(`${tmp}/contexts.txt`, "event_type\n");
  await Deno.writeTextFile(`${tmp}/allowlist.txt`, "madeUpEvent  # placeholder\n");

  const orphans = await findOrphans({
    catalog: new Set(["eventClosed"]),
    targetFiles: [`${tmp}/sample.sql`],
    contextsFile: `${tmp}/contexts.txt`,
    allowlistFile: `${tmp}/allowlist.txt`,
  });

  assertEquals(orphans, []);
});

Deno.test("grep-orphans: ignores literals not near a context token", async () => {
  const tmp = await Deno.makeTempDir();
  await Deno.writeTextFile(
    `${tmp}/sample.sql`,
    "SELECT 'someRandomCamel' FROM unrelated;\n",
  );
  await Deno.writeTextFile(`${tmp}/contexts.txt`, "event_type\n");
  await Deno.writeTextFile(`${tmp}/allowlist.txt`, "");

  const orphans = await findOrphans({
    catalog: new Set(["eventClosed"]),
    targetFiles: [`${tmp}/sample.sql`],
    contextsFile: `${tmp}/contexts.txt`,
    allowlistFile: `${tmp}/allowlist.txt`,
  });

  assertEquals(orphans, []);
});
