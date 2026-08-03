# Prospect — design notes

A tRPC-shaped RPC layer for Ruby. You write Sorbet `T::Struct`s and a router;
you get runtime validation, an HTTP transport, a typed Ruby client, and a typed
TypeScript client — all derived from the same declaration.

> **On the name.** From Latin *prospectus* — "a view across a distance". A
> generated client is exactly that: a typed view onto a service you cannot
> reach directly. The related *prospectus* is a document stating precisely what
> is on offer, which is what `schema.json` is. It also happens to contain
> `r`, `p`, `c` in order.
>
> `prospect` is unclaimed on RubyGems (verified). The npm package ships scoped
> as `@yourorg/prospect-client`, so the bare npm name being taken is irrelevant.

## 1. The premise, and where tRPC's trick doesn't transfer

tRPC's core move is that the client imports a *type*, not a module:

```ts
import type { AppRouter } from '../server'
```

TypeScript's structural inference carries the whole router shape across the
boundary with zero runtime coupling and zero codegen. Ruby has no equivalent —
no type-level computation, no inference from runtime values into a static
checker. **So codegen is unavoidable.** That is the single most important fact
about this project's design, and fighting it produces something worse than
embracing it.

What we keep from tRPC is the *ergonomics*, not the mechanism:

- The IDL is ordinary Ruby. No `.proto`, no `.yaml`, no hand-written OpenAPI.
- Procedures are functions with typed input and output, not REST resources
  contorted into verbs.
- The client call site reads like a method call, and your type checker knows the
  argument and return types.
- Adding a procedure is one place, not five.

What we inherit from Twirp/Connect/gRPC is honest codegen with a schema
document in the middle. The pitch is "gRPC's rigour without leaving Ruby, tRPC's
feel without needing TypeScript on both ends."

## 2. Pipeline

Pluggable on *both* sides, with the IR in the middle:

```
  Sorbet T::Struct   │   schema DSL   │   RBS parse      ◄── frontends
   (v0)              │   (later)      │   (later)
        └────────────┴───────┬────────┴────────┘
                             │   Frontend interface: #types, #procedures
                             ▼
                  Schema IR  (schema.json)                ◄── the actual product
                             │
     ┌───────┬───────────────┼───────────┬─────────────┐
     ▼       ▼               ▼           ▼             ▼
   Ruby     TS            OpenAPI       RBS         (yours)     ◄── emitters
  client  client           spec        sigs
```

Everything hangs off the IR. Emitters never touch Sorbet internals, never load
your application, and can be written in any language because the IR is a JSON
document on disk. That is what makes "pluggable emitters" real rather than
aspirational — the plugin boundary is a file format, not a Ruby API.

### Frontends

The same seam belongs on the input side. A frontend's only job is to produce IR;
`T::Struct` reflection is simply the first implementation. Two others are
plausible later: a plain-Ruby schema DSL for shops that won't adopt Sorbet, and
a parser that reads `.rbs` directly.

This matters because requiring `sorbet-runtime` is a genuine adoption tax, and
it's the reason projects like [T-Ruby](https://type-ruby.github.io/) exist at
all — a compile-to-`.rb`+`.rbs` language whose headline feature is having no
runtime dependency. We can't use such a tool as a frontend (see below), but the
demand it represents is real, and the frontend seam is what keeps our bet on
Sorbet from being permanent. It is nearly free to preserve now and expensive to
retrofit once emitters have grown Sorbet-shaped assumptions.

**Design rule that falls out of this: the IR must be sufficient to construct a
validator.** If runtime validation can be synthesized from the IR, frontends are
purely compile-time and a non-reflective frontend becomes possible. If instead
validation stays coupled to `T::Struct.from_hash`, every frontend must ship its
own validator and the seam is decorative. v0 can lean on Sorbet's constructor
for validation, but the IR should carry enough — constraints, formats,
nullability, defaults — that it never *has* to.

### Why type-erasing tools can't be frontends

Worth recording, since it's the first question anyone asks. T-Ruby and similar
compile-time-only checkers erase types before the program runs; there is no
runtime API left to introspect and no validation to reuse. Using one would mean
hand-writing the entire validator layer *and* parsing the generated `.rbs` to
recover shapes that were already declared — the RBS-as-source path, with an
extra compile step in front. Sorbet is close to unique in Ruby in having a
runtime that knows about declared types, and that single property, not its
checker or its ecosystem, is why it wins the v0 frontend slot.

## 3. Authoring

```ruby
class User < T::Struct
  const :id,         String
  const :email,      String
  const :created_at, Time
  const :posts,      T::Array[Post], default: []
end

class GetUserInput < T::Struct
  const :id,            String
  const :include_posts, T::Boolean, default: false
end

class UsersRouter < Prospect::Router
  path :users
  context AppContext

  query :get, input: GetUserInput, output: User, errors: [NotFound] do |input, ctx|
    user = ctx.db.users.find(input.id)
    raise NotFound.new(resource: "user", id: input.id) unless user
    User.new(id: user.id, email: user.email, created_at: user.created_at)
  end

  mutation :create, input: CreateUserInput, output: User do |input, ctx|
    # ...
  end
end

class AppRouter < Prospect::Router
  mount UsersRouter
  mount PostsRouter
end
```

`query` vs `mutation` is not decoration — it drives HTTP method selection, cache
semantics, batching eligibility, and whether the generated TS client exposes a
procedure via a query hook or a mutation hook.

**Correction — input validation is *not* free.** An earlier draft of this
section claimed `T::Struct.from_hash` type-checks on construction. It does not.
Verified while porting bookface:

```ruby
CreatePostInput.from_hash({ "body" => 42 })  # => accepted, body is Integer 42
CreatePostInput.new(body: 42)                # => TypeError
```

Only `.new` checks. `from_hash` is deserialization, not validation, and an
unvalidated input reaching a handler is how a wrong type becomes a 500 instead
of a 400.

So the dispatcher walks the declared props and checks each value against its
type object (`Prospect::Dispatcher#validate!`), producing per-field errors:

