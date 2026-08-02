// Hand-written type assertions against the generated schema.
//
// A golden file proves the emitter's output didn't *change*. This proves it's
// actually *correct* — that the types constrain what they claim to. Every
// `@ts-expect-error` below fails compilation if the line stops erroring, so
// these assert in both directions: the good lines must typecheck, the bad ones
// must not.

import type { Matrix, Nested, Ping, Procedures, NotFound } from "./schema"
import { WIRE_FIELDS, PROC_TYPES, ERROR_TYPES } from "./schema"

// --- scalars round-trip to the right TS primitives ---------------------------

const nested: Nested = { label: "n" }

const matrix: Matrix = {
  str: "s",
  int: 1,
  flt: 1.5,
  flag: true,
  at: "2026-01-02T03:04:05Z", // timestamp is a string, not Date
  on: "2026-01-02", // so is date
  money: "1.25", // and decimal — JSON numbers are doubles
  maybe: null,
  list: ["a"],
  refs: [nested],
  lookup: { "👍": 2 },
  nested,
  colour: "red",
  tree: { label: "root", children: [] },
  twoWords: "yes",
  // withDefault omitted — it has a default, so it must be optional
}

// @ts-expect-error int is a number, not a string
const wrongScalar: Matrix = { ...matrix, int: "1" }

// @ts-expect-error T::Boolean must emit `boolean`, never `true | false` widened to string
const wrongBool: Matrix = { ...matrix, flag: "true" }

// @ts-expect-error the enum is a literal union, so an unlisted value is invalid
const wrongEnum: Matrix = { ...matrix, colour: "green" }

// @ts-expect-error required fields stay required
const missingRequired: Matrix = { ...matrix, str: undefined }

// --- nilable vs optional -----------------------------------------------------

const explicitNull: Matrix = { ...matrix, maybe: null } // T.nilable accepts null
const omittedDefault: Matrix = { ...matrix } // `withDefault` may be absent

// --- maps keep an open key space --------------------------------------------
// The whole point of emitting `Record<string, number>` rather than an interface:
// keys are DATA. Any string must be accepted, and none may be renamed.

const anyEmoji: number | undefined = matrix.lookup["🎉"]
const dynamicKey: Record<string, number> = matrix.lookup

// @ts-expect-error but the VALUE type is still enforced
const badMapValue: Matrix = { ...matrix, lookup: { "👍": "two" } }

// --- procedures --------------------------------------------------------------

type PingInput = Procedures["echo.ping"]["input"]
type PingOutput = Procedures["echo.ping"]["output"]

const pingIn: PingInput = { who: "world" } // `loud` has a default → optional
const pingOut: PingOutput = matrix // echo.ping returns Matrix

// @ts-expect-error there is no such procedure
type Missing = Procedures["echo.nope"]

// @ts-expect-error echo.ping does not return Nested
const wrongOutput: Procedures["echo.ping"]["output"] = nested

// A procedure with no declared errors types its error as `never`, so nothing
// can be assigned to it — which is what makes the client's error union honest.
declare const noError: Procedures["echo.ping"]["error"]
// @ts-expect-error `never` accepts nothing
const cannotAssign: Procedures["echo.ping"]["error"] = { code: "not_found" }

// A declared error carries its fields.
const declared: NotFound = { code: "not_found", resource: "thing", id: "1" }

// ...and reaches the procedure that declared it. Without this, dropping an
// error from the contract compiles cleanly — a gap found by deliberately
// breaking the emitter and watching this file stay green.
const boomError: Procedures["echo.boom"]["error"] = declared

// @ts-expect-error echo.boom declares only NotFound
const undeclaredError: Procedures["echo.boom"]["error"] = { code: "forbidden", action: "x", resource: "y" }

// --- generated runtime tables ------------------------------------------------

const fields: Record<string, string> = WIRE_FIELDS.Matrix
const types: { input: string; output: string } = PROC_TYPES["echo.ping"]
const errorName: string = ERROR_TYPES.not_found

// Exported so noUnusedLocals doesn't complain about the assertions above.
export { boomError,
  matrix, explicitNull, omittedDefault, anyEmoji, dynamicKey,
  pingIn, pingOut, declared, fields, types, errorName,
}
