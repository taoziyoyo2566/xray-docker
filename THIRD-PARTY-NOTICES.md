# Third-Party Notices

This repository's own contents — the Dockerfile, entrypoint, release
automation scripts, tests, workflows, and documentation — are licensed under
the MIT License (see [`LICENSE`](LICENSE)).

**The published container image is a different artifact.** It bundles
third-party components that carry their own licenses and obligations. Nothing
in this repository vendors or modifies those components; they are downloaded
from their official release artifacts at build time, unmodified, and their
SHA256 digests are verified before use.

---

## Xray-core

| | |
|---|---|
| Upstream | https://github.com/XTLS/Xray-core |
| License | **MPL-2.0** (Mozilla Public License 2.0) |
| Bundled as | `/usr/bin/xray`, extracted from the official `Xray-linux-*.zip` release asset |
| Modified | No |

The image redistributes the official Xray binary in Executable Form. Per
MPL-2.0 §3.2, recipients are informed of the license and the corresponding
Source Code Form is available from the upstream repository above. The upstream
`LICENSE` file is included in the image.

## geosite.dat

| | |
|---|---|
| Upstream | https://github.com/v2fly/domain-list-community |
| License | **MIT** |
| Bundled as | `geosite.dat`, shipped inside the official Xray release asset |
| Modified | No |

## geoip.dat

| | |
|---|---|
| Upstream | https://github.com/v2fly/geoip |
| License | **CC-BY-SA-4.0** (Creative Commons Attribution-ShareAlike 4.0 International) |
| Bundled as | `geoip.dat`, shipped inside the official Xray release asset |
| Modified | No |

**Attribution:** the GeoIP data in this image is produced by the
[v2fly/geoip](https://github.com/v2fly/geoip) project and is licensed under
[CC-BY-SA-4.0](https://creativecommons.org/licenses/by-sa/4.0/). It is
redistributed here unmodified. Any redistribution of this data, modified or
not, must carry the same attribution and be shared under the same license.

## Alpine Linux

| | |
|---|---|
| Upstream | https://alpinelinux.org/ |
| Base image | `alpine:3.24`, digest-pinned in the Dockerfile |
| Added packages | `ca-certificates`, `tzdata` |

Alpine and its packages carry their own individual licenses. Consult the
distribution for per-package terms.

---

## Notes for maintainers

- The geodata files ship **inside** the official Xray release zip; they are not
  fetched separately. Their licenses therefore apply to every image build.
- `geoip.dat` is the only bundled component under a **share-alike** license.
  Replacing it with a different geodata source (for example a community rules
  set) changes the obligations recorded here — update this file in the same
  change.
- When the Dockerfile's asset layout changes, keep the upstream `LICENSE` in
  the image. Removing it would drop the MPL-2.0 notice required for
  redistribution.