```json
{ "code": "invalid_input", "errors": { "body": "expected T.nilable(String), got Integer" } }
```

This matters beyond the bug. "Sorbet gives us runtime validation for free" was
one of the arguments for choosing it as the v0 frontend (§2). The honest version
is narrower: Sorbet gives us *declared types reflectable at runtime*, and we
build the validator from them. That is still a real advantage over a
type-erasing tool — but it's the reflection that's load-bearing, not the
validation, and it makes §2's rule that **the IR must be sufficient to construct
a validator** a working requirement rather than an aspiration. The same walk
serves both.

## 4. The IR

Deliberately narrower than Sorbet's type system. Every construct must map
cleanly to JSON *and* to TypeScript *and* to RBS — anything that doesn't is
rejected at boot (see strict mode, §8).

```json
{
  "prospect_schema": "0.1",
  "schema_hash": "sha256:1f3a…",
  "types": {
    "User": {
      "kind": "struct",
      "fields": [
        { "name": "id",         "type": { "kind": "scalar", "name": "string" } },
        { "name": "created_at", "type": { "kind": "scalar", "name": "timestamp" } },
        { "name": "posts",
          "type": { "kind": "list", "of": { "kind": "ref", "name": "Post" } },
          "default": [] }
      ]
    },
    "Role": { "kind": "enum", "values": ["admin", "member", "guest"] }
  },
  "procedures": [
    { "path": "users.get",
      "kind": "query",
      "input":  { "kind": "ref", "name": "GetUserInput" },
      "output": { "kind": "ref", "name": "User" },
      "errors": ["NotFound"] }
  ]
}
```

Type nodes: `scalar` | `ref` | `list` | `map` | `optional` | `union` | `enum`.
Scalars: `string`, `int`, `float`, `bool`, `timestamp`, `decimal`, `uuid`,
`bytes`, `void`.

`schema_hash` is cheap and worth a lot. Generated clients embed it and send it
as a header; the server can warn or reject on mismatch. Codegen's central risk
is silent drift between a stale generated client and a live server, and this
closes it for the price of a digest.

## 5. Transports

**HTTP/JSON, Rack-mountable.** `POST /rpc/users.create` with the input as the
body; `GET /rpc/users.get?input=<urlencoded json>` for queries, so they stay
cacheable and CDN-friendly. Batching via `POST /rpc?batch=1` with an array,
mirroring tRPC's link batching.

**In-process.** `AppRouter.caller(ctx).users.get(id: "1")` — same validation and
same middleware chain, but no serialization and no socket. This is tRPC's
`createCaller`, and in a Ruby monolith it is arguably the more valuable of the
two transports: it gives you a typed, contract-checked seam between modules that
you can later promote to a network boundary without touching call sites.

## 6. Deployment: Lambda via Ruby CDK

Target is AWS Lambda through the Ruby CDK bindings in `../aws-cdk` —
jsii-generated over real `aws-cdk-lib`, `AWSCDK::` namespace, snake_case props,
driven by `cdk.json` → `bundle exec ruby cdk.rb`.

API names below are taken from the published docs, but those docs are being
actively reworked (jsii-rosetta still leaks TypeScript into translated examples
— `path.join(__dirname, …)` in supposedly-Ruby snippets). **The installed gem is
the source of truth, not the rendered docs.** Names used here worth
re-verifying before implementation: `AWSCDK::APIGatewayv2::HttpAPI` (lowercase
`v` in the module, uppercase `API` in the class), `HttpMethod::ANY`,
`AWSCDK::APIGatewayv2Integrations::HttpLambdaIntegration.new(id, fn)` — which
takes no scope argument, unlike most constructs.

### Don't emit infrastructure — ship a construct

This is the payoff from choosing Ruby CDK over Terraform or SAM, and it removes
a whole subsystem. A text emitter would serialize the IR to disk for a separate
toolchain to read back. But the CDK app *is Ruby*, so it can `require` the router
and read the IR **in memory, at synth time**. No codegen step, no generated
infrastructure files to review, vendor, or drift.

```ruby
class ApiStack < AWSCDK::Stack
  def initialize(scope, id, props = nil)
    super
    Prospect::CDK::Service.new(self, "Api", {
      router:       AppRouter,
      granularity:  :per_router,          # :per_procedure | :per_router | :single
      architecture: AWSCDK::Lambda::Architecture.X86_64,   # dot, not :: — and see build timings
      runtime:      AWSCDK::Lambda::Runtime.RUBY_4_0,
      defaults:     { memory_size: 1024, timeout: AWSCDK::Duration.seconds(10) }
    })
  end
end
```

Infrastructure is therefore *not* a fifth emitter — it's an in-process consumer
of the IR. The emitter list in §2 is unchanged.

**Dependency risk, stated plainly:** the CDK gems are `0.0.0.pre` on a private
gem server, and the jsii Ruby target is under active development by the same
person building this. That's good for both projects, but two unstable things are
being built against each other and a bad jsii release blocks deploys. Pin exact
versions, keep the construct's API surface small, and treat `Prospect::CDK` as the
single place that knows CDK class names so a rename is one file.

### Granularity must be invisible to the client

Everything sits behind one `HttpAPI` front door, routed by procedure path. The
critical property: **clients cannot tell which granularity was chosen.** Moving
`users` to its own function, or collapsing everything into one, regenerates no
client.

That imposes a concrete constraint on path design. Procedure IDs are dotted
(`users.create`), but the *URL* must be slash-separated — `POST /rpc/users/create`
— because API Gateway greedy params can't split on a dot. With slashes, the
gateway can route on the unit prefix:

| Granularity      | Routes                                            |
| ---------------- | ------------------------------------------------- |
| `:single`        | `/rpc/{proxy+}` → one function                    |
| `:per_router`    | `/rpc/users/{proxy+}` → users function            |
| `:per_procedure` | `/rpc/users/create` → dedicated function          |

```ruby
http_api.add_routes({
  path:        "/rpc/users/{proxy+}",
  methods:     [AWSCDK::APIGatewayv2::HttpMethod::ANY],
  integration: AWSCDK::APIGatewayv2Integrations::HttpLambdaIntegration.new("UsersInt", users_fn)
})
```

