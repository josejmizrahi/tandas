import { assertEquals } from "jsr:@std/assert@1";
import {
  isSystemEventType,
  systemEventTypeValues,
} from "../_shared/types/systemEventType.ts";
import {
  conditionTypeValues,
  isConditionType,
} from "../_shared/types/conditionType.ts";
import {
  consequenceTypeValues,
  isConsequenceType,
} from "../_shared/types/consequenceType.ts";
import {
  isResourceType,
  resourceTypeValues,
} from "../_shared/types/resourceType.ts";
import {
  isPermissionLevel,
  permissionLevelValues,
} from "../_shared/types/permissionLevel.ts";

Deno.test("generated TS catalogs are non-empty and well-formed", () => {
  for (
    const [name, values] of [
      ["SystemEventType", systemEventTypeValues],
      ["ConditionType", conditionTypeValues],
      ["ConsequenceType", consequenceTypeValues],
      ["ResourceType", resourceTypeValues],
      ["PermissionLevel", permissionLevelValues],
    ] as const
  ) {
    if ((values.length as number) === 0) {
      throw new Error(`${name} catalog is empty`);
    }
    for (const v of values) {
      if (typeof v !== "string" || v.length === 0) {
        throw new Error(`${name} contains non-string or empty entry: ${v}`);
      }
      if (!/^[a-z][A-Za-z0-9]*$/.test(v)) {
        throw new Error(`${name} entry violates camelCase shape: ${v}`);
      }
    }
  }
});

Deno.test("type guards accept known values, reject unknown", () => {
  assertEquals(isSystemEventType("eventClosed"), true);
  assertEquals(isSystemEventType("madeUp"), false);

  assertEquals(isConditionType("alwaysTrue"), true);
  assertEquals(isConditionType("madeUp"), false);

  assertEquals(isConsequenceType("fine"), true);
  assertEquals(isConsequenceType("madeUp"), false);

  assertEquals(isResourceType(resourceTypeValues[0]), true);
  assertEquals(isResourceType("madeUp"), false);

  assertEquals(isPermissionLevel("founder"), true);
  assertEquals(isPermissionLevel("madeUp"), false);
});
