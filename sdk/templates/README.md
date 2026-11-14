# {{NAME}}

The {{LANGUAGE}} SDK for the **Veilplane {{API}} API** (`https://api.veilplane.com/{{API}}/v{{MAJOR}}`), version {{VERSION}}.

{{DESCRIPTION}}

## Install

{{INSTALL}}

## Authentication

Every call (except the few that are public) needs an API token, sent as `Authorization: Bearer vp_<id>_<secret>`. Tokens are issued through the auth API (`vp-auth-sdk-*`) or, later, in the Veilplane dashboard. Keep them secret: a token can do everything its scopes allow.

## Reference

[API.md](API.md) lists every operation and model, with links to their pages under [docs/](docs/). [openapi.yaml](openapi.yaml) is the OpenAPI document this SDK was generated from.

## Versions

- This SDK's version is the API's version. Its major version is the one in the API's path (`/{{API}}/v{{MAJOR}}`).
- Every major version lives on its own branch: `v1`, `v2`, … Releases are tags (`v{{VERSION}}`) on that branch.
- Within a major version, changes never break existing callers: the build that produces this SDK refuses breaking changes to the OpenAPI document unless the major version changes.

## How this repository is made

Nothing here is edited by hand. Veilplane's server generates the OpenAPI document from its code, and from it the SDKs in every language, with [OpenAPI Generator](https://openapi-generator.tech). Each change of the API is pushed here automatically; a new version is tagged and released (see `.github/workflows/sdk.yml`). Issues and questions are welcome; pull requests can't be merged, since the next generation would overwrite them, but they are a good way to show what you mean.

## License

Apache License 2.0, see [LICENSE](LICENSE). Copyright {{YEAR}} Julian Siebert.
