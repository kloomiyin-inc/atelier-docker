#!/bin/sh
# Atelier — self-hosted installer for Linux and macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/kloomiyin-inc/atelier-docker/main/install.sh -o install.sh
#   sh install.sh
#
# It does exactly what the README's manual steps do, in the same order, with the checks a
# person doing it by hand would skip. Download and read it before running rather than piping
# it to a shell — this installs licensed software and generates the two secrets your
# deployment's security rests on.
#
# POSIX sh on purpose: /bin/sh is dash on Debian and Ubuntu, and macOS ships bash 3.2.
# Nothing here needs more than that.

set -eu

SOURCE="${ATELIER_SOURCE:-https://raw.githubusercontent.com/kloomiyin-inc/atelier-docker/main}"
DIR="${ATELIER_DIR:-atelier}"
ASSUME_YES="${ATELIER_YES:-0}"

usage() {
  cat <<USAGE
Atelier installer

  sh install.sh [--dir <path>] [--yes]

  --dir <path>   where to install (default: ./atelier)
  --yes          do not prompt before pulling the image
  --help

Environment: ATELIER_SOURCE, ATELIER_DIR, ATELIER_YES
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:?--dir needs a path}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
head_() { printf '\n%s\n' "$*"; }
die()  { printf '\nError: %s\n\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ preflight --

head_ "Checking Docker"

command -v docker >/dev/null 2>&1 || die \
"Docker is not installed.
  macOS / Windows:  https://docs.docker.com/desktop/
  Linux:            https://docs.docker.com/engine/install/"

# The binary existing and the daemon running are different things, and the second is the
# one people actually hit — Docker Desktop not started yet is the commonest first failure.
docker info >/dev/null 2>&1 || die \
"Docker is installed but not running. Start Docker Desktop (or: sudo systemctl start docker)
  and run this again."

# Compose v2 is a docker subcommand; v1 was a separate `docker-compose` binary and is end of
# life. This compose file uses \`name:\` and profiles, which v1 does not understand — so
# check for the subcommand rather than accepting either and failing later in a confusing way.
docker compose version >/dev/null 2>&1 || die \
"Docker Compose v2 is missing. It ships with Docker Desktop; on Linux install the
  docker-compose-plugin package. (The old \`docker-compose\` script is not enough.)"

say "Docker is running, Compose v2 present."

# ------------------------------------------------------------------- the files --

head_ "Installing into $DIR"
mkdir -p "$DIR"
cd "$DIR"

fetch() {
  # $1 remote name, $2 local name
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$SOURCE/$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$SOURCE/$1"
  else
    die "Neither curl nor wget is available to download $1."
  fi
}

if [ -f docker-compose.yml ]; then
  say "docker-compose.yml is already here — keeping it."
  say "(Upgrading? Edit the image tag in it, then: docker compose up -d)"
else
  fetch docker-compose.yml docker-compose.yml
  say "Fetched docker-compose.yml"
fi

[ -f .env.example ] || { fetch .env.example .env.example 2>/dev/null || true; }

# ---------------------------------------------------------------- the secrets --

# Hex rather than base64 for the database password: it is interpolated into a postgres://
# URL, and base64's "/" and "+" corrupt one.
random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  elif [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    od -An -vtx1 -N"$1" /dev/urandom | tr -d ' \n'
  else
    die "No source of randomness found (needs openssl, or /dev/urandom with od)."
  fi
}

random_b64() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$1"
  elif [ -r /dev/urandom ] && command -v base64 >/dev/null 2>&1; then
    dd if=/dev/urandom bs="$1" count=1 2>/dev/null | base64 | tr -d '\n'
  else
    die "No source of randomness found (needs openssl, or /dev/urandom with base64)."
  fi
}

head_ "Secrets"

# The volume compose will attach, if it is already there. The project name comes from `name:`
# in the compose file, which COMPOSE_PROJECT_NAME overrides if it is set.
pgvolume="${COMPOSE_PROJECT_NAME:-atelier}_pgdata"

if [ ! -f .env ] && docker volume inspect "$pgvolume" >/dev/null 2>&1; then
  # Generating a password here would produce exactly the failure the README documents, and
  # the error it produces names none of this: Postgres reads POSTGRES_PASSWORD only when it
  # first creates its data directory, so an existing volume keeps the password it was born
  # with and the app crash-loops on "password authentication failed for user atelier".
  # Caught here rather than diagnosed afterwards, because at this point nothing is broken yet.
  die "There is already a database volume ($pgvolume) but no .env to open it with.

  A fresh .env would generate a new password, and the existing database would keep the old
  one — the app would then crash-loop on 'password authentication failed'. Pick one:

    Restore the .env you had              (its POSTGRES_PASSWORD matches that volume)

    Start over, destroying that data      docker volume rm $pgvolume

    Keep the data, set a new password     docker compose up -d db
                                          docker compose exec db psql -U atelier -d atelier \\
                                            -c \"ALTER USER atelier PASSWORD 'new-one';\"
                                          then put that password in .env

  If that volume belongs to something else of yours, install into a different Compose
  project instead:  COMPOSE_PROJECT_NAME=atelier2 sh install.sh"
fi

if [ -f .env ]; then
  # The single most destructive thing this script could do. Postgres reads POSTGRES_PASSWORD
  # only when it first creates its data directory and ignores it ever after, so writing a
  # fresh one over an existing instance leaves the database on the old password and the app
  # crash-looping against it — with a stack trace that explains none of that. Regenerating
  # SESSION_SECRET is milder and still signs everybody out. Existing .env always wins.
  say ".env already exists — leaving it untouched."
  say "Its secrets belong to the database that is already here; regenerating them would"
  say "lock the app out of it. Delete the volume too if you really want to start over."
else
  umask 077   # the file is about to hold both secrets
  {
    printf 'SESSION_SECRET=%s\n' "$(random_b64 36)"
    printf 'POSTGRES_PASSWORD=%s\n' "$(random_hex 24)"
    printf 'APP_BASE_URL=%s\n' "${ATELIER_BASE_URL:-http://localhost:3000}"
  } > .env
  say "Wrote .env with freshly generated secrets (mode 600)."
  say "Back it up: without SESSION_SECRET everyone is signed out, and without"
  say "POSTGRES_PASSWORD the database in the volume cannot be opened."
fi

# ------------------------------------------------------------------- the pull --

head_ "Licence"
say "Atelier is not open source. It is published under an end-user licence agreement"
say "that permits running any number of instances for your own organisation, and does"
say "not permit reselling it as a hosted service."
say "  $SOURCE/EULA.txt"

if [ "$ASSUME_YES" != "1" ]; then
  # Read from the terminal rather than stdin, so this still asks when the script itself
  # arrived on stdin. With no terminal at all — CI, a Dockerfile, `sh install.sh </dev/null`
  # — say so and stop, rather than defaulting either way: consenting on somebody's behalf is
  # wrong, and a bare "declined" reads as a bug.
  if [ ! -r /dev/tty ]; then
    printf '\n  No terminal to ask on. Re-run with --yes to accept and continue:\n'
    printf '    sh install.sh --dir %s --yes\n\n' "$DIR"
    exit 0
  fi
  printf '\n  Pull the image and start? [y/N] '
  read -r reply </dev/tty || reply=n
  case "$reply" in
    y|Y|yes|YES) ;;
    *) printf '\n  Stopped. Nothing was pulled. Run again, or: docker compose up -d\n\n'; exit 0 ;;
  esac
fi

head_ "Starting (about 400 MB on first pull)"
docker compose pull
docker compose up -d

# --------------------------------------------------------------------- health --

head_ "Waiting for it to come up"

# The app migrates its database at boot, so a first start is legitimately slower than a
# restart. Ninety seconds, then show the logs rather than a bare failure — the answer is
# almost always in them.
url="$(grep '^APP_BASE_URL=' .env | cut -d= -f2- || true)"
[ -n "$url" ] || url="http://localhost:3000"

i=0
ok=0
while [ "$i" -lt 45 ]; do
  if curl -fsS "$url/healthz" >/dev/null 2>&1; then ok=1; break; fi
  i=$((i + 1))
  sleep 2
done

if [ "$ok" != "1" ]; then
  # Name the one failure whose message explains nothing. Everything else gets its log.
  if docker compose logs app 2>/dev/null | grep -q 'password authentication failed'; then
    printf '\n'
    docker compose logs --tail 5 app 2>/dev/null | tail -3
    die "The database rejected the app's password.

  The volume $pgvolume was created with a different POSTGRES_PASSWORD than the one in
  .env now. Postgres only reads that variable when it first creates its data directory, so
  editing .env afterwards changes what the app sends and nothing about what the database
  expects. Either restore the old .env, or change it for real:

    docker compose exec db psql -U atelier -d atelier \\
      -c \"ALTER USER atelier PASSWORD '\$(grep ^POSTGRES_PASSWORD= .env | cut -d= -f2-)';\"
    docker compose up -d"
  fi

  printf '\n  It did not answer on %s within 90 seconds. The last of its log:\n\n' "$url"
  docker compose logs --tail 40 app || true
  die "Not healthy yet. \`docker compose logs -f app\` will show what it is waiting for."
fi

# ---------------------------------------------------------------------- done --

cat <<DONE

  Atelier is running.

  Open       $url
             The first account to sign up owns the workspace, and signup closes
             behind it. Everybody after that arrives by invitation.

  Next       Set SMTP_URL in .env before you invite anyone — with it unset, no mail
             is sent at all and invitation links go to the log instead.
             Put TLS in front before exposing it: see the README's Caddy profile.

  Agents     Atelier speaks MCP at $url/mcp. Mint a token for your account:

               cd $DIR
               docker compose exec app node server/scripts/admin.mjs token create you@example.com "claude"

  Operate    docker compose logs -f app
             docker compose exec app node server/scripts/admin.mjs users
             docker compose down          # stop;  add -v to destroy the data

DONE
