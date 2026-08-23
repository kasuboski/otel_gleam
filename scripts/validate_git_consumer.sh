#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/otel-gleam-git.XXXXXX")
package_repo="$tmp_root/package"
consumer="$tmp_root/consumer"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$package_repo" "$consumer"
cp "$root/gleam.toml" "$root/manifest.toml" "$root/README.md" "$root/LICENSE" "$package_repo/"
cp -R -L "$root/src" "$root/docs" "$package_repo/"

(
  cd "$package_repo"
  git init -q
  git config user.email otel-gleam-validation@example.invalid
  git config user.name otel-gleam-validation
  git add gleam.toml manifest.toml README.md LICENSE src docs
  git commit -qm "standalone production package"
)

revision=$(git -C "$package_repo" rev-parse HEAD)
cp -R "$root/examples/basic/." "$consumer/"
rm -rf "$consumer/build" "$consumer/manifest.toml"

path_dependency='otel_gleam = { path = "../.." }'
git_dependency="otel_gleam = { git = \"file://$package_repo\", ref = \"$revision\" }"
if ! grep -Fq "$path_dependency" "$consumer/gleam.toml"; then
  echo "basic example does not contain the expected local otel_gleam dependency" >&2
  exit 1
fi
sed -i "s|$path_dependency|$git_dependency|" "$consumer/gleam.toml"

if [ -d "$consumer/.git" ]; then
  echo "consumer unexpectedly became a Git repository" >&2
  exit 1
fi

(
  cd "$consumer"
  gleam deps download
  gleam check
)

printf 'Basic example passed with Git dependency revision %s\n' "$revision"
