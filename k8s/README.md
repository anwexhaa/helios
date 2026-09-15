# k8s

Kubernetes manifests.

- `base/` — the manifests shared by every environment
- `overlays/dev`, `overlays/test`, `overlays/prod` — per-environment differences only:
  replica counts, resource requests, log level

Environments differ by overlay, never by hand-edited manifests. If something is true in
production but not in dev, it belongs in an overlay file that is committed.