Had each unit gotten its own Function URL instead, granularity would leak into
every client and freeze after first release. One front door, path routing,
granularity as a pure deployment concern.

Deployment config lives next to the procedure — the "chunks of Ruby → services"
ergonomic:

```ruby
class ReportsRouter < Prospect::Router
  path :reports
  deploy memory_size: 1024, timeout: 30

  mutation :export, input: ExportInput, output: ExportJob,
           deploy: { memory_size: 3008, timeout: 900, granularity: :dedicated }
end
```

### Packaging and dependency slicing

Explicit units with automatic slicing is where essentially all remaining risk
sits. Ruby's require graph is dynamic — autoload, conditional requires,
metaprogramming, interpolated paths — so a sound static closure is not
computable. Sequencing that delivers value before betting on the hard part:

1. **Gem-level slicing, declared (v0).** Gems dominate Ruby cold start; one
   `require "aws-sdk-s3"` dwarfs an app's own files. Routers declare Bundler
   groups, each unit bundles only its groups. Mechanical, sound, no analysis —
   and it captures most of the available win.
2. **Dynamic tracing (v1).** Boot a unit, exercise it, record `$LOADED_FEATURES`.
   Far more accurate for Ruby than AST parsing, because it observes what
   actually loads rather than what appears to.
3. **Static scan as safety net.** Prism-parsed requires to catch branches tracing
   never exercised. Union with the trace, never intersect.
4. **Verification, always.** Boot every built bundle in a Lambda-like container
   and fail the build on a missing constant. Unsound slicing caught at build
   time is an inconvenience; caught at invoke time it's an outage.

`force_include` is mandatory, not a nicety — the tracer will eventually be
wrong, and users need an override that doesn't require understanding it.

#### `eval_gemfile` in the unit, not a root Gemfile

Bundler has no workspace protocol — no `workspace:*`, no root manifest, no
lockfile shared across members. But `eval_gemfile` composes Gemfiles, and the
right direction is **each unit evaluating a shared common file**, selected via
`BUNDLE_GEMFILE`:

```ruby
# units/users.gemfile
eval_gemfile File.expand_path("../common.gemfile", __dir__)
gem "tilt"
```

```sh
BUNDLE_GEMFILE=units/users.gemfile bundle install
```

This beats a root Gemfile with optional groups on four counts:

- **The boundary is hard, not soft.** A unit's dependency set physically
  excludes what it didn't declare. Groups only *filter* a shared set, so nothing
  stops unit code requiring a gem it never declared.
- **The lockfile is the gem set.** `units/users.gemfile.lock` lists exactly what
  that unit needs, so the dedupe-by-gem-set optimisation above is a direct
  lockfile comparison. With groups you would have to infer a group's transitive
  closure, which Bundler's lockfile does not record — the opposite of what an
  earlier draft of this section claimed.
- **It matches deployed reality.** The Lambda runs with `BUNDLE_GEMFILE` set to
  its own unit; dev and CI use the identical mechanism.
- **No ceremony.** No `optional: true`, no `bundle config set with` juggling per
  build.

Verified in `spike/child-eval`:

- Each unit produces its own lockfile containing exactly its gems.
- **Bundler enforces uniformity for anything in `common.gemfile`.** Redeclaring
  a common gem with a different constraint is a hard parse error — *"You cannot
  specify the same gem twice with different version requirements"*. So shared
  pins are authoritative across every unit by Bundler's own rules, not by
  convention.
- Residual skew is possible only for gems *absent* from common that two units
  declare independently. Demonstrated: `mustermann` resolving to `3.1.1` in one
  unit and `4.0.0` in another.

That last point is the real cost of N lockfiles, and it is narrower than an
earlier draft of this section claimed. Three mitigations, in order of value:

1. **Put every shared gem in `common.gemfile`** — the framework, the serializer,
   anything wire-relevant. Bundler then enforces uniformity for exactly the
   gems where skew would matter.
2. **A CI consistency check** over unit lockfiles, failing on any gem resolved
   to more than one version. About ten lines; a working version is in
   `spike/child-eval`.
3. **`bundler-multilock`** if stricter synchronisation is ever wanted — it
   derives secondary lockfiles from a default one.

Worth keeping in proportion: skew in *non*-shared gems is much less alarming
than it first sounds. Units are independently deployed artifacts whose contract
is the wire format and schema hash (§4), not their gem graphs — the same reason
separately deployed services safely run different dependency versions. Build-time
bundle verification (step 4) still earns its place, but now for *file*-level
slicing rather than for policing the gem boundary, which Bundler handles.

Separately, for the gems *this project ships* (`prospect`, `prospect-cdk`, …), the
standard Ruby monorepo pattern applies: the gemspec declares a real version
dependency for publishing, while the development Gemfile overrides it with
`gem "prospect", path: "../prospect"`. Note this is precisely where Bundler is weaker than
pnpm — `path:` doesn't compose with publishing, so the dev/release split is
manual rather than a `workspace:*` specifier rewritten at publish time.

**Zip over container by default.** `Runtime.RUBY_4_0` exists, so managed-runtime
zip is available and image pull cost disappears. The Rails example uses
`DockerImageFunction`, which is right for Rails and wrong here — typed procedures
are small. Use `Code.from_asset` with bundling so native extensions compile
against the right libc and architecture:

```ruby
AWSCDK::Lambda::Code.from_asset(unit_dir, {
  bundling: {
    image:   AWSCDK::Lambda::Runtime.RUBY_4_0.bundling_image,
    command: ["bash", "-c", "bundle install --path /asset-output/vendor/bundle && cp -au . /asset-output"]
  }
})
```

Container images stay the fallback for bundles over the zip limit or with
unusual native deps.

#### Measured: it works, but architecture choice is expensive

`spike/run_bundling.sh` builds a Gemfile with genuinely-compiled native
extensions (`oj`, `bcrypt`, `bigdecimal` — no precompiled binaries available)
inside `public.ecr.aws/sam/build-ruby4.0`, on an x86_64 host:

