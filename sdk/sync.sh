#!/usr/bin/env bash
# The template variables (NAME, API_IDENT, YEAR, ...) are read by render() through ${!key}, which
# static analysis cannot follow: no warnings about them being unused.
# shellcheck disable=SC2034
# =================================================================================================
# sync.sh: pushes freshly generated SDKs into their repositories vp-<api>-sdk-<language>
# =================================================================================================
#
# Called by the reusable workflow sdk-sync.yml, after the server's build has written one OpenAPI
# document per API (<api>.json and <api>.yaml). It runs just as well on a laptop, against local
# test repositories (see docs/sdks.md of veilplane-server, "Trying the sync locally").
#
# For every API:
#   1. Read its version from the document (info.version, e.g. 1.2.0). The major version (1) picks
#      the branch (v1) in every SDK repository; the full version becomes the release tag (v1.2.0).
#   2. Generate the SDKs in all languages: run $GENERATE (in veilplane-server: the Maven module
#      `sdk`, i.e. OpenAPI Generator) with the API's name and version.
#   3. For every language, in the repository vp-<api>-sdk-<language>:
#      a. clone it and check out the branch v<major>, or start that branch if it doesn't exist yet;
#      b. (breaking changes were refused before, by the workflow's job "breaking" with oasdiff);
#      c. replace everything with the generated SDK, plus the files from templates/: LICENSE
#         (Apache 2.0), README.md, renovate.json and .github/workflows/sdk.yml;
#      d. commit, if anything changed;
#      e. tag v<version>, if that version has no tag yet. Pushing the tag starts the repository's
#         own workflow (sdk.yml), which releases the SDK. A tag whose release never finished (no
#         GitHub release exists for it) is pushed again, which starts its release again. An already released version is never
#         tagged again (registries such as Maven Central never accept the same version twice): if
#         the code changed without a new version, the change is pushed but not released, and a
#         warning says so;
#      f. push the branch, then the tag on its own;
#      g. set the repository's settings, if $ADMIN_TOKEN is given: About (description, link to the
#         package in its registry, topics), no wiki and projects, the newest major version as the
#         default branch, and remove a leftover branch "main" (see configure_repository).
#
# Input, from the environment:
#   SPECS          directory with the OpenAPI documents <api>.json and <api>.yaml (required)
#   GENERATED      where $GENERATE writes the SDKs, one directory per generator (required)
#   GENERATE       the command that generates the SDKs of one API (required); it is called with
#                  -Dsdk.api=<api> -Dsdk.version=<version> -Dsdk.goMajorSuffix=<"" or /v2, /v3...>
#   APIS           which APIs, space-separated (default: every document in $SPECS)
#   LANGUAGES      which languages (default: "rust ts go java")
#   OWNER          GitHub owner of the SDK repositories (default: veilplane)
#   TOKEN          token with "contents" and "workflows" write access to the SDK repositories
#                  (in CI: the GitHub App's short-lived token)
#   ADMIN_TOKEN    token with "administration" write access to the SDK repositories, for step 3g;
#                  without it the settings are left alone
#   GITHUB_API     GitHub's REST API (default: https://api.github.com)
#   REMOTE         printf pattern of a repository's URL, %s is the repository's name
#                  (default: GitHub with $TOKEN; tests use local bare repositories)
#   AUTHOR_NAME, AUTHOR_EMAIL   the author of the commits in the SDK repositories
#   DRY_RUN=1      do everything except pushing
#
# Exit status: 0 if every repository is in sync; 1 if any API or repository was refused (the
# others are still synced; the log says which and why).
set -euo pipefail

# ---- Settings ----------------------------------------------------------------------------------

