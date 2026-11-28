# Hosting a Galley server

A Galley server for reviewers who are not at your machine. It is the server `galley host` runs,
written out by `galley bundle` and set by its environment (DESIGN D18). This page hosts it on
Fly.io. Any host that runs a container with a disk that persists will do; the settings below are
the same.

Hosting costs money and mails real people: both are the owner's to decide.

## What you need

- A Fly.io account, and `flyctl` signed in to it.
- An SMTP relay that will send from an address you own (a transactional mail provider). Fly.io
  does not send mail. Without a relay, nobody can sign in: the codes are mailed.
- The app's checkout with `galley_cli` in its dev dependencies (README).

## 1. Write the bundle

```sh
dart run galley_cli:galley bundle ../galley-server     # linux_amd64; --platform linux_arm64
```

The directory must be new or empty. It holds PocketBase (the pinned release, checked), the
validator compiled for Linux from the source this CLI judges by, the schema and hooks, the
canvas as `public/`, `run`, a `Dockerfile` and `bundle.json`. The canvas is the pinned
release's, or `--web <dir>`; with neither, `bundle` refuses, since a reviewer's link would open
nothing.

## 2. Add a fly.toml

Write this beside the bundle's Dockerfile, as `fly.toml`. `flyctl` reads `fly.toml` from the
directory it is run in.

```toml
app = "my-galley"              # yours: fly apps create picks it
primary_region = "iad"         # near your reviewers

[env]
  GALLEY_URL = "https://my-galley.fly.dev"
  GALLEY_PROXY_HEADER = "Fly-Client-IP"
  GALLEY_OWNERS = "you@example.com"
  GALLEY_SMTP_HOST = "smtp.example.com"
  GALLEY_SMTP_PORT = "587"
  GALLEY_SMTP_USERNAME = "galley"
  GALLEY_MAIL_FROM = "galley@example.com"
  GALLEY_MAIL_NAME = "Galley"

[mounts]
  source = "galley_data"
  destination = "/data"

[http_service]
  internal_port = 8080
  force_https = true
  # One machine, always running: its data is on one volume, and a stopped machine makes the
  # first reviewer wait for it to start.
  auto_stop_machines = "off"
  auto_start_machines = true
  min_machines_running = 1

  [[http_service.checks]]
    grace_period = "10s"
    interval = "30s"
    method = "GET"
    timeout = "5s"
    path = "/api/health"
```

The password is a secret, not an `[env]` line: step 3.

What each setting does:

| Variable | What it is |
|---|---|
| `GALLEY_URL` | The address reviewers open. It is in every mail and link. |
| `GALLEY_OWNERS` | Emails, comma-separated, that may sign in without an invite. |
| `GALLEY_SMTP_HOST`, `_PORT` | The relay. The port is 587 by default. |
| `GALLEY_SMTP_TLS` | `true` for TLS from the first byte (port 465). Otherwise the relay must offer STARTTLS, or the password is not sent. |
| `GALLEY_SMTP_USERNAME`, `_PASSWORD` | Set together, or neither. |
| `GALLEY_MAIL_FROM`, `_NAME` | The sender. The address is required with a relay. |
| `GALLEY_PROXY_HEADER` | The header the proxy names the client in (below). |
| `GALLEY_DATA`, `GALLEY_HTTP` | Where the data is kept (`/data` in the image), and what to listen on (`0.0.0.0:8080`). |

A setting the server cannot read stops it, naming the setting, in `fly logs`. A setting left out
is left as it was, so to undo one, set it to what it should be.

**`GALLEY_PROXY_HEADER` only behind a proxy that sets that header.** Sign-in is rate limited per
client. Behind Fly's proxy every request comes from the proxy, so without the header all
reviewers share one limit, and one guesser locks everyone out. Fly's proxy names the client in
`Fly-Client-IP` (docs.fly.io/networking/request-headers). Not in `X-Forwarded-For`: its rightmost
address is Fly's own, and the rest are whatever the client sent. On a machine reached directly,
leave the header unset: a client would name any address it liked.

## 3. Create it

From the bundle's directory:

```sh
fly apps create my-galley
fly volumes create galley_data --size 1 --region iad
fly secrets set GALLEY_SMTP_PASSWORD='…'
fly deploy --ha=false --remote-only
```

`--remote-only` builds the image on Fly's builder, so no Docker is needed here. `--ha=false`
makes one machine. Two would each have a volume, and each its own galleys.

## 4. Check it

```sh
curl -fsS https://my-galley.fly.dev/api/health
dart run galley_cli:galley login https://my-galley.fly.dev --email you@example.com
dart run galley_cli:galley link https://my-galley.fly.dev --create 'My app' --alias Me
dart run galley_cli:galley push
dart run galley_cli:galley invite reviewer@example.com
```

The code arrives by mail. If none does, `fly logs` says why the relay refused it. `link` and
`invite` print the canvas's link for reviewers.

Check that the client header cannot be forged. Send a request that names another client, and
see that the server limits you anyway:

```sh
for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -w '%{http_code} ' -H 'Fly-Client-IP: 203.0.113.9' \
    -H 'Content-Type: application/json' -d '{"otpId":"x","password":"0"}' \
    https://my-galley.fly.dev/api/collections/users/auth-with-otp
done
```

Then run it again with another made-up address. If the second run is limited at once, the proxy
replaced the header, as it should. If it starts afresh, the client's own header got through:
unset `GALLEY_PROXY_HEADER` and say so in this repo's issues. Fly's docs do not say which.

## Updating

Write a new bundle into a new directory with the new release, copy `fly.toml` in, and run
`fly deploy --ha=false --remote-only` from there. The data is on the volume and stays. The
schema migrates on start.

## The dashboard

PocketBase's dashboard is at `/_/`, guarded by a superuser's password. The bundle makes no
superuser, so nobody can sign in to it. When you need one, to free a stuck round for example:

```sh
fly ssh console -C '/galley/pocketbase superuser upsert you@example.com <password> --dir=/data/pb_data --migrationsDir=/galley/schema/pb_migrations --hooksDir=/galley/schema/pb_hooks'
```

## What is not done

- The Dockerfile's base image is not pinned by digest.
- A bundle for arm64 is written but has not been run.
- Backups are Fly's daily snapshots of the volume, and nothing else.
- The dashboard cannot be turned off.
- Any invited user can create a galley of their own on the server.