| Platform        | Pull | Build     | Extensions built | Exit |
| --------------- | ---- | --------- | ---------------- | ---- |
| `linux/amd64`   | 104s | **23s**   | `x86_64-linux`   | 0    |
| `linux/arm64`   | 104s | **941s**  | `aarch64-linux`  | 0    |

Both work. `sorbet-runtime` installs cleanly alongside. But **emulated arm64
compilation is 41× slower** — 15.7 minutes against 23 seconds — because qemu is
emulating every instruction of every `make` invocation.

That reverses the earlier default. arm64 Lambda is cheaper per GB-second and
generally faster at runtime, but the *build* cost is only acceptable when the
builder is genuinely arm64. So:

- **Default `X86_64`.** It is the architecture that never produces a
  15-minute surprise on a contributor's laptop or a stock CI runner.
- **`ARM_64` is opt-in and worth taking** — on Apple Silicon, or arm64 CI
  runners, where it builds natively and costs nothing extra.
- The construct should **detect emulation and warn** rather than silently
  burning quarter-hours: if the requested architecture differs from the build
  host's, say so at synth time and name the fix.

Choosing per-host would be worse than either option, since it makes build output
depend on who ran the build.

#### Build count is the real scaling problem

The 941s figure is per *bundle*, and `:per_router` granularity means one bundle
per router. Naively that multiplies: ten routers on an emulated arm64 build is
over two hours. Two mitigations, both worth designing in from the start:

1. **Deduplicate by gem set.** Units whose declared Bundler groups resolve to
   the same lockfile subset should share one built artifact. In practice most
   routers depend on the same handful of gems, so N units usually collapse to a
   small number of distinct bundles. This is cheap to implement — hash the
   resolved gem set and memoise — and it attacks the multiplier directly.
2. **Consider a Lambda Layer for shared gems.** Build the common set once,
   attach to every function, keep only unit-specific code in the function
   itself. This trades against §6's slicing goal — a layer must be the union of
   its consumers' dependencies — so the useful form is one layer per *distinct
   gem set* rather than one global layer, which is the same grouping as (1).

The 3.63GB image is its own cost: pull dominates a cold build (104s vs 23s), so
CI must cache it explicitly, and bundling should be skipped entirely when the
lockfile and gem set are unchanged. CDK asset hashing gives some of this for
free, but only after the first build on each machine.

### The handler is an event adapter, not a second dispatcher

```ruby
# Never `bundle exec` — the standalone setup is ~630ms cheaper. See cold start.
require_relative "vendor/bundle/bundler/setup"
require_relative "boot"
HANDLER = Prospect::Lambda.handler(
  AppRouter, unit: "users",
  context_builder: MyApp::Context.method(:from_event)
)
def handle(event:, context:) = HANDLER.call(event, context)
```

`Prospect::Lambda` decodes the API Gateway v2 payload and delegates to **the same
dispatcher the Rack transport uses**. Validation, middleware, error mapping and
batching must not fork per transport — that divergence is precisely how "works
locally, breaks deployed" gets built in. Lambda is a third event source
alongside Rack and the in-process caller, never a third implementation. Local
dev stays a plain Rack process running the whole router, with no emulator in the
common loop.

### Cold start, measured

Measured in `public.ecr.aws/lambda/ruby:4.0` with CPU capped to match Lambda's
memory→vCPU allocation (1769MB = 1 vCPU). Scripts in `spike/coldstart`. Medians
of 7 runs.

**Wall clock at 512MB (0.29 vCPU) — process start to ready:**

| | ms |
| --- | --- |
| Ruby VM boot, nothing else | 148 |
| `bundle exec ruby -e ""` | 779 |
| `bundle exec` + `require "sorbet-runtime"` | 825 |
| **`--standalone` + `require "sorbet-runtime"`** | **285** |
| `--standalone` + sorbet + rack | 286 |

**The dominant cost is Bundler, not Sorbet.** `bundle exec` adds ~630ms of pure
overhead at 512MB — four times what `sorbet-runtime` costs. `bundle install
--standalone` generates a `vendor/bundle/bundler/setup.rb` that sets `$LOAD_PATH`
directly and never loads the Bundler runtime at all, taking 825ms → 285ms.

So: **the handler must never run under `bundle exec`.** The generated shim
requires the standalone setup file. This is the single largest cold-start lever
available and it costs nothing.

**In-process init at three sizes** (excludes VM boot; 50 structs + 50 sig'd
methods):

| Scenario | 512MB | 1024MB | 1769MB |
| --- | --- | --- | --- |
| `require "sorbet-runtime"` | 107 | 69 | 36 |
| + 50 `T::Struct` definitions | 124 | 87 | 50 |
| + first `from_hash` on each | 197 | 93 | 55 |
| + sigs exercised (`full`) | 201 | 102 | 60 |

Three conclusions, one of which corrects an earlier draft of this section:

1. **`T::Configuration.default_checked_level = :never` does not help cold
   start.** Measured 104.8ms vs 108.5ms — indistinguishable. The cost is in
   *loading* `sorbet-runtime`, not in wrapping `sig`-ed methods. An earlier
   draft recommended disabling sig wrapping to save init time; that was wrong.
   It may still help warm-path throughput, but that is a different claim and is
   not measured here.
2. **Raise the default memory.** Init drops 3.3× from 512MB to 1769MB (201ms →
   60ms) while GB-seconds stay flat — 0.100 vs 0.106 GB-s. Higher memory is
   roughly cost-neutral and substantially faster, so `memory_size` defaults to
   1024 rather than 512.
3. **Sorbet is affordable.** ~100ms at 512MB, ~36ms at 1769MB, and structs
   themselves are cheap to define. This answers the open question directly:
   cold start does **not** force the frontend seam. Sorbet stays the v0
   frontend on merit, and the seam remains an option rather than a roadmap
   item.

Caveats worth stating: this excludes AWS sandbox provisioning (typically another
100–200ms, and outside our control), excludes the framework's own code because it
doesn't exist yet, and approximates Lambda's CPU allocation with Docker limits
rather than reproducing it. Treat the *ratios* as sound and the absolute floor as
optimistic. A realistic v0 target is roughly 300–400ms of controllable init at
1024MB with the standalone bundle.

