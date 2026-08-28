# Xray

[Xray-core](https://github.com/XTLS/Xray-core) for `linux/amd64` and
`linux/arm64`, about 25 MB compressed. Built from the official release assets
with their SHA256 digests verified, and run on both architectures before any
tag is created.

## Run

```bash
docker run -d --name xray --restart unless-stopped \
  -v ./config.json:/config.json:ro \
  -p 443:443 \
  taoziyoyo2566/xray-docker:latest
```

The image ships no configuration — mount your own. It is validated before Xray
starts, so a broken config exits with the parser error instead of restarting
forever.

Runs as UID 10000, and works with `--read-only`, `--cap-drop ALL` and
`--security-opt no-new-privileges`.

| Variable | Default | Purpose |
|---|---|---|
| `XRAY_CONFIG` | `/config.json` | Single-file config path |
| `XRAY_CONFDIR` | `/etc/xray/conf.d` | Fragment directory, used when the single file is absent |
| `XRAY_LOCATION_ASSET` | `/usr/local/share/xray` | Where `geoip.dat` / `geosite.dat` are read from |
| `XRAY_HEALTH_PORT` | unset | TCP port for the healthcheck to probe on `127.0.0.1`. Unset means no probe. |
| `TZ` | `Asia/Shanghai` | Container timezone |

## Split configuration

Mount a directory of JSON fragments at `/etc/xray/conf.d` instead of one file.
Xray merges them in filename order, but not symmetrically:

| | Merge behaviour |
|---|---|
| `inbounds`, new tag | appended |
| `outbounds`, new tag | **prepended** — see below |
| either, existing tag | replaces the earlier entry |
| `routing`, `dns`, `policy`, … | later file overrides or supplements |

> **The first outbound is the default outbound.** Since new outbounds are
> prepended, adding a fragment can silently change where unmatched traffic
> goes. To append instead, put `tail` in the filename — e.g. `99_tail.json`.

Check the merged result before deploying:

```bash
docker run --rm -v ./conf.d:/etc/xray/conf.d:ro \
  --entrypoint /usr/bin/xray taoziyoyo2566/xray-docker:latest \
  run -confdir /etc/xray/conf.d -dump
```

Full rules: [Xray multiple-config documentation](https://xtls.github.io/en/config/features/multiple.html).

## Tags and updates

| Tag | Meaning |
|---|---|
| `latest` | Newest verified stable release |
| `vX.Y.Z` | An upstream stable release |
| `vX.Y.Z-beta` | An upstream prerelease. Never aliased to `latest`. |

New upstream releases appear automatically, usually within a day. Old tags are
kept, never deleted.

**No tag is immutable — not even `vX.Y.Z`.** A version tag names an upstream
Xray version, not a fixed set of bytes: when the image definition changes (a
base image security update, a packaging fix) the tag is rebuilt and re-pointed.
That is how a CVE fix reaches you without your chasing a new version number,
and the trade-off is that a tag alone does not pin content.

To take updates, pull and recreate — the tag you already use will have moved:

```bash
docker pull taoziyoyo2566/xray-docker:latest
docker rm -f xray && docker run -d --name xray ...   # same flags as above
```

To pin content instead, use a digest — those never change, and never receive
updates until you move the pin yourself:

```bash
docker run -d taoziyoyo2566/xray-docker@sha256:...
```

## Rule data

`geoip.dat` and `geosite.dat` ship at `/usr/local/share/xray`, so `geoip:` and
`geosite:` routing rules work out of the box. They are the copies bundled in
the official Xray release — a **snapshot from that release date**, never
refreshed in place — packaged by
[Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat),
which carries extra categories beyond the v2fly originals. Mount your own
directory over `/usr/local/share/xray` for current or different data.

## Licenses

The image bundles third-party components under several licenses. Full
statement: [`THIRD-PARTY-NOTICES.md`](https://github.com/taoziyoyo2566/xray-docker/blob/main/THIRD-PARTY-NOTICES.md);
a `NOTICE` and the license texts also ship at `/usr/share/licenses/` inside
the image.

- **Xray-core** — MPL-2.0, redistributed unmodified.
- **`geoip.dat`, `geosite.dat`** — from `v2ray-rules-dat` (GPL-3.0-only);
  `geosite.dat` derives from
  [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)
  (MIT), `geoip.dat` from **MaxMind's GeoLite2 Country** database.

> **This product includes GeoLite2 data created by MaxMind, available from
> [https://www.maxmind.com](https://www.maxmind.com).** That data is governed
> by the [MaxMind GeoLite EULA](https://www.maxmind.com/en/geolite/eula). If you
> redistribute this image, preserve this attribution and hold your recipients to
> equivalent terms; commercial redistribution may require a separate MaxMind
> license. The EULA also obliges licensees to stop using data older than thirty
> days — whether that reaches downstream recipients of a derived dataset is
> unresolved, and recorded in `THIRD-PARTY-NOTICES.md`. Mount your own rule data
> if you want none of these obligations.

Build tooling: [taoziyoyo2566/xray-docker](https://github.com/taoziyoyo2566/xray-docker),
MIT — the tooling only, not the bundled components above.
