#!/usr/bin/env bash
# Pushes generated SDKs into their repositories vp-<api>-sdk-<language>.
#
# For every API (one OpenAPI document <api>.json + <api>.yaml in $SPECS):
#   1. generate the SDKs ($GENERATE -Dsdk.api=… -Dsdk.version=… -Dsdk.goMajorSuffix=…),
#   2. for every language, check out the branch v<major> of its repository (or start it),
#   3. refuse breaking changes against the document already there (oasdiff), within a major version,
#   4. replace the content with the generated SDK, LICENSE, README.md, openapi.yaml and the
#      workflow that builds and releases it,
#   5. commit if anything changed, tag v<version> if that version has no tag yet, and push.
#
# Environment:
#   SPECS        directory with the OpenAPI documents (required)
#   GENERATED    where $GENERATE writes the SDKs, one directory per generator (required)
#   GENERATE     the generating command (required), e.g. "mvn -B -q -pl sdk generate-sources"
#   APIS         space-separated API names (default: every document in $SPECS)
#   LANGUAGES    default "rust ts go java"
#   OWNER        GitHub owner of the SDK repositories (default veilplane)
#   TOKEN        token with contents and workflows write access to the SDK repositories
#   REMOTE       printf pattern of a repository's URL (default: GitHub with $TOKEN); for tests
#   AUTHOR_NAME, AUTHOR_EMAIL   who commits
#   DRY_RUN=1    do everything but push
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
templates="$here/templates"
: "${SPECS:?}" "${GENERATED:?}" "${GENERATE:?}"
SPECS="$(cd "$SPECS" && pwd)"
mkdir -p "$GENERATED" && GENERATED="$(cd "$GENERATED" && pwd)"
LANGUAGES="${LANGUAGES:-rust ts go java}"
OWNER="${OWNER:-veilplane}"
REMOTE="${REMOTE:-https://x-access-token:${TOKEN:-}@github.com/${OWNER}/%s.git}"
AUTHOR_NAME="${AUTHOR_NAME:-Julian Siebert}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-mail@julian-siebert.de}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [[ -z "${APIS:-}" ]]; then
  APIS="$(cd "$SPECS" && ls -1 *.json | sed 's/\.json$//' | tr '\n' ' ')"
fi

declare -A generator=([rust]=rust [ts]=typescript [go]=go [java]=java)
declare -A language=([rust]=Rust [ts]=TypeScript [go]=Go [java]=Java)

# Replaces {{NAME}} placeholders; values may contain anything.
render() {
  local text
  text="$(cat "$1")"
  local key
  for key in NAME LANGUAGE LANG API API_IDENT MAJOR VERSION YEAR GO_MODULE DESCRIPTION INSTALL; do
    text="${text//\{\{$key\}\}/${!key-}}"
  done
  printf '%s\n' "$text"
}

failed=0
for API in $APIS; do
  spec="$SPECS/$API.json"
  VERSION="$(jq -r .info.version "$spec")"
  DESCRIPTION="$(jq -r '.info.description // ""' "$spec")"
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "::error::$API: version '$VERSION' is not x.y.z"
    failed=1
    continue
  fi
  MAJOR="${VERSION%%.*}"
  API_IDENT="${API//-/_}"
  YEAR="$(date +%Y)"
  suffix=""
  ((MAJOR >= 2)) && suffix="/v$MAJOR"
  GO_MODULE="github.com/$OWNER/vp-$API-sdk-go$suffix"
  branch="v$MAJOR"
  tag="v$VERSION"

  echo "::group::$API $VERSION: generate"
  rm -rf "$GENERATED"
  $GENERATE "-Dsdk.api=$API" "-Dsdk.version=$VERSION" "-Dsdk.goMajorSuffix=$suffix"
  echo "::endgroup::"

  for LANG in $LANGUAGES; do
    repo="vp-$API-sdk-$LANG"
    NAME="$repo"
    LANGUAGE="${language[$LANG]}"
    dir="$work/$repo"
    echo "::group::$repo $branch"
    # shellcheck disable=SC2059
    url="$(printf "$REMOTE" "$repo")"
    git clone -q "$url" "$dir"
    cd "$dir"
    git config user.name "$AUTHOR_NAME"
    git config user.email "$AUTHOR_EMAIL"
    if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
      git checkout -q -B "$branch" "origin/$branch"
    else
      echo "new branch $branch"
      git checkout -q --orphan "$branch"
      git rm -rq --cached . 2>/dev/null || true
    fi

    if [[ -f openapi.yaml ]] && command -v oasdiff >/dev/null; then
      if ! oasdiff breaking openapi.yaml "$SPECS/$API.yaml" --fail-on ERR; then
        echo "::error::$repo: breaking changes within major version $MAJOR; raise the major version of the $API API instead"
        failed=1
        cd - >/dev/null
        echo "::endgroup::"
        continue
      fi
    elif [[ -f openapi.yaml ]]; then
      echo "::warning::oasdiff not installed: breaking changes are not checked"
    fi

    find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    cp -R "$GENERATED/${generator[$LANG]}/." .
    rm -rf .openapi-generator .openapi-generator-ignore
    mv README.md API.md
    if [[ $LANG == rust ]]; then
      # crates.io shows these; the generator has no options for them
      sed -i -e "s|^authors = .*|authors = [\"$AUTHOR_NAME\"]|" \
        -e "s|^description = .*|description = \"Veilplane $API API\"\\nrepository = \"https://github.com/$OWNER/$repo\"\\nhomepage = \"https://veilplane.com\"\\nreadme = \"README.md\"|" Cargo.toml
    fi
    cp "$SPECS/$API.yaml" openapi.yaml
    cp "$templates/LICENSE" LICENSE
    INSTALL="$(render "$templates/install/$LANG.md")"
    render "$templates/README.md" >README.md
    mkdir -p .github/workflows
    render "$templates/sdk.yml" >.github/workflows/sdk.yml

    git add -A
    if git diff --cached --quiet && git rev-parse -q --verify HEAD >/dev/null; then
      echo "unchanged"
    else
      git commit -q -m "$API API $VERSION"
      echo "committed $(git rev-parse --short HEAD)"
    fi
    push=("refs/heads/$branch")
    if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
      if [[ "$(git rev-parse HEAD)" != "$(git ls-remote --tags origin "refs/tags/$tag^{}" | cut -f1)" ]] &&
        ! git diff --quiet "$(git ls-remote --tags origin "refs/tags/$tag^{}" | cut -f1)" HEAD -- . ':!README.md' ':!.github' 2>/dev/null; then
        echo "::warning::$repo: the SDK changed but $tag is already released; raise the version of the $API API to release it"
      fi
    else
      git tag -a "$tag" -m "$API API $VERSION"
      push+=("refs/tags/$tag")
      echo "tagged $tag"
    fi
    if [[ "${DRY_RUN:-}" == 1 ]]; then
      echo "dry run: would push ${push[*]}"
    else
      git push -q origin "${push[@]}"
    fi
    cd - >/dev/null
    echo "::endgroup::"
  done
done
exit $failed