### What Lambda does to the persistence question

The pluggable-ORM thread isn't dead, it inverts. Connection *pools* are an
anti-pattern here: each concurrent execution environment holds its own, so pool
size multiplies by concurrency and exhausts the database. The Rails example
reaching for DynamoDB rather than RDS is that same conclusion found in practice.

So the adapter must distinguish two lifecycles a Rack app can safely conflate:

- **Cold-start scope** — clients, config, credentials. Built once per execution
  environment, reused across invocations.
- **Invocation scope** — transactions, request identity, anything that must not
  leak between invocations sharing a warm container.

Leaking invocation state into cold-start scope is *the* classic Lambda bug, and
the adapter should make it structurally hard rather than merely documented.
Concretely: RDS Proxy or a data API for relational stores, DynamoDB where it
fits, and no pool-sizing knobs that only make sense for long-lived processes.

### Testing — and using this project to exercise the Ruby CDK

`Prospect::CDK::Service` is testable without an AWS account and without deploying:
synthesise the stack and assert on the CloudFormation output.

```ruby
stack    = AWSCDK::Stack.new(AWSCDK::App.new, "Test")
Prospect::CDK::Service.new(stack, "Api", { router: AppRouter, granularity: :per_router })
template = AWSCDK::Assertions::Template.from_stack(stack)

template.resource_count_is("AWS::Lambda::Function", 3)
template.has_resource_properties("AWS::Lambda::Function", { Architectures: ["arm64"] })
```

This is the natural test for the "granularity is invisible to clients" claim:
synthesise the same router at all three granularities and assert the route set
is identical while the function count differs.

It also runs in the other direction. This framework is a far more demanding
consumer of the jsii Ruby target than the `rails-blog-lambda` example, which
uses four constructs, never subclasses below `Stack`, and creates nothing
dynamically. `Prospect::CDK::Service` must subclass `Constructs::Construct`, generate
N children from the IR at synth time, interpolate tokens, and wire grants across
constructs it created itself.

`spike/jsii_probe.rb` exercises exactly that surface and currently reports
**18/19** against `aws-cdk-lib 0.0.0.20260725025349`:

| Capability                                             | Result |
| ------------------------------------------------------ | ------ |
| Subclass `Constructs::Construct`, N children from data  | pass   |
| `Runtime.RUBY_4_0`, `Duration.seconds`, `Architecture.ARM_64` | pass |
| `RemovalPolicy::DESTROY` (true enum, `::`)              | pass   |
| Token as env value, and in Ruby string interpolation    | pass   |
| `table.grant_read_write_data(fn)`                       | pass   |
| `APIGatewayv2::HttpAPI`, `HttpLambdaIntegration.new(id, fn)` | pass |
| `add_routes` with `{proxy+}` greedy path                | pass   |
| `Assertions::Template` count + property matchers        | pass   |
| `Architecture::ARM_64` as a constant                    | **fail** |

Every assumption §6 rests on holds. The one failure is a deliberate negative
control, and it's a usability finding rather than a bug:

**Static properties and enums are accessed differently, and nothing signals
which is which.** `RemovalPolicy::DESTROY` is a jsii enum and uses `::`;
`Architecture.ARM_64` is a static property on a class and uses `.`. In
TypeScript both are a dot and the distinction is invisible. In Ruby a user has
to know the underlying jsii kind to pick the right sigil, and guessing wrong
produces a bare `NameError` at the call site. I hit this writing the probe.
Worth considering whether the Ruby target should also define constants aliasing
static properties, so `::` works for both.

Keeping the probe pinned and re-running it against each gem build makes it a
cheap canary for the jsii Ruby target — regressions in construct subclassing or
token handling would otherwise surface as confusing failures deep inside this
framework.

## 7. Developer experience: Ruby procedures → TypeScript client

In a monorepo the backend toolchain is present anyway, so "may the frontend
build invoke Ruby?" is a *choice*, not a constraint. That choice shapes
everything else in this section, and it's worth making deliberately rather than
by default.

```
1.  edit a procedure in Ruby
2.  `bundle exec prospect watch`  →  regenerates TS types (and RBS) on save
3.  frontend type-checks against the new types immediately — red squiggles in
    the editor before anything is deployed
4.  `bundle exec prospect serve`  →  whole router as one local Rack process
```

Step 3 is the whole point. The failure mode this project exists to prevent is
learning at runtime that the backend renamed a field.

### CLI surface

```
bundle exec prospect schema                       # dump IR to schema.json
bundle exec prospect emit ts  --out ../web/src/api
bundle exec prospect emit rbs --out sig/
bundle exec prospect serve                        # local Rack server, all procedures
bundle exec prospect watch                        # re-emit on change
bundle exec prospect check                        # CI: fail if generated output is stale
```

### Committed artifacts vs generated on demand

Since Ruby is available, a Vite plugin invoking `bundle exec prospect emit` on Ruby
file change *is* viable — edit a procedure, types regenerate, HMR picks it up.
That's the closest thing to real tRPC's inference, and it's strictly nicer than
a separate watch process.

| | Commit generated `.ts` | Generate on demand |
| --- | --- | --- |
| Staleness | possible; needs a CI gate | impossible by construction |
| Git noise | generated diffs, merge conflicts | none |
| Frontend build deps | pure Node | Ruby + working bundle |
| Node-only deploy builds (Vercel/Pages) | fine | needs a custom image |
| Frontend-only contributors | no backend setup needed | need a working bundle |
| **API change visible in review** | **yes** | **no** |

Most rows favour on-demand. The last one is the reason not to go all the way,
and it's the one that's easy to miss: when generated types are committed, a
reviewer sees `- email: string` in the diff and instantly knows the change is
breaking. Generate on demand and that signal vanishes into the Ruby diff, where
API-shape changes are much harder to read.

Note also that "Ruby is installed" and "the backend bundle installs cleanly,
with native extensions compiled" are different bars. The second is the one a
frontend build actually needs, and it's the one that breaks.

