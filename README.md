# Atelier — self-hosted

A workspace for documents, databases, tasks and flowcharts. Runs as two containers on any
machine with Docker: the app, and a Postgres to keep it in.

Atelier also exists as a managed package on Salesforce, built from the same source. This is
the other half — same product, its own identity and storage, nothing to do with Salesforce.

---

## Run it

```bash
curl -O https://raw.githubusercontent.com/kloomiyin-inc/atelier-docker/main/docker-compose.yml

# The two secrets it refuses to start without. The password is hex rather than base64
# because it is interpolated into a postgres:// URL, and base64's "/" and "+" corrupt one.
cat > .env <<EOF
SESSION_SECRET=$(openssl rand -base64 48)
POSTGRES_PASSWORD=$(openssl rand -hex 24)
APP_BASE_URL=http://localhost:3000
EOF

docker compose up -d
```

<details>
<summary>Windows, in PowerShell</summary>

```powershell
curl.exe -O https://raw.githubusercontent.com/kloomiyin-inc/atelier-docker/main/docker-compose.yml

# Generated with the cryptographic RNG rather than Get-Random, and written with
# WriteAllText rather than Set-Content: the latter writes CRLF, and a stray carriage
# return inside the password lands in the middle of a postgres:// URL.
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$b = [byte[]]::new(36); $rng.GetBytes($b); $secret = [Convert]::ToBase64String($b)
$b = [byte[]]::new(24); $rng.GetBytes($b); $dbpass = ($b | ForEach-Object { $_.ToString("x2") }) -join ""

[IO.File]::WriteAllText("$PWD\.env", "SESSION_SECRET=$secret`nPOSTGRES_PASSWORD=$dbpass`nAPP_BASE_URL=http://localhost:3000`n")

docker compose up -d
```

</details>

Everything else is optional and documented in
[.env.example](.env.example) — email, the listening address, retention hours.

Open <http://localhost:3000>. **The first account to sign up owns the workspace**, and signup
closes behind it — everybody after that arrives by invitation. There is no seed script and no
default password to change.

Roughly 400 MB pulled, `amd64` and `arm64` both published.

## Before you put it on the internet

The app speaks plain HTTP and authenticates with a cookie. It does not terminate TLS, so
something in front of it must.

```bash
curl -O https://raw.githubusercontent.com/kloomiyin-inc/atelier-docker/main/Caddyfile.example
mv Caddyfile.example Caddyfile          # then edit the hostname
docker compose --profile tls up -d      # Caddy gets a certificate on its own
```

Set `APP_BASE_URL=https://your.host` in `.env` at the same time. It is what goes into
invitation and password-reset links, and a link pointing at `localhost` is useless in
somebody else's inbox.

**Set `SMTP_URL` too, before you invite anyone.** With it unset nothing is emailed at all —
invitations and reset links are written to `docker compose logs app` instead. That is
deliberate, and fine while you are the only person here; the first person you invite simply
never hears from the product. Any provider that speaks SMTP works.

## Configuration

Everything is environment variables; the image holds no configuration of its own.

| Variable                 | Default                  |                                                                        |
| ------------------------ | ------------------------ | ---------------------------------------------------------------------- |
| `SESSION_SECRET`         | —                        | **Required.** Signs session cookies. Rotating it signs everyone out    |
| `POSTGRES_PASSWORD`      | —                        | **Required.** Used between the two containers                          |
| `DATABASE_URL`           | the bundled Postgres     | Point it at a managed database if you would rather not run one         |
| `APP_BASE_URL`           | `http://localhost:3000`  | The address people actually reach. Goes into emailed links             |
| `APP_BIND` / `APP_PORT`  | `127.0.0.1` / `3000`     | Where it listens on the host. Loopback until TLS is in front           |
| `SMTP_URL`               | unset                    | Unset means no mail is sent — links go to the log                      |
| `MAIL_FROM`              | `no-reply@atelier.local` | The from address on invitations and reminders                          |
| `ATELIER_JOB_HOURS`      | `3,7`                    | Hours, UTC, when retention purges and reminders run                    |
| `ATELIER_MAX_BLOB_BYTES` | `26214400`               | Largest single upload. Files live in Postgres, so this sizes your disk |
| `LOG_LEVEL`              | `info`                   |                                                                        |

