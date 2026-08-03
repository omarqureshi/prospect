# Prospect

A tRPC-shaped RPC layer for Ruby. You write Sorbet `T::Struct`s and a router;
you get runtime validation, an HTTP transport, a typed TypeScript client, and
Lambda deployment — all derived from the same declaration.

See [DESIGN.md](DESIGN.md) for the architecture and the reasoning, including
what was measured rather than assumed.

```ruby
class UsersRouter < Prospect::Router
  path :users
  context AppContext

  query :get, input: GetUserInput, output: User, errors: [Prospect::NotFound] do |input, ctx|
    User.from(ctx.db.users.find(input.id) || raise(Prospect::NotFound.new(resource: "user", id: input.id)))
  end

  authenticated do
    mutation :create, input: CreateUserInput, output: User do |input, ctx|
      # ...
    end
  end
end
```

## What's here

| | |
| --- | --- |
| `Prospect::Router` | the authoring DSL; misuse fails at load time, not on the first request |
| `Prospect::Dispatcher` | the single dispatcher every transport delegates to |
| `Prospect::RackApp` | local transport — the whole router in one process |
| `Prospect::Lambda` | API Gateway v2 event adapter, scoped to one deployment unit |
| `Prospect::Authorizer` | optional-auth Lambda authorizer (needs the `jwt` gem) |
| `Prospect::IR` | reflects a router into the schema document every emitter reads |
| `Prospect::Emit::TypeScript` | generates types — not a client |
| `Prospect::Package` | builds a deployable artifact per unit |
| `Prospect::CDK::Service` | synthesises the infrastructure (needs `aws-cdk-lib`) |

## Optional dependencies

Deliberately not runtime dependencies, because most consumers need neither:

- **`jwt`** — only `Prospect::Authorizer` uses it, and only the authorizer's own
  deployment unit installs it.
- **`aws-cdk-lib`, `constructs`** — only `require "prospect/cdk"` needs them, and
  they pull in a Node sidecar that has no business in a Lambda's cold start.

## Status

Early. The router, dispatcher, both transports, IR extraction, the TypeScript
emitter, packaging and the CDK construct all work and are specced. Not built
yet: the RBS and Ruby client emitters, and static context narrowing. Nothing has
been deployed to AWS.

## Development

```sh
bundle install
bundle exec rake            # specs
npm install && npx tsc -p spec/golden   # typecheck the emitted TypeScript
```

The CDK specs need `aws-cdk-lib`; they skip loudly when it is absent rather than
passing silently.