**The synthesis, which the IR makes available: generate TypeScript on demand,
and commit `schema.json`.** Types are never stale and never in git; the IR is
the reviewable artifact. It's one structured file, it diffs legibly, it *is* the
API contract, and it's already what the drift hash is computed from (§4). A PR
that changes the API shows exactly that change in one place, without anyone
maintaining generated TypeScript.

This is the recommended default. Committing the `.ts` as well stays a supported
option for teams with Node-only deploy builds or frontend-only contributors.

### Generate types, not a client

This is the important decision. The emitter produces **only type declarations**;
the runtime client is a small hand-written npm package that is generic over
them.

```ts
// generated/schema.ts  — emitted, never edited
export interface User { id: string; email: string; createdAt: string; posts: Post[] }
export interface GetUserInput { id: string; includePosts?: boolean }

export type NotFound = { code: "not_found"; resource: string; id: string }

export type Procedures = {
  "users.get":    { kind: "query";    input: GetUserInput;    output: User; error: NotFound }
  "users.create": { kind: "mutation"; input: CreateUserInput; output: User; error: never }
}
```

```ts
// hand-written, versioned, tested once
import { createClient } from "@acme/prospect-client"
import type { Procedures } from "./generated/schema"

export const api = createClient<Procedures>({ url: "/rpc" })

const user = await api.users.get({ id: "1" })   // User, inferred
```

Why this split rather than emitting a client with a method per procedure:

- Generated output has **no logic in it**, so there is nothing to review and no
  bugs to fix in generated code. Diffs are legible — a renamed field is a
  one-line change, not a regenerated 2000-line file.
- Retries, batching, auth headers, and error decoding are fixed *once*, in a
  package with tests, rather than re-emitted into every consumer.
- The proxy in `createClient` recovers the tRPC call-site feel
  (`api.users.get(...)`) without generating a single method.

Batching belongs in the runtime client too — it can coalesce concurrent
`query` calls into one `POST /rpc?batch=1` transparently, the same way tRPC's
batch link does, with no change to call sites.

### The snake_case boundary

Ruby is snake_case, idiomatic TypeScript is camelCase, and this is a real
decision rather than a formatting preference.

**The wire format stays snake_case; TypeScript gets camelCase; the mapping is
generated per struct from the IR.** The tempting shortcut — a generic deep
`camelize`/`snakeize` in the runtime client — is quietly wrong: it cannot tell a
*struct field* (which should be renamed) from a *map key* (which is user data
and must not be). `{ "user_prefs": { "dark_mode": true } }` where the inner
object is a `T::Hash[String, Bool]` gets its data keys mangled.

The IR distinguishes `struct` from `map` (§4), so the emitter can produce
correct per-type mappers where a reflective transform cannot. This is a concrete
case of the IR earning its keep.

### Distribution

**Monorepo** (assumed default): emit into the frontend's source tree at build
and dev time, commit `schema.json` only. Backend change, contract change, and
frontend fallout all land in one atomic PR.

**Polyrepo**: CI publishes `@acme/api-types` on schema change; the frontend
takes it as a normal dependency. Version it by schema hash for exactness, or
semver if humans need to reason about compatibility. The cost is that backend
and frontend changes can no longer be atomic, which is a real loss.

### Three layers of drift protection

Codegen's failure mode is a stale client, so this is defended in depth:

1. **`prospect check` in CI** — regenerate and `git diff --exit-code` against the
   committed `schema.json`. With on-demand TypeScript there is no stale-types
   failure mode left to catch, so this narrows to one job: proving the committed
   contract matches the code, i.e. that the reviewable artifact is honest.
2. **Schema hash at runtime** (§4) — the client sends its hash; the server warns
   or rejects on mismatch. Catches a stale *deployed* client.
3. **The TypeScript compiler** — a removed or renamed field fails the frontend
   build. This is the layer that makes the whole project worthwhile.

### Getting the URL after deploy

`Prospect::CDK::Service` emits a `CfnOutput` with the front-door URL; `cdk deploy
--outputs-file` writes it where the frontend's env config can read it. Because
granularity is invisible to clients (§6), one generated client works unchanged
against local Rack, a preview stage, and production — only the base URL differs.

### Optional: query hooks

Most of tRPC's perceived magic in React is `useQuery`/`useMutation`. A TanStack
Query adapter is a natural add-on, generated from the same `Procedures` type —
`kind: "query" | "mutation"` is already in the IR precisely so this can be
mechanical. Worth doing, but after the core client, and as a separate package so
non-React consumers don't carry it.

## 8. The parts that are actually hard

**Sorbet type reflection.** `T::Props` exposes `.props`, with types as
`T::Types::Base` objects. Walking `Simple`, `Union` (which is how nilable is
represented), `TypedArray`, `TypedHash`, `T::Enum`, and nested `T::Struct` is
mechanical but fiddly, and needs cycle detection for self-referential types.
Sorbet's own `T::Props::Serializable` does a version of this, which is a useful
map of the terrain.

**Strict mode.** `T.untyped`, `T.any(String, Integer)`, `Symbol`, procs, and
arbitrary objects have no honest wire representation. The library should refuse
to boot when a procedure's input or output contains one, with a message naming
the offending field. "If it boots, it serializes" is a genuinely strong
guarantee and cheap to provide — but only if enforced eagerly, never at request
time.

**Errors as contract.** gRPC has status codes; tRPC's typed errors are weak. If
declared errors go in the IR, the TS client can expose a discriminated union and
the Ruby client can raise typed exception classes. This is a place to be better
than the thing we're imitating rather than merely equal to it.

**Middleware and context narrowing.** tRPC's most loved feature is arguably that
`.use(isAuthed)` *narrows the context type* — `ctx.user` goes from `User | nil`
to `User` for everything downstream. Reproducing that statically in Sorbet needs
per-procedure generated RBI and is the hardest thing on this list. v0 should
ship runtime middleware with a single declared context type per router, and
treat narrowing as a research spike, not a launch blocker.

**Streaming and subscriptions.** Defer entirely. Getting unary right is the
whole job for now.