## Operating it

```bash
docker compose logs -f app                  # logs, including emailed links when SMTP is unset
docker compose exec db psql -U atelier -d atelier

# Back up. Everything is in Postgres — documents, databases, and uploaded files alike —
# so this one file is the whole instance.
docker compose exec -T db pg_dump -U atelier -Fc atelier > atelier-$(date +%F).dump

# Restore into an empty database
docker compose exec -T db pg_restore -U atelier -d atelier --clean --if-exists < atelier-2026-08-25.dump
```

**Upgrading** is editing the version in `docker-compose.yml` and running `docker compose up -d`.
Migrations run at boot, behind an advisory lock, so starting several containers at once is
safe. Take a dump first: migrations move forward only.

**"password authentication failed" on startup?** Postgres reads `POSTGRES_PASSWORD` only
when it first creates its data directory and silently ignores it afterwards — so changing
the password in `.env` on an instance that has already run leaves the database on the old
one, and the app crash-loops with a stack trace that explains none of that. Either put the
original password back, or change it for real:

```bash
docker compose exec db psql -U atelier -d atelier -c "ALTER USER atelier PASSWORD 'the-new-one';"
docker compose up -d
```

**Locked out?** Signup closes after the first account, so a forgotten password with no SMTP
configured has no route back in from the product. The operator CLI is the door:

```bash
docker compose exec app node server/scripts/admin.mjs users
docker compose exec app node server/scripts/admin.mjs set-password you@example.com
docker compose exec app node server/scripts/admin.mjs invite-link you@example.com
```

## What you get

Documents with a block editor — headings, lists, to-dos, callouts, toggles, tables, code,
images, `/` menu, markdown shortcuts, `@` mentions and `[[` page links. Databases with typed
properties, filters, sorts and saved views, shown as a table, board, calendar, timeline,
gallery or list. Tasks with subtasks three deep, repeats, reminders and a personal order.
Flowcharts on a canvas, with swimlanes, auto-layout and SVG/PNG export. Comments, an inbox,
an activity feed, presence, soft locks, search, file attachments, per-page sharing, and a
trash that restores.

## Known limits

Stated plainly, because finding them yourself is worse:

- **No co-editing.** Two people in one document is handled by a soft lock and a conflict
  banner, not by live cursors. Nobody loses work; only one person types at a time.
- **No version history.** The conflict check deliberately keeps no revisions, so there is no
  page timeline to roll back through. Your database dump is the backstop.
- **A document is capped at 131,072 characters** — roughly 5,000 words of prose. Past it the
  editor refuses the save and offers to split the page at a heading.
- **Files live in Postgres**, not in object storage. Simple to back up, and it means uploads
  grow your database rather than a bucket.
- **Email is send-only.** No inbound address, no reply-to-comment.
- Scaling out works — the app keeps nothing on local disk — but the database is the
  bottleneck, and nobody has load-tested this above a small team.

## Licence

Atelier is **not open source.** It is published under the end-user licence agreement in
[EULA.txt](EULA.txt) — read it before you pull — which lets you run any number of instances
for your own organisation and does not let you resell it as a hosted service.

The same text ships inside the image, alongside the licences of everything it redistributes:

```bash
docker compose exec app cat licenses/EULA.txt
docker compose exec app cat licenses/THIRD-PARTY-NOTICES.txt   # 164 components
docker compose exec app ls licenses/fonts/                     # three OFL typefaces
```

The source repository is private. Every image is built by GitHub Actions from a tagged
commit and carries a signed provenance attestation and an SBOM:

```bash
gh attestation verify oci://ghcr.io/kloomiyin-inc/atelier:1.7.0 --owner kloomiyin-inc
docker buildx imagetools inspect ghcr.io/kloomiyin-inc/atelier:1.7.0
```

## Support

No support is promised, and questions are welcome anyway: **ben@kloomiyin.com**, or open an
issue on this repository. Terms other than the EULA — hosting Atelier as a service, or a
source licence — same address.