here="$(cd "$(dirname "$0")" && pwd)"
templates="$here/templates"
: "${SPECS:?SPECS: directory of the OpenAPI documents}" "${GENERATED:?GENERATED: output directory of the generator}" "${GENERATE:?GENERATE: generating command}"
SPECS="$(cd "$SPECS" && pwd)" # absolute: the script changes directories below
mkdir -p "$GENERATED" && GENERATED="$(cd "$GENERATED" && pwd)"
LANGUAGES="${LANGUAGES:-rust ts go java}"
OWNER="${OWNER:-veilplane}"
REMOTE="${REMOTE:-https://x-access-token:${TOKEN:-}@github.com/${OWNER}/%s.git}"
GITHUB_API="${GITHUB_API:-https://api.github.com}"
AUTHOR_NAME="${AUTHOR_NAME:-Julian Siebert}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-mail@julian-siebert.de}"
work="$(mktemp -d)" # the clones; removed at the end
trap 'rm -rf "$work"' EXIT

if [[ -z "${APIS:-}" ]]; then
  APIS=""
  for f in "$SPECS"/*.json; do APIS+="$(basename "$f" .json) "; done
fi

# Repository suffix -> directory of OpenAPI Generator's output, and the language's display name.
declare -A generator=([rust]=rust [ts]=typescript [go]=go [java]=java)
declare -A language=([rust]=Rust [ts]=TypeScript [go]=Go [java]=Java)

# Fills a template: replaces every {{KEY}} with the variable KEY. Values may contain anything
# (slashes, newlines); unknown keys stay as they are.
render() {
  local text key
  text="$(cat "$1")"
  for key in NAME LANGUAGE LANG API API_IDENT MAJOR VERSION YEAR GO_MODULE DESCRIPTION INSTALL; do
    text="${text//\{\{$key\}\}/${!key-}}"
  done
  printf '%s\n' "$text"
}

# Calls GitHub's REST API with the settings token: api METHOD PATH [JSON body].
api() {
  curl -fsS -X "$1" "$GITHUB_API$2" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" ${3:+-d "$3"} >/dev/null
}

# The package page of an SDK in its registry: the repository's link ("Website" in About).
registry_url() {
  case "$3" in
    rust) echo "https://crates.io/crates/vp-$2-sdk" ;;
    ts) echo "https://www.npmjs.com/package/@veilplane/$2-sdk" ;;
    go) echo "https://pkg.go.dev/$GO_MODULE" ;;
    java) echo "https://central.sonatype.com/artifact/com.veilplane/vp-$2-sdk" ;;
  esac
}

# Sets what GitHub shows about an SDK repository, from the same facts as everything else, so it
# never has to be maintained by hand:
#   - About: description, link to the package in its registry, topics;
#   - no wiki and no projects (the README and the API reference are the documentation;
#     issues stay on for questions and bug reports);
#   - the default branch is the newest major version (v1, v2, ...): what visitors see first, and
#     where Renovate looks for its configuration;
#   - a branch "main" left over from creating the repository (holding nothing but README.md,
#     LICENSE or .gitignore) is deleted once it is no longer the default branch.
# Needs the App's "Administration" permission; without it the sync goes on and only warns.
# Not possible through GitHub's API: hiding "Packages", "Releases" or "Deployments" from the
# repository's home page (docs/sdks.md of veilplane-server says how to do it by hand).
configure_repository() {
  local repo="$1" api_name="$2" lang="$3" newest settings topics
  newest="$(git ls-remote --heads origin 'refs/heads/v*' | sed 's|.*refs/heads/v||' | grep -E '^[0-9]+$' | sort -n | tail -1)"
  settings="$(jq -n --arg d "Veilplane $api_name API: ${language[$lang]} SDK (generated, Apache 2.0)" \
    --arg h "$(registry_url "$repo" "$api_name" "$lang")" --arg b "v$newest" \
    '{description: $d, homepage: $h, default_branch: $b, has_wiki: false, has_projects: false}')"
  topics="$(jq -n --arg a "$api_name" --arg l "${lang/ts/typescript}" '{names: ["veilplane", "sdk", "openapi", "api-client", $a, $l]}')"
  if api PATCH "/repos/$OWNER/$repo" "$settings" && api PUT "/repos/$OWNER/$repo/topics" "$topics"; then
    echo "settings: About, link, topics; default branch v$newest"
  else
    echo "::warning::$repo: could not update the repository's settings (does the GitHub App have the permission \"Administration: Read and write\"?)"
    return 0
  fi
  if git ls-remote --exit-code --heads origin main >/dev/null; then
    git fetch -q origin main
    if ! git ls-tree --name-only FETCH_HEAD | grep -qvxE 'README(\.md)?|LICENSE|\.gitignore'; then
      git push -q origin :refs/heads/main && echo "deleted the branch main left over from the repository's creation"
    else
      echo "::warning::$repo: the branch main holds more than README.md, LICENSE and .gitignore; not deleted"
    fi
  fi
}

# git push, tried up to three times: GitHub occasionally refuses a push for reasons of its own
# ("unable to write file", "missing necessary objects") that are gone a few seconds later.
push() {
  local attempt
  for attempt in 1 2 3; do
    git push -q origin "$@" && return 0
    echo "push of $* failed (attempt $attempt of 3)"
    sleep $((attempt * 5))
  done
  return 1
}

# Whether the GitHub release of a tag exists, i.e. the tag's release workflow ran to its end. Only
# with a token for GitHub's API; without one (local tests) every tag counts as released.
has_release() {
  [[ -n "${TOKEN:-}" ]] || return 0
  local status
  status="$(curl -sS -o /dev/null -w '%{http_code}' "$GITHUB_API/repos/$OWNER/$1/releases/tags/$2" \
    -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")"
  [[ "$status" != 404 ]]
}

failed=0
for API in $APIS; do

  # ---- 1. Version, branch, tag -----------------------------------------------------------------

  spec="$SPECS/$API.json"
  VERSION="$(jq -r .info.version "$spec")"
  DESCRIPTION="$(jq -r '.info.description // ""' "$spec")"
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "::error::$API: the API's version '$VERSION' is not MAJOR.MINOR.PATCH (set it in the server's code: new Api(\"$API\", \"1.0.0\", ...))"
    failed=1
    continue
  fi
  MAJOR="${VERSION%%.*}"
  API_IDENT="${API//-/_}" # usable as an identifier (Rust crate, Go package, Java package)
  YEAR="$(date +%Y)"
  # Go requires the major version in the module path from v2 on: github.com/.../vp-x-sdk-go/v2
  suffix=""
  ((MAJOR >= 2)) && suffix="/v$MAJOR"
  GO_MODULE="github.com/$OWNER/vp-$API-sdk-go$suffix"
  branch="v$MAJOR"
  tag="v$VERSION"

  # ---- 2. Generate the SDKs of this API in all languages ---------------------------------------

  echo "::group::$API $VERSION: generate the SDKs"
  rm -rf "$GENERATED"
  $GENERATE "-Dsdk.api=$API" "-Dsdk.version=$VERSION" "-Dsdk.goMajorSuffix=$suffix"
  echo "::endgroup::"

  for LANG in $LANGUAGES; do
    repo="vp-$API-sdk-$LANG"
    NAME="$repo"
    LANGUAGE="${language[$LANG]}"
    dir="$work/$repo"
    echo "::group::$repo, branch $branch"

    # ---- 3a. Clone, check out (or start) the branch of this major version ----------------------

    # shellcheck disable=SC2059
    url="$(printf "$REMOTE" "$repo")"
    git clone -q "$url" "$dir"
    cd "$dir"
    git config user.name "$AUTHOR_NAME"
    git config user.email "$AUTHOR_EMAIL"
    if git ls-remote --exit-code --heads origin "$branch" >/dev/null; then
      git checkout -q -B "$branch" "origin/$branch"
    else
      echo "new branch $branch (first SDK of major version $MAJOR)"
      git checkout -q --orphan "$branch" # no history shared with other branches
      git rm -rq --cached . 2>/dev/null || true
    fi

    # ---- 3c. Replace the content -----------------------------------------------------------------

    # everything but the repository itself goes; the generator's output takes its place
    find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    cp -R "$GENERATED/${generator[$LANG]}/." .
    rm -rf .openapi-generator .openapi-generator-ignore # the generator's bookkeeping
    mv README.md API.md                                 # its README is the reference of operations and models
    if [[ $LANG == rust ]]; then
      # crates.io shows these fields; OpenAPI Generator has no options for them
      sed -i -e "s|^authors = .*|authors = [\"$AUTHOR_NAME\"]|" \
        -e "s|^description = .*|description = \"Veilplane $API API\"\\nrepository = \"https://github.com/$OWNER/$repo\"\\nhomepage = \"https://veilplane.com\"\\nreadme = \"README.md\"|" Cargo.toml
    fi
    cp "$SPECS/$API.yaml" openapi.yaml # the next sync compares against it (3b)
    cp "$templates/LICENSE" LICENSE
    cp "$templates/renovate.json" renovate.json
    INSTALL="$(render "$templates/install/$LANG.md")"
    render "$templates/README.md" >README.md
    mkdir -p .github/workflows
    render "$templates/sdk.yml" >.github/workflows/sdk.yml

    # ---- 3d. Commit ------------------------------------------------------------------------------

    git add -A
    if git diff --cached --quiet && git rev-parse -q --verify HEAD >/dev/null; then
      echo "unchanged"
    else
      git commit -q -m "$API API $VERSION"
      echo "committed $(git rev-parse --short HEAD)"
    fi

    # ---- 3e. Tag a new version -------------------------------------------------------------------

    tag_push="" # "new": push the new tag; "again": push the tag once more, to start the release again
    if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
      released="$(git ls-remote --tags origin "refs/tags/$tag^{}" | cut -f1)"
      if [[ "$(git rev-parse HEAD)" != "$released" ]] &&
        ! git diff --quiet "$released" HEAD -- . ':!README.md' ':!renovate.json' ':!.github' 2>/dev/null; then
        # changes to README.md, renovate.json or the workflow alone need no release; anything else does
        echo "::warning::$repo: the SDK changed, but version $VERSION is already tagged, so the change is not released. Raise the version of the $API API in the server's code (patch for fixes, minor for additions) to release it."
      elif ! has_release "$repo" "$tag"; then
        # Tagged, but its release never finished: its workflow did not start, or failed (a missing or
        # wrong registry token, say). The code is the same, so the tag moves to the current commit
        # and is pushed again, which starts the release again. Publishing skips what a registry
        # already has, so a repeated release does no harm.
        git tag -fa "$tag" -m "$API API $VERSION"
        tag_push=again
        echo "$tag has no release yet: tagging again to start its release"
      fi
    else
      git tag -a "$tag" -m "$API API $VERSION"
      tag_push=new
      echo "tagged $tag (its push starts the release in $repo)"
    fi

    # ---- 3f. Push --------------------------------------------------------------------------------

    # The branch first, then the tag on its own: GitHub does not reliably start the workflows of a
    # tag that arrives in the same push as its branch.
    if [[ "${DRY_RUN:-}" == 1 ]]; then
      echo "dry run: would push $branch${tag_push:+ and $tag}"
    else
      push "refs/heads/$branch"
      case "$tag_push" in
        new) push "refs/tags/$tag" ;;
        again)
          # deleting and pushing again makes a new push event even if the tag did not move
          push ":refs/tags/$tag"
          push "refs/tags/$tag"
          ;;
      esac
    fi

    # ---- 3g. Repository settings ------------------------------------------------------------------

    if [[ -n "${ADMIN_TOKEN:-}" && "${DRY_RUN:-}" != 1 ]]; then
      configure_repository "$repo" "$API" "$LANG"
    fi
    cd - >/dev/null
    echo "::endgroup::"
  done
done
exit $failed
