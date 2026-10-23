# xray-docker

Build tooling that republishes official XTLS/Xray-core releases as the
multi-arch Docker Hub image `taoziyoyo2566/xray-docker` (`linux/amd64`,
`linux/arm64`). Consumed by `reality-ops` (`xray_image`, `edge_xray_image`);
publishing here does not deploy any node.

## Layout

- `.github/workflows/build-image.yml` — the sync: `discover` → `build-missing`
  → `reconcile-latest`, every five minutes and on `workflow_dispatch`. Its
  `env.IMAGE_NAME` is the only definition of the publish target.
- `.github/workflows/audit-xray-image-tags.yml` — weekly read-only tag audit.
- `.github/workflows/sync-dockerhub-overview.yml` — pushes `README.md` to the
  Docker Hub overview when it changes on `main`; `README.md` is written for
  Docker Hub readers.
- `.github/workflows/quality.yml` — checks on every PR and on `main`.
- `.github/dependabot.yml` — weekly PRs for the SHA-pinned actions and the
  digest-pinned Alpine base.
- `docker-build/` — `dockerfile`, entrypoint, and the scripts the workflows call.
- `tests/` — shell tests of those scripts and of the workflow's structure.
- `docs/runbooks/xray-image-release.md` — how to operate the sync.
- `docs/decisions.md` — why each part is the way it is, and when to revisit it.
  Code is the fact; correct this file when they disagree.

## Commands

```bash
for t in tests/*.sh; do bash "$t"; done
shellcheck -x docker-build/*.sh tests/*.sh
actionlint -no-color -shellcheck "$(command -v shellcheck)" \
  -ignore 'unexpected key "queue" for "concurrency" section'
hadolint docker-build/dockerfile
```

CI pins the linter versions and SHA256s in `quality.yml`; use the same ones
locally. CI also builds the image and runs `docker-build/smoke-image.sh`.

## Project Facts

- Canonical remote `origin` (`github.com/taoziyoyo2566/xray-docker`), main
  branch `main`, unprotected. Branches are `<type>/<topic>` with type `feat`,
  `fix`, `docs`, `ci`, or `test`; Dependabot uses its own `dependabot/…`.
  Changes merge through a pull request with a merge commit, after
  `quality.yml` passes.
- Only `main` runs on schedule, so a workflow change takes effect after merge.
- Merging to `main` publishes indirectly. A change to a build input (the files
  `docker-build/build-fingerprint.sh` hashes, including the Alpine digest)
  rebuilds and re-points every tag in the window on the next run. The cron fires
  every five minutes, but GitHub has started this repository's scheduled runs
  4–12 hours late (`docs/decisions.md` D-12b), so the rebuild can land hours
  after the merge. A change to `README.md` rewrites the Docker Hub overview.
  Treat such a merge as a Docker Hub write. A manual dispatch, moving `latest`,
  and deleting tags are direct writes, and each needs its own approval.
- An idle run must stay a check: no image pull, no container, no login
  (`docs/decisions.md` D-09, D-12b). `tests/test_xray_image_workflow.sh`
  asserts this.
- Version tags are moving aliases, not immutable; consumers pin digests
  (`docs/decisions.md` D-01).
- Commit subjects are plain imperative sentences without a type prefix, with a
  body explaining why.
- Secrets are GitHub Actions repository secrets (`DOCKERHUB_*`); their roles are
  in the runbook §14.1. Never read or copy their values.
