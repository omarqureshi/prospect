# Changelog

## 0.0.2

- `Prospect::Package` accepts `env:`, forwarded into the build container. A
  private gem source needs credentials at build time and the container inherits
  nothing from the host. Forwarded rather than written to disk — a credential
  baked into the artifact would ship to Lambda, where it is useless and a
  liability.

## 0.0.1

First release. Everything here is specced (208 examples) and exercised by a real
application, but nothing has been deployed to AWS.

- `Prospect::Router` — the authoring DSL. Misuse (a procedure before `path`, a
  missing handler, a duplicate name, a non-`T::Struct` input, an unknown
  middleware or deploy key) raises `Prospect::DefinitionError` at load time
  rather than on the first request.
- `Prospect::Dispatcher` — one dispatcher; Rack and Lambda are event adapters
  over it, and a spec asserts they return identical bodies. Validates declared
  props itself, because `T::Struct.from_hash` does not check value types.
- `Prospect::RackApp`, `Prospect::Lambda` — local and API Gateway v2 transports,
  with batching and per-unit scoping.
- `Prospect::Authorizer` — a Lambda authorizer supporting *optional* auth, which
  an API Gateway JWT authorizer cannot express.
- `Prospect::IR`, `Prospect::Emit::TypeScript` — schema extraction and type
  generation, with a golden file and a `tsc` check over the output.
- `Prospect::Package` — per-unit deployable artifacts with gem slicing,
  deduplication and build-time boot verification.
- `Prospect::CDK::Service` — synthesises Lambdas, routes, an authorizer and an
  optional custom domain by reading the router's IR at synth time.
- Schema-hash drift detection across both transports.
