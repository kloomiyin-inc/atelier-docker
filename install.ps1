<#
.SYNOPSIS
  Atelier — self-hosted installer for Windows.

.DESCRIPTION
  The PowerShell twin of install.sh, doing the same things in the same order. Download and
  read it before running rather than piping it to a shell — this installs licensed software
  and generates the two secrets your deployment's security rests on.

    curl.exe -fsSL https://raw.githubusercontent.com/kloomiyin-inc/atelier-docker/main/install.ps1 -o install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.PARAMETER Dir
  Where to install. Default: .\atelier

.PARAMETER Yes
  Do not prompt before pulling the image.
#>
[CmdletBinding()]
param(
  [string]$Dir = $(if ($env:ATELIER_DIR) { $env:ATELIER_DIR } else { "atelier" }),
  [string]$Source = $(if ($env:ATELIER_SOURCE) { $env:ATELIER_SOURCE } else { "https://raw.githubusercontent.com/kloomiyin-inc/atelier-docker/main" }),
  [switch]$Yes
)

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 negotiates whatever SecurityProtocol it was configured with, which on
# some machines still excludes TLS 1.2 — and GitHub refuses anything less, so the downloads
# below fail with "the request was aborted: could not create SSL/TLS secure channel" and
# nothing about the actual cause. Harmless on PowerShell 7, where this is already the default.
try {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# Invoke-WebRequest renders a progress bar per chunk in 5.1, which costs more time than the
# download does. Silencing it is the difference between seconds and minutes on a slow link.
$ProgressPreference = "SilentlyContinue"

function Say  { param($m) Write-Host "  $m" }
function Head { param($m) Write-Host ""; Write-Host $m }
function Die  { param($m) Write-Host ""; Write-Host "Error: $m" -ForegroundColor Red; Write-Host ""; exit 1 }

# ------------------------------------------------------------------ preflight --

Head "Checking Docker"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Die "Docker is not installed. Get Docker Desktop: https://docs.docker.com/desktop/"
}

# The binary existing and the daemon running are different things, and the second is the one
# people actually hit — Docker Desktop not started yet is the commonest first failure.
& docker info *> $null
if ($LASTEXITCODE -ne 0) {
  Die "Docker is installed but not running. Start Docker Desktop and run this again."
}

# Compose v2 is a docker subcommand; v1 was a separate binary and is end of life. This
# compose file uses `name:` and profiles, which v1 does not understand.
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
  Die "Docker Compose v2 is missing. It ships with Docker Desktop — update it."
}

Say "Docker is running, Compose v2 present."

# ------------------------------------------------------------------- the files --

Head "Installing into $Dir"
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Set-Location $Dir

function Fetch { param($Name, $To) Invoke-WebRequest -Uri "$Source/$Name" -OutFile $To -UseBasicParsing }

if (Test-Path docker-compose.yml) {
  Say "docker-compose.yml is already here — keeping it."
  Say "(Upgrading? Edit the image tag in it, then: docker compose up -d)"
} else {
  Fetch "docker-compose.yml" "docker-compose.yml"
  Say "Fetched docker-compose.yml"
}
if (-not (Test-Path .env.example)) {
  try { Fetch ".env.example" ".env.example" } catch { }
}

# ---------------------------------------------------------------- the secrets --

Head "Secrets"

# The volume compose will attach, if it is already there. The project name comes from `name:`
# in the compose file, which COMPOSE_PROJECT_NAME overrides if it is set.
$project  = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { "atelier" }
$pgvolume = "${project}_pgdata"

& docker volume inspect $pgvolume *> $null
$volumeExists = ($LASTEXITCODE -eq 0)

