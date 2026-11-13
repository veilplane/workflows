# workflows

Reusable GitHub Actions workflows for Veilplane's repositories, so that each repository's own workflow is a few lines that say *what*, and the *how* lives here once.

This repository is public on purpose: the SDK repositories are public, and a public repository can only call reusable workflows of a public one. Nothing here is secret; secrets are passed in by the callers.

## Workflows

| Workflow | What it does | Used by |
|---|---|---|
| [`maven-ci.yml`](.github/workflows/maven-ci.yml) | `mvn verify` (or other goals) with a chosen JDK; optionally uploads a directory of the build as an artifact | veilplane-server |
| [`rust-ci.yml`](.github/workflows/rust-ci.yml) | `cargo fmt --check`, `clippy -D warnings`, `cargo test` for a workspace | Rust repositories |
| [`sdk-sync.yml`](.github/workflows/sdk-sync.yml) | generates the SDKs of every API from OpenAPI documents and pushes them into `vp-<api>-sdk-<language>` | veilplane-server |
| [`sdk-release.yml`](.github/workflows/sdk-release.yml) | builds an SDK repository; on a tag, publishes it to its registry and makes a GitHub release | every `vp-<api>-sdk-<language>` |

Callers pin `@main`. A change here takes effect in every repository at once, which is the point; it also means a change here should be tried on one repository first (call it with `workflows-ref` or `@<branch>`).

## The SDK pipeline

Veilplane's server is the only source of truth for its APIs. Its OpenAPI documents are generated from the Java code, and everything else follows from them:

```
veilplane-server, push to main
  └─ maven-ci: mvn verify
       └─ the tests write app/target/openapi/<api>.{json,yaml}   → artifact "openapi"
  └─ sdk-sync, for every API:
       ├─ mvn -pl sdk generate-sources -Dsdk.api=<api> -Dsdk.version=<info.version>
       │    (OpenAPI Generator: Rust, TypeScript, Go, Java)
       └─ for every language, repository vp-<api>-sdk-<language>, branch v<major>:
            ├─ oasdiff: refuse breaking changes against the openapi.yaml already there
            ├─ replace the content: generated code, API.md, docs/, openapi.yaml,
            │  LICENSE (Apache 2.0), README.md and .github/workflows/sdk.yml (sdk/templates)
            ├─ commit if anything changed
            └─ tag v<version> if that version has no tag yet, push
vp-<api>-sdk-<language>, push of the tag
  └─ sdk-release: build, publish to crates.io / npm / Maven Central / the Go proxy, GitHub release
```

Rules that follow from this:

- **The version of an API is the version of its SDKs.** It is set in the server's code (`new Api("fleet", "1.2.0", …)`). Changing the API without raising the version updates the SDK repositories, but releases nothing; the sync warns about it.
- **The major version is the branch and the path.** `/fleet/v1` ↔ branch `v1` ↔ releases `v1.x.y`. A breaking change needs a new major version: a new `Api` with `2.0.0` under `/fleet/v2`, while `v1` keeps being served and its SDKs keep their branch.
- **Go** wants the major version in the module path from v2 on (`github.com/veilplane/vp-fleet-sdk-go/v2`); the sync takes care of it.
- **Nothing in an SDK repository is edited by hand**; the next sync overwrites it. Changes to what every SDK repository contains go into [`sdk/templates`](sdk/templates) here.

### Package names

| Language | Package | Repository |
|---|---|---|
| Rust | crate `vp-<api>-sdk` | `vp-<api>-sdk-rust` |
| TypeScript | `@veilplane/<api>-sdk` | `vp-<api>-sdk-ts` |
| Go | module `github.com/veilplane/vp-<api>-sdk-go` | `vp-<api>-sdk-go` |
| Java | `com.veilplane:vp-<api>-sdk`, packages `com.veilplane.sdk.<api>` | `vp-<api>-sdk-java` |

### Secrets

Set once as organization secrets (visible to the repositories that need them):

| Secret | Needed by | What |
|---|---|---|
| `SDK_PUSH_TOKEN` | veilplane-server | a fine-grained token (or GitHub App token) with *Contents: write* and *Workflows: write* on all `vp-*-sdk-*` repositories. Not `GITHUB_TOKEN`: it cannot write to other repositories, and tags it pushes would not start their workflows. |
| `CARGO_REGISTRY_TOKEN` | Rust SDKs | crates.io token allowed to publish `vp-*-sdk` |
| `NPM_TOKEN` | TypeScript SDKs | npm automation token for the `@veilplane` scope |
| `MAVEN_CENTRAL_USERNAME`, `MAVEN_CENTRAL_PASSWORD` | Java SDKs | Central Portal user token for the namespace `com.veilplane` |
| `MAVEN_GPG_PRIVATE_KEY`, `MAVEN_GPG_PASSPHRASE` | Java SDKs | the key that signs the artifacts (ASCII-armored), its public part on a key server |

Each registry is skipped while its secrets are missing, so releases work (as tags and GitHub releases) before any registry is set up. Go needs no secret; once a repository is public, the Go module proxy is asked to fetch each new tag.

### Trying the sync locally

[`sdk/sync.sh`](sdk/sync.sh) is the whole logic and runs anywhere with git, jq and the generator's toolchain (oasdiff optional). Against local bare repositories instead of GitHub:

```sh
for l in rust ts go java; do git init -q --bare /tmp/remotes/vp-fleet-sdk-$l.git; done
cd veilplane-server && mvn verify
SPECS=app/target/openapi GENERATED=sdk/target/sdk GENERATE="mvn -B -q -pl sdk generate-sources" \
  APIS=fleet REMOTE=/tmp/remotes/%s.git ../workflows/sdk/sync.sh
```

`DRY_RUN=1` does everything but push.

## Copyright

Copyright 2026 Julian Siebert. The templates in `sdk/templates` become part of the SDK repositories, which are licensed under the Apache License 2.0.