## 9. v0 scope

Adding a deployment story roughly doubled this, so it's now staged. Building the
breadth before the depth would mean discovering the packaging problems last,
when they're the ones most likely to invalidate the design.

### Milestone 0 — walking skeleton

One procedure, end to end, proving every seam is real:

`T::Struct` → IR → one Lambda behind an `HttpAPI` → called from a generated Ruby
client with correct types. Single granularity (`:per_router`), declared Bundler
groups, no slicing, no TS, no batching.

The point was to hit the unknowns early. Two of the three are now answered by
spikes, before any framework code exists:

- **Does jsii hold up under synth-time IR consumption?** Yes —
  `spike/jsii_probe.rb`, 18/19, §6.
- **Does `Runtime.RUBY_4_0` bundling build native gems?** Yes, on both
  architectures — `spike/run_bundling.sh`, §6. It also changed the default
  architecture from arm64 to x86_64.
- **What is a realistic cold start with `sorbet-runtime` loaded?** Answered —
  `spike/coldstart`, §6. ~285ms total at 512MB with a standalone bundle, of
  which Sorbet is ~100ms. It does *not* force the frontend seam, and it found a
  much bigger lever: `bundle exec` costs ~630ms and must be avoided.

Everything else is comparatively known work.

### v0

> **Status.** Built: the router DSL, one dispatcher, Rack and Lambda adapters,
> IR extraction, the TypeScript emitter, and the CDK construct — 129 specs.
> Not built: packaging, the RBS and Ruby client emitters, and schema-hash drift
> checking. See §11, where the gaps are ranked.

- Sorbet reflection → IR, behind the frontend interface, strict-mode boot
  validation
- Router DSL: `query`, `mutation`, `mount`, `errors`, runtime middleware, `deploy`
- One dispatcher, three event sources: Rack, Lambda, in-process caller
- `Prospect::CDK::Service` construct — all three granularities, front-door routing
- Gem-level dependency slicing via declared Bundler groups, plus build-time
  bundle verification
- Ruby client emitter (RBI) and RBS emitter
- TypeScript client emitter
- Schema-hash drift detection

### Out

- Automatic file-level dependency slicing (tracing + static scan) — v1, and the
  staging in §6 exists specifically so v0 doesn't depend on it
- Streaming, subscriptions
- Static context narrowing through middleware
- Non-JSON codecs (msgpack, protobuf)
- Additional frontends — v0 defines the interface and ships one implementation;
  schema-DSL and RBS-parse frontends stay hypothetical until someone wants them
- Multi-region, canaries, alias/version management — CDK's job, not ours
- Rails-specific integration beyond "it's a Rack app"

## 10. The type-layer question, revisited

It was left open, but choosing `T::Struct` as the schema source mostly answers
it — for the *server*. The server is a Sorbet codebase, so the generated Ruby
client emits **RBI**: inline `sig` blocks work directly, one checker, no
`.rbs`/`.rb` pairs to keep in sync.

The client is a separate question, and the answer has moved. **RBS is promoted
into v0** rather than held back to v0.2. The reasoning:

- The frontend's type system and the emitter's are independent by construction.
  Authoring in Sorbet does not oblige a consumer to run Sorbet — but only if we
  actually ship the emitter that makes that true.
- The ecosystem is consolidating on RBS as the interchange format. T-Ruby is one
  data point: a new project that compiles to RBS specifically to avoid a runtime
  dependency. Betting that RBS-only consumers are a rounding error looks worse
  now than it did.
- If the product is a typed seam *between services*, the callee choosing the
  caller's type checker is close to a defect. A Sorbet-only client means only
  Sorbet shops can consume your API with types, which undercuts the pitch.
- Deferred emitters don't stay cheap. The longer the Ruby emitter is the only
  Ruby emitter, the more RBI-shaped assumptions leak into the IR — precisely the
  drift the IR exists to prevent. A second emitter built early is also the only
  real proof the IR is checker-agnostic rather than merely intended to be.

That last point generalises: the IR's neutrality is a claim, and claims about
extensibility are worth roughly nothing until a second implementation exists on
each side. RBS is the cheapest available test on the emitter side. The frontend
side stays untested in v0, which is a known and accepted risk — the interface is
there, but a single implementation can't prove it fits anything else.

## 11. Open questions

Reordered after building v0 and porting a real app onto it. The ranking is by
how much each would hurt, not by how interesting it is.

### Answered

- ~~Name and gem availability.~~ `prospect`, verified unclaimed.
- ~~Do struct definitions need declaring to the router, or is reachability from
  procedure signatures enough?~~ Reachability. `IR.extract` walks from each
  procedure's input and output and registers what it finds, with a placeholder
  written before fields are walked so self-referential types terminate.
- ~~The IR needs a `date` scalar.~~ Added, along with `DateTime` mapping to
  `timestamp` — ORMs return `DateTime`, never `Time`.
- ~~Does `Prospect::CDK::Service` belong in a companion gem?~~ No: an explicit
  `require "prospect/cdk"` gives the same isolation for free, and can still
  become a gem if the dependency needs its own release cycle.
- ~~Which errors should Prospect own?~~ `NotFound`, `Forbidden`, `Unauthorized`,
  `InvalidInput`. bookface redeclaring them silently lost their HTTP statuses
  (an unauthenticated call returned 422), which settled it.

### Open — and now blocking

1. ~~**Nothing packages a deployment artifact.**~~ Built — `Prospect::Package`.
   Plans and builds one artifact per unit: app sources, a generated handler
   shim, and a standalone bundle sliced by the unit's gemfile, installed in the
   Lambda image. Verified against bookface: 5 units, 3 distinct gem sets after
   dedup, 31–38MB each, every one booting in a Lambda-like container and
   answering a real API Gateway event.

   Three things it found that the design had not anticipated:

   - **`bundle install --standalone` does not vendor `path:` gems.** It writes
     an absolute host path into `setup.rb`, so the artifact deploys and then
     `LoadError`s on first invocation. Path gems are now copied into the bundle
     and the entry rewritten. Caught by the verify step, which is exactly the
     failure it exists for.
   - **Unit gemfiles are fragments, not standalone Gemfiles** — the root Gemfile
     supplies `source`, and `path:` resolves relative to the primary gemfile. So
     the build runs *in place* via `BUNDLE_GEMFILE` with the app mounted at its
     own absolute path, rather than copying gemfiles somewhere flat.
   - **Containers must run as the invoking user.** Otherwise every built file is
     root-owned on the host and the next `rm -rf build` fails.

