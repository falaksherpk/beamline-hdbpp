#!/usr/bin/env bash
# Build the HDB++ .debs from the four pinned upstream tarballs in a clean, throwaway
# container (handbook Part 3, Ch30; same pattern as beamline-slurm's Ch18 build-deb.sh).
# Usage: packaging/deb/build-deb.sh OUTDIR
# Needs the builder image: podman build -t localhost/beamline-hdbpp-builder:noble packaging/deb
# HDBPP_CONTAINER (default podman) and HDBPP_BUILDER_IMAGE exist for the sandbox rehearsal only.
set -euo pipefail

engine=${HDBPP_CONTAINER:-podman}
image=${HDBPP_BUILDER_IMAGE:-localhost/beamline-hdbpp-builder:noble}
cache=${XDG_CACHE_HOME:-$HOME/.cache}/beamline-hdbpp
url_base=https://gitlab.com/tango-controls/hdbpp
# Build order: libhdbpp first; the other three build-depend on its -dev package (libhdb++-dev).
order=(libhdbpp libhdbpp-mysql hdbpp-es hdbpp-cm)
out=${1:?usage: $0 OUTDIR}

repo=$(git rev-parse --show-toplevel)
cd "$repo"
if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
  echo "refusing: tracked files have uncommitted changes; the build follows HEAD's SHA256SUMS" >&2
  exit 1
fi
if ! "$engine" image exists "$image" 2>/dev/null && ! "$engine" image inspect "$image" >/dev/null 2>&1; then
  echo "refusing: builder image $image not found" >&2
  exit 1
fi

# The four tarballs this commit pins, one line each, in build order.
sums=$(git show HEAD:SHA256SUMS)
mapfile -t lines <<< "$sums"
if [[ ${#lines[@]} -ne ${#order[@]} ]]; then
  echo "refusing: SHA256SUMS must hold exactly ${#order[@]} lines" >&2
  exit 1
fi
tarballs=()
for i in "${!order[@]}"; do
  name=${order[$i]}
  if [[ ! ${lines[$i]} =~ ^[0-9a-f]{64}\ \ (${name}-([0-9][0-9.]*)\.tar\.gz)$ ]]; then
    echo "refusing: SHA256SUMS line $((i + 1)) must be '<sha256>  ${name}-<tag>.tar.gz'" >&2
    exit 1
  fi
  tarballs+=("${BASH_REMATCH[1]}")
done

mkdir -p "$out"
out=$(realpath "$out")
if [[ -n $(ls -A "$out") ]]; then
  echo "refusing: $out is not empty" >&2
  exit 1
fi

# Download once into the cache; never use a file that fails the pinned hash.
mkdir -p "$cache"
for i in "${!order[@]}"; do
  name=${order[$i]} tarball=${tarballs[$i]}
  tag=${tarball#"$name"-}
  tag=${tag%.tar.gz}
  if [[ ! -e $cache/$tarball ]]; then
    echo "=== downloading $url_base/$name/-/archive/$tag/$tarball"
    curl -fsSL -o "$cache/$tarball.part" "$url_base/$name/-/archive/$tag/$tarball"
    mv "$cache/$tarball.part" "$cache/$tarball"
  fi
done
if ! (cd "$cache" && sha256sum -c --strict <<< "$sums"); then
  echo "refusing: a tarball in $cache does not match the pinned SHA-256 (left in place for inspection)" >&2
  exit 1
fi

echo "=== building ${order[*]} (beamline-hdbpp $(git rev-parse --short HEAD)) in $image -> $out"
mounts=(-v "$cache:/in:ro" -v "$repo/debian:/pkg:ro" -v "$out:/out")
# Inside: for each package in order, the upstream tree is unpacked, upstream's own debian/
# is replaced by ours, root installs the Build-Depends, the unprivileged 'ubuntu' user
# builds. libhdb++2 and libhdb++-dev are installed right after their build, so the other
# three can build-depend on libhdb++-dev. Root copies the results to /out. The backend
# must link the MariaDB client, never libmysqlclient. lintian runs last and writes
# /out/lintian.txt; an error there fails the build but leaves the packages for inspection.
# shellcheck disable=SC2016  # the inner script expands its variables in the container
"$engine" run --rm -i -e "ORDER=${order[*]}" -e "TARBALLS=${tarballs[*]}" "${mounts[@]}" "$image" \
  bash -euo pipefail -c '
    read -ra order <<< "$ORDER"
    read -ra tarballs <<< "$TARBALLS"
    apt-get update -qq
    for i in "${!order[@]}"; do
      name=${order[$i]}
      echo "=== $name from ${tarballs[$i]}"
      mkdir "/build/$name"
      tar -xzf "/in/${tarballs[$i]}" -C "/build/$name" --strip-components=1
      rm -rf "/build/$name/debian"
      cp -r "/pkg/$name" "/build/$name/debian"
      chown -R ubuntu:ubuntu /build
      apt-get build-dep -y -qq --no-install-recommends "/build/$name"
      (cd "/build/$name" && runuser -u ubuntu -- env DEB_BUILD_OPTIONS="parallel=$(nproc)" dpkg-buildpackage -b -us -uc)
      if [[ $name == libhdbpp ]]; then
        apt-get install -y -qq --no-install-recommends ./libhdb++2_*.deb ./libhdb++-dev_*.deb
      fi
    done
    cd /build
    deps=$(dpkg-deb -f libhdb++mysql7_*.deb Depends)
    echo "libhdb++mysql7 Depends: $deps"
    if [[ $deps != *libmariadb3* || $deps == *libmysqlclient* ]]; then
      echo "refusing: the backend must depend on libmariadb3 and not on libmysqlclient" >&2
      exit 1
    fi
    cp ./*.deb ./*.buildinfo ./*.changes /out/
    (cd /out && sha256sum -- *.deb > SHA256SUMS)
    rc=0
    runuser -u ubuntu -- lintian --fail-on error --info ./*.changes > /out/lintian.txt 2>&1 || rc=$?
    echo "lintian exit: $rc (findings in lintian.txt: $(grep -c "^[EW]: " /out/lintian.txt) E/W lines)"
    exit "$rc"
  '
echo "=== results"
ls -l "$out"
