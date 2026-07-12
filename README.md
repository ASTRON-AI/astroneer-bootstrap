# astroneer-bootstrap

Public bootstrap entry point for **astroneer** — a user-scope provisioner +
manager for the astron dev environment on WSL/Ubuntu.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ASTRON-AI/astroneer-bootstrap/main/bootstrap.sh | bash
```

Nothing secret is fetched here. `bootstrap.sh` then clones the **private**
`ASTRON-AI/astroneer` repo using your already-logged-in `gh`/`git` (run
`gh auth login` first if needed), installs runtime deps (`gum`, `jq`), and puts
`astroneer` on your `PATH`. Then provision the environment:

```bash
~/.local/bin/astroneer install
```

## Why a separate repo?

GitHub visibility is per-repo, not per-file — you cannot expose a single file of
a private repo. So this small **public** repo hosts only `bootstrap.sh` (so the
`curl … | bash` one-liner works without auth), while the full tool stays in the
**private** `ASTRON-AI/astroneer`, reachable only via authenticated `gh`/`git`.

`bootstrap.sh` here is mirrored from the private repo, which is the source of
truth; update it there and copy the change over.
