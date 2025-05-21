#!/usr/bin/env bash

# message prints text with a color, redirected to stderr in the event of
# warning or error messages.
message() {
  declare -A __colors=(
    ["error"]="31"   # red
    ["warning"]="33" # yellow
    ["begin"]="32"   # green
    ["ok"]="32"      # green
    ["info"]="1"     # bold
    ["reset"]="0"    # here just to note reset code
  )
  local __type="$1"
  local __message="$2"
  if [ -z "${__colors[$__type]}" ]; then
    __type="info"
  fi
  if [[ "${__type}" == "error" ]]; then
    echo -e "\e[${__colors[$__type]}m${__message}\e[0m" 1>&2
  else
    echo -e "\e[${__colors[$__type]}m${__message}\e[0m"
  fi
}

if [[ "$(head -n 1 CHANGELOG.md | cut -d ' ' -f 3-)" != "(Unreleased)" ]]; then
  message error "The changelog must have \"Unreleased\" in brackets next to its version number in order to be used by this tool."
  exit 1
fi

release=$(head -n 1 CHANGELOG.md | awk '{print $2}')
IFS="." read -r -a semver <<< "${release}"
major="${semver[0]}"
minor="${semver[1]}"
IFS="-+" read -r -a patchpremeta <<< "${semver[2]}"
patch="${patchpremeta[0]}"
extra="${patchpremeta[1]}"

for x in "${major}" "${minor}" "${patch}"; do 
  if ! [ "${x}" -eq "${x}" ]; then
    message error "${release} is not a proper semantic-versioned release."
    message error "Please update the first line in CHANGELOG.md to a numeric MAJOR.MINOR.PATCH version."
    exit 1
  fi
done

if [[ "${extra}" == "pre" ]]; then
  message error "Pre-releases tagged as \"pre\" are not supported. Release aborted."
  message error "Please update the first line in CHANGELOG.md to a version without the -pre tag,"
  message error "or use a different pre-release tag (i.e. beta)."
  exit 1
fi

if ! grep -q -F ".version = \"${release}\"," build.zig.zon; then
  message error "Version mismatch in build.zig.zon (${release} not found)."
  message error "Please update the version in build.zig.zon and try again."
  exit 1
fi

if [[ -t 0 ]]; then
  message warning "You are releasing: ${release}"
  message warning "Type \"yes\" to continue, anything else to abort."
  prompt="$(message info "Continue?")"
  read -r -p "${prompt} " confirm
  if [[ "${confirm}" != "yes" ]]; then
    message error "Release aborted."
    exit 1
  fi
fi

set -e

# Timestamp and update version in changelog
message begin "==> Timetsamping current release in CHANGELOG.md <=="
current_date="$(date "+%B %e, %Y" | sed -E -e 's/  / /')"
echo -e "## ${release} (${current_date})\n$(tail -n +2 CHANGELOG.md)" > CHANGELOG.md

message begin "==> Committing CHANGELOG.md <=="
git add CHANGELOG.md
git commit -m "$(echo -e "Release v${release}\n\nSee CHANGELOG.md for more details.")"

message begin "==> Tagging Release v${release} <=="
git tag "v${release}" -m "$(echo -e "Release v${release}\n\nSee CHANGELOG.md for more details.")"

if [[ "${extra}" != "" ]]; then
  # We just drop the pre-release tags from the release information and don't increment.
  message warning "NOTE: extra pre-release and metadata tags have been dropped from new version."
  message warning "Manual modification may be necessary post-release."
fi

new_prerelease="${semver[0]}.${semver[1]}.$((semver[2]+1))-pre"

message begin "==> Bumping CHANGELOG.md and build.zig.zon to Release v${new_prerelease} <=="
echo -e "## ${new_prerelease} (Unreleased)\n\nBumped version for dev.\n\n$(cat CHANGELOG.md)" > CHANGELOG.md
cat <<EOS > build.zig.zon
// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
.{
    .name = .z2d,
    .version = "${new_prerelease}",
    .fingerprint = 0x188c5a41eff938f,
    .minimum_zig_version = "0.14.0",
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
EOS

git add CHANGELOG.md build.zig.zon
git commit -m "Bump CHANGELOG.md and build.zig.zon to v${new_prerelease}"

message begin "==> Pushing Commits and Tags <=="
git push origin "$(git ls-remote --symref origin HEAD | head -n1 | awk '{print $2}')"
git push origin --tags

message ok "\nRelease v${release} successful."