2. **Nothing has ever been deployed.** Everything up to `cdk deploy` now works:
   bookface synthesises a complete template — 6 Lambdas, 13 routes with
   per-route auth, a JWT authorizer, four DynamoDB tables, Cognito — against
   real built artifacts, offline and without credentials. What remains untested
   is the part only AWS can answer: whether the stack comes up, what cold start
   actually costs (the container measurement excludes sandbox provisioning), and
   whether a real Cognito token flows through the authorizer into `ctx.viewer`.

   ~~Optional auth is not expressible.~~ Solved with `Prospect::Authorizer`, a
   Lambda REQUEST authorizer using the SIMPLE response format. An API Gateway
   JWT authorizer is all-or-nothing — it rejects a request with no token, and a
   route without one receives no verified claims at all — which would leave
   bookface's four public-but-viewer-dependent procedures behaving as though
   every caller were signed out.

   It turned out to be **better than the JWT authorizer, not merely a
   workaround**: because a Lambda authorizer receives `rawPath`, it decides per
   *procedure* rather than per route. Routes therefore stay greedy, where the
   JWT authorizer forced a split into one exact route per procedure to carry
   different auth. bookface went from 13 routes to 6.

   Security posture, deliberately chosen: a present-but-invalid token is
   treated as anonymous on a public procedure (an expired session should not
   black out the public feed, and it grants no access) and refused on a
   protected one. An unreachable JWKS refuses rather than failing open. JWKS is
   cached in cold-start scope; claims are per invocation.
3. ~~**The schema hash is emitted and then ignored.**~~ Wired end to end. The
   emitter publishes `SCHEMA_HASH`, the TypeScript client sends it as
   `X-Prospect-Schema` on every request, and `Dispatcher#check_schema` compares
   it — from both transports, so Rack and Lambda behave identically.

   Default policy is **warn, not reject**: failing hard would break every
   browser holding a cached bundle the moment the contract changed, which is a
   worse outcome than a log line. `on_schema_mismatch: :reject` returns 409 with
   both hashes. A batch is checked once per request rather than per call — a
   stale client is stale for all of it, and partial success is worse than
   either outcome.

   The hash is baked into each function's environment at synth time, so no cold
   start spends anything walking the type graph to recompute it.

### Open — design questions the implementation sharpened

4. **The frontend seam is still decorative.** §2's rule is that the IR must be
   sufficient to construct a validator. `Dispatcher#validate!` does not read the
   IR — it reads Sorbet's `T::Types::Base` objects directly via `props`. So a
   non-Sorbet frontend would still have to bring its own validator, which is
   exactly the outcome the rule exists to prevent. Fixing it means validating
   from IR nodes instead, and that is the only thing that would make the seam
   real rather than intended.
5. **Middleware scoping is unsettled.** `authenticated do … end` is implemented
   and works, but bookface flagged the shape: a block hides its own extent in a
   long file, and there is no way to say "all mutations". Alternatives are
   `use RequireLogin, only: %i[create update]` or a tRPC-style procedure
   builder. Cheap to change now, expensive once apps depend on it.
6. **Context narrowing.** `ctx.viewer` stays `T.nilable` inside
   `authenticated do`, so every bookface mutation opens with `ctx.authenticated!`
   to satisfy a type system that should already know. This is tRPC's most-loved
   feature and the largest ergonomic gap in the port. Needs per-procedure
   generated RBI, and remains a research spike.
7. **Sum types.** The IR has a `union` node and nothing produces one — every
   Sorbet union encountered so far has been `T.nilable` or `T::Boolean`, both of
   which collapse. A real sum type needs a discriminator to emit a usable
   TypeScript discriminated union, and Sorbet has no natural way to declare one.
8. **Pagination has no IR shape.** bookface invented `FeedPage { posts,
   next_cursor }` by hand. Cursor-paginated lists recur often enough that
   letting every app invent one guarantees they will all differ.

### Open — smaller, or cheap to answer

9. **Is `.max` the right precedence for `deploy:` settings?** Where a unit holds
   several procedures the construct takes the largest requested memory and
   timeout, on the grounds that undersizing fails at runtime and oversizing is
   a rounding error. Defensible, but it means one greedy procedure silently
   raises the bill for its whole service.
10. **Does arm64 cold-start materially better?** Only x86_64 was measured. If
    arm64's init is meaningfully faster, "arm64 with mandated arm64 build hosts"
    could still beat "x86_64 everywhere" despite the 41× emulated build penalty.
    One rerun of `spike/coldstart/run.sh` under `--platform linux/arm64`.
11. **The `from_hash` row in the cold-start table is nonlinear** — 73ms extra at
    512MB, ~6ms at 1024MB, a gap larger than the CPU difference explains.
    Probably GC or noise, but worth confirming before anyone sizes at 512MB.
12. **Does Ruby 4.0's 148ms VM boot floor improve with YJIT or a bootsnap-style
    cache?** Over half the measured cold start, and none of it is ours.
13. **API Gateway's per-API route quota.** `:per_procedure` creates one route
    per procedure and will hit it. The fix is greedy routes plus in-function
    dispatch, which costs nothing in client terms because §6 already makes
    granularity invisible — but it is unimplemented.
14. **The RBS and Ruby client emitters do not exist.** §9 puts both in v0 and
    only TypeScript was built. The RBS one matters more than it looks: it is the
    only real evidence the IR is checker-agnostic rather than TypeScript-shaped,
    and that claim is currently untested.
15. **Should the OpenAPI emitter be in v0?** Still nearly free once the IR
    exists, and still buys documentation plus non-generated-client consumers.
