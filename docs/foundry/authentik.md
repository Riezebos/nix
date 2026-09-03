# Authentik as code

Authentik's own configuration — providers, applications, groups, the embedded
outpost's provider list — lives in `modules/features/authentik-blueprints/` as
[blueprints](https://docs.goauthentik.io/developer-docs/blueprints/), Authentik's
native declarative format. Nothing in that directory should be edited through the
admin UI: the next deploy overwrites it.

## What is and is not repo-managed

| Managed here | Managed in the UI |
|---|---|
| Groups (name, superuser flag) | Which users exist |
| Providers and applications | Which groups a user is in |
| Application access bindings | Flows and stages |
| The embedded outpost's provider list | The rest of the default brand |
| The default brand's `branding_*` fields | Everything else |

The split is enforced by how the importer works, not by convention: it builds
serializers with `partial=True` for objects that already exist, so a key absent
from a blueprint is left alone. That is why no entry in this directory may
contain a `users:` key — an *absent* `users` preserves UI-managed membership,
but an *empty* one would wipe every member on the next deploy.

The one deliberate exception is `05-iac-service-account.yaml`, which declares the
`svc-iac` machine identity and its group. It has to be self-healing or a rebuilt
host would come back with no way to administer Authentik except the UI.

## Theming

`40-brand.yaml` de-brands the login pages: it sets `branding_title` and hides
authentik's wordmark, photo background and "Powered by authentik" footer with
`branding_custom_css`.

CSS is the tool for this rather than the file fields because `branding_logo`,
`branding_favicon` and `branding_default_flow_background` are `FileField`s whose
validator rejects an empty value — they can be repointed but not cleared. If we
ever upload our own logo, set `branding_logo` and drop the rule that hides
`.pf-c-login__main-header.pf-c-brand`.

Custom CSS is unusually far-reaching here. The web UI writes it into
`<style data-id="brand-css">` in the document head *and* adopts it into every Lit
component's render root, so plain PatternFly 4 selectors work inside shadow DOM.
Selectors are therefore tied to authentik's markup and can break on upgrade;
re-check the flow pages after a version bump.

Two knobs deliberately left alone for now: `attributes.settings` on the brand
(theme base, and `enabledFeatures` for the API/notification drawers and search)
and each flow's `layout` and `background`. Both stay UI-managed.

## How it is applied

`authentik-blueprints.service` is a oneshot that runs
`ak apply_blueprint` over every file in the directory, in filename order.

Files are numbered so dependencies resolve: groups (`00-`) before the bindings
that reference them, providers (`10-`–`30-`) before the outpost that lists them
(`90-`). Cross-file references use `!Find`; within a file, `!KeyOf` is clearer.

The unit sets `AUTHENTIK_BLUEPRINTS_DIR` to the store path of this directory for
itself only. One consequence: `authentik_blueprints.metaapplyblueprint` is
unusable in this directory. It resolves the referenced blueprint's path relative
to that variable, so upstream's packaged `default/` files are not reachable and
the entry fails with `BlueprintRetrievalFailed`. Express ordering against those
blueprints through file numbering instead — see the header of `40-brand.yaml`.
The importer refuses any path outside that root, and the
long-running services must keep the package default so upstream's own `default/`
and `system/` blueprints still get discovered by the worker.

systemd re-runs the unit when a blueprint changes, because a changed file
changes the store path, which changes `ExecStart`. An unchanged deploy does not
re-run it. It is ordered after `authentik-worker`, since every blueprint
`!Find`s a flow or scope mapping that upstream's worker-side discovery creates;
on a first boot that discovery may not have run yet, so the unit retries on
failure rather than failing the deploy outright.

## Dry-running a change before deploying

Worth doing for anything non-trivial — it catches serializer errors against the
*live* database, which `nix flake check` cannot. It applies every file in one
transaction and rolls the whole thing back, so it is read-only.

```bash
ssh deploy@foundry 'rm -rf /tmp/ak-bp && mkdir -p /tmp/ak-bp'
scp modules/features/authentik-blueprints/*.yaml deploy@foundry:/tmp/ak-bp/
ssh deploy@foundry 'cat > /tmp/dryrun.py' <<'EOF'
from pathlib import Path
from django.db import transaction
from authentik.blueprints.v1.importer import Importer

class Rollback(Exception):
    pass

try:
    with transaction.atomic():
        for p in sorted(Path("/tmp/ak-bp").glob("*.yaml")):
            ok = Importer.from_string(p.read_text())._apply_models(raise_errors=True)
            print("DRYRUN", p.name, "OK" if ok else "FAIL")
        raise Rollback()
except Rollback:
    print("DRYRUN ROLLED BACK CLEANLY")
EOF
ssh deploy@foundry 'sudo systemctl show authentik-blueprints -p ExecStart --value'
```

Run the printed `ak` binary with the unit's environment plus
`AUTHENTIK_BLUEPRINTS_DIR=/tmp/ak-bp`, replacing `apply_blueprint ...` with
`shell -c "$(cat /tmp/dryrun.py)"`.

Note `_apply_models` rather than the public `validate()`: `validate()` wraps
each call in its own rollback, so file N's objects would be gone before file
N+1 tried to `!Find` them.

## API access

`svc-iac` is a service account in `authentik Admins` with a non-expiring API
token, for inspecting and diffing config without the admin UI.

```bash
TOKEN=$(ssh deploy@foundry sudo cat /var/lib/authentik/secrets/iac-token)
curl -sS -H "Authorization: Bearer $TOKEN" \
  https://auth.datagiant.org/api/v3/core/applications/?superuser_full_list=true
```

The token is generated on the host by `authentik-prepare-secrets`, not kept in
sops, so a full-admin credential never lands in the repo. It is reachable from
the public internet at `auth.datagiant.org/api/v3/`; treat it like a root
password. To rotate: delete the file, restart `authentik-prepare-secrets` and
`authentik-blueprints`.

`superuser_full_list=true` matters. Without it, `core/applications/` returns only
the applications the *token's own account* passes the access policies for, which
silently hides most of them.

## Adding an application

1. Add the group that gates it to `00-groups.yaml`.
2. Add a `NN-<app>.yaml` with the provider, the application, and a
   `authentik_policies.policybinding` tying the group to the application.
3. For a proxy (forward-auth) application, add the provider to
   `90-embedded-outpost.yaml`. **`providers` is a whole-list replacement, not an
   append** — a provider omitted there stops answering `forward_auth`, and its
   site starts 403ing for everyone.
4. Add the Caddy vhost with the `forward_auth` block; see
   `modules/features/sterwerk.nix` for the current example.
5. Dry-run, then deploy.

Populate the new group in the UI — nobody can reach the app until you do.
