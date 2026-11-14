# {{NAME}}

The {{LANGUAGE}} SDK for the **veilplane {{API}} API** (`https://api.veilplane.com/{{API}}/v{{MAJOR}}`), version {{VERSION}}.

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

## License

Apache License 2.0, see [LICENSE](LICENSE). Copyright {{YEAR}} Julian Siebert.