if ((-not (Test-Path .env)) -and $volumeExists) {
  # Generating a password here would produce exactly the failure the README documents, and
  # the error it produces names none of this: Postgres reads POSTGRES_PASSWORD only when it
  # first creates its data directory, so an existing volume keeps the password it was born
  # with and the app crash-loops on "password authentication failed for user atelier".
  Die @"
There is already a database volume ($pgvolume) but no .env to open it with.

  A fresh .env would generate a new password, and the existing database would keep the old
  one — the app would then crash-loop on 'password authentication failed'. Pick one:

    Restore the .env you had           (its POSTGRES_PASSWORD matches that volume)
    Start over, destroying that data   docker volume rm $pgvolume
    Keep the data, new password        docker compose up -d db
                                       docker compose exec db psql -U atelier -d atelier ``
                                         -c "ALTER USER atelier PASSWORD 'new-one';"
                                       then put that password in .env

  If that volume belongs to something else of yours, install into a different Compose
  project instead:  `$env:COMPOSE_PROJECT_NAME='atelier2'
"@
}

if (Test-Path .env) {
  # Existing .env always wins — see the note above. Its secrets belong to the database that
  # is already on disk, and replacing them locks the app out of it.
  Say ".env already exists — leaving it untouched."
  Say "Its secrets belong to the database that is already here; regenerating them would"
  Say "lock the app out of it. Delete the volume too if you really want to start over."
} else {
  # The cryptographic RNG rather than Get-Random, which is not seeded for this.
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

  $b = [byte[]]::new(36); $rng.GetBytes($b)
  $secret = [Convert]::ToBase64String($b)

  # Hex rather than base64: this value is interpolated into a postgres:// URL, and base64's
  # "/" and "+" corrupt one.
  $b = [byte[]]::new(24); $rng.GetBytes($b)
  $dbpass = ($b | ForEach-Object { $_.ToString("x2") }) -join ""

  $baseUrl = if ($env:ATELIER_BASE_URL) { $env:ATELIER_BASE_URL } else { "http://localhost:3000" }

  # WriteAllText rather than Set-Content: the latter writes CRLF, and a stray carriage return
  # inside a secret lands in the middle of a postgres:// URL and in a cookie signing key.
  [IO.File]::WriteAllText(
    (Join-Path $PWD ".env"),
    "SESSION_SECRET=$secret`nPOSTGRES_PASSWORD=$dbpass`nAPP_BASE_URL=$baseUrl`n"
  )
  Say "Wrote .env with freshly generated secrets."
  Say "Back it up: without SESSION_SECRET everyone is signed out, and without"
  Say "POSTGRES_PASSWORD the database in the volume cannot be opened."
}

# ------------------------------------------------------------------- the pull --

Head "Licence"
Say "Atelier is not open source. It is published under an end-user licence agreement"
Say "that permits running any number of instances for your own organisation, and does"
Say "not permit reselling it as a hosted service."
Say "  $Source/EULA.txt"

if (-not $Yes) {
  $reply = Read-Host "`n  Pull the image and start? [y/N]"
  if ($reply -notmatch '^(y|yes)$') {
    Write-Host "`n  Stopped. Nothing was pulled. Run again, or: docker compose up -d`n"
    exit 0
  }
}

Head "Starting (about 400 MB on first pull)"
& docker compose pull
if ($LASTEXITCODE -ne 0) { Die "The image could not be pulled." }
& docker compose up -d
if ($LASTEXITCODE -ne 0) { Die "Compose could not start the containers." }

# --------------------------------------------------------------------- health --

Head "Waiting for it to come up"

# The app migrates its database at boot, so a first start is legitimately slower than a
# restart. Ninety seconds, then show the logs rather than a bare failure.
$url = "http://localhost:3000"
if (Test-Path .env) {
  $line = Select-String -Path .env -Pattern '^APP_BASE_URL=' -ErrorAction SilentlyContinue
  if ($line) { $url = ($line.Line -split '=', 2)[1] }
}

$ok = $false
for ($i = 0; $i -lt 45; $i++) {
  try {
    Invoke-WebRequest -Uri "$url/healthz" -UseBasicParsing -TimeoutSec 3 | Out-Null
    $ok = $true; break
  } catch { Start-Sleep -Seconds 2 }
}

if (-not $ok) {
  # Name the one failure whose message explains nothing. Everything else gets its log.
  $logs = (& docker compose logs app 2>&1) -join "`n"
  if ($logs -match 'password authentication failed') {
    Die @"
The database rejected the app's password.

  The volume $pgvolume was created with a different POSTGRES_PASSWORD than the one in .env
  now. Postgres only reads that variable when it first creates its data directory, so
  editing .env afterwards changes what the app sends and nothing about what the database
  expects. Either restore the old .env, or change it for real:

    docker compose exec db psql -U atelier -d atelier -c "ALTER USER atelier PASSWORD '<the one in .env>';"
    docker compose up -d
"@
  }
  Write-Host "`n  It did not answer on $url within 90 seconds. The last of its log:`n"
  & docker compose logs --tail 40 app
  Die "Not healthy yet. ``docker compose logs -f app`` will show what it is waiting for."
}

# ---------------------------------------------------------------------- done --

Write-Host @"

  Atelier is running.

  Open       $url
             The first account to sign up owns the workspace, and signup closes
             behind it. Everybody after that arrives by invitation.

  Next       Set SMTP_URL in .env before you invite anyone — with it unset, no mail
             is sent at all and invitation links go to the log instead.
             Put TLS in front before exposing it: see the README's Caddy profile.

  Agents     Atelier speaks MCP at $url/mcp. Mint a token for your account:

               cd $Dir
               docker compose exec app node server/scripts/admin.mjs token create you@example.com "claude"

  Operate    docker compose logs -f app
             docker compose exec app node server/scripts/admin.mjs users
             docker compose down          # stop;  add -v to destroy the data

"@
