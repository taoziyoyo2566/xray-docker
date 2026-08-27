# Xray

[Xray-core](https://github.com/XTLS/Xray-core) packaged for `linux/amd64` and
`linux/arm64`. About 26 MB compressed.

The binary and rule data come from the official Xray release assets, whose
SHA256 digests are verified before unpacking. Every image is run on both
architectures and asked for its version before it is given a tag.

## Run

```bash
docker run -d --name xray \
  -v ./config.json:/config.json:ro \
  -p 443:443 \
  taoziyoyo2566/xray-docker:latest
```

The configuration is checked before Xray starts, so a broken config exits with
the parser error instead of restarting forever.

Instead of one file you can mount a directory of JSON fragments at
`/etc/xray/conf.d`. Xray appends `inbounds` and `outbounds` across fragments
but **replaces** `routing`, `dns`, and `policy` wholesale, so keep each of
those in a single file.

The container runs as UID 10000 and works with `--read-only`, `--cap-drop ALL`
and `--security-opt no-new-privileges`.

## Tags

| Tag | Meaning |
|---|---|
| `latest` | Newest verified stable. The only tag that moves. |
| `vX.Y.Z` | An upstream stable release. Immutable. |
| `vX.Y.Z-beta` | An upstream prerelease. Immutable, never aliased to `latest`. |

Version tags move. When the image definition changes, such as a base image
update or a packaging fix, the tags in the current window are rebuilt and
re-pointed, so `v26.3.27` always means the best build of that Xray version.
Pin the digest if you need content that never changes.

Tags follow upstream automatically: the newest stable plus every prerelease
published after it. Older tags are kept, never deleted.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `XRAY_CONFIG` | `/config.json` | Single-file config path |
| `XRAY_CONFDIR` | `/etc/xray/conf.d` | Fragment directory, used when the single file is absent |
| `XRAY_LOCATION_ASSET` | `/usr/local/share/xray` | Where `geoip.dat` and `geosite.dat` are read from |
| `XRAY_HEALTH_PORT` | unset | Port for the container healthcheck to probe. Unset means no probe. |
| `TZ` | `Asia/Shanghai` | Container timezone |

## Rule data

`geoip.dat` and `geosite.dat` ship at `/usr/local/share/xray`, so `geoip:` and
`geosite:` routing rules work without extra setup. They are the copies bundled
in the official Xray release, so they are only as fresh as that release. Mount
your own directory over that path to use a different rule set.

## Licenses

This image redistributes Xray-core (MPL-2.0), `geosite.dat` from
[v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)
(MIT), and `geoip.dat` from [v2fly/geoip](https://github.com/v2fly/geoip)
(CC-BY-SA-4.0), all unmodified. Full texts are in `/usr/share/licenses/xray/`
inside the image.

Build tooling: [taoziyoyo2566/xray-docker](https://github.com/taoziyoyo2566/xray-docker) (MIT)
