# beamline-hdbpp

Debian packages of HDB++, the Tango Controls archiving system, for the beamline lab
(Ubuntu 24.04, cppTango 9.5.0 from Ubuntu, MariaDB 10.11). Handbook Part 3, Chapter 30.

| source package | upstream tag | binary packages |
|---|---|---|
| `libhdbpp` | 2.2.1 | `libhdb++2`, `libhdb++-dev` |
| `libhdbpp-mysql` | 1.3.0 (builds 7.2.0) | `libhdb++mysql7` (schema files in `/usr/share/libhdb++mysql7/sql`) |
| `hdbpp-es` | 2.3.8 | `hdbpp-es` (`/usr/bin/hdb++es-srv`) |
| `hdbpp-cm` | 2.2.2 | `hdbpp-cm` (`/usr/bin/hdb++cm-srv`) |

The repository holds no upstream source: `SHA256SUMS` pins one GitLab tag tarball per
package, `SOURCE` records how they were checked, and `debian/<name>/` is our packaging.

    podman build -t localhost/beamline-hdbpp-builder:noble packaging/deb
    packaging/deb/build-deb.sh ~/artifacts/hdbpp-<date>

The build runs in a throwaway container from a digest-pinned `ubuntu:24.04`, in dependency
order (`libhdbpp` first, then the rest against the fresh `libhdb++-dev`). It refuses
uncommitted changes, a non-empty output directory, a tarball that fails its pinned hash,
and a backend linked against anything but the MariaDB client. Lintian errors fail it.

The EventSubscriber loads the backend by soname: `LibConfiguration` `libname=libhdb++mysql.so.7`.

Our files are MIT (`LICENSE`); the packaged software keeps its upstream licence
(LGPL-3+ for the libraries, GPL-3+ for the servers; see `debian/*/copyright`).
