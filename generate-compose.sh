#!/usr/bin/env bash
# generate-compose.sh — Generate compose.yml + Caddyfile from helmfile templates
#
# First run:  interactive setup (domain, voice, data root, secrets)
# Next runs:  re-renders helmfile templates + regenerates compose
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Reuse helpers from init.sh (generate_seed, generate_vapid, generate_files_key, derive_secret, read_seed)
source "$SCRIPT_DIR/init.sh"

TEMPLATE_CHECK=true
for arg in "$@"; do
    [[ "$arg" == "--no-template-check" ]] && TEMPLATE_CHECK=false
done

# Warn if a generated file has drifted from its template (line count comparison)
check_template_drift() {
    local generated="$1" template="$2"
    [[ "$TEMPLATE_CHECK" == false ]] && return
    [[ ! -f "$generated" || ! -f "$template" ]] && return
    local gen_lines tpl_lines
    gen_lines=$(wc -l < "$generated")
    tpl_lines=$(wc -l < "$template")
    if [[ "$gen_lines" -ne "$tpl_lines" ]]; then
        echo ""
        echo "⚠ Template drift: $generated ($gen_lines lines) differs from $template ($tpl_lines lines)."
        echo "  The template may have new options since you generated your file."
        echo "  Compare them:  diff $generated $template"
        echo "  Use --no-template-check to suppress this warning."
        read -rp "  Press Enter to continue..."
        echo ""
    fi
}

H2C_MANAGER_URL="https://raw.githubusercontent.com/helmfile2compose/h2c-manager/main/h2c-manager.py"
H2C_MANAGER="$(mktemp /tmp/h2c-manager.XXXXXX.py)"

# ---------------------------------------------------------------------------
# Download h2c-manager
# ---------------------------------------------------------------------------

echo "Downloading h2c-manager..."
curl -fsSL "$H2C_MANAGER_URL" -o "$H2C_MANAGER"
trap 'rm -f "$H2C_MANAGER"' EXIT

# ---------------------------------------------------------------------------
# Setup: environments/compose.yaml (domain, voice, secrets)
# ---------------------------------------------------------------------------

if [[ ! -f environments/compose.yaml ]]; then
    echo ""
    echo "=== Stoat Compose Setup ==="
    echo ""

    # -- Domain --
    read -rp "Domain [stoatchat.local]: " DOMAIN
    DOMAIN="${DOMAIN:-stoatchat.local}"

    # -- Voice --
    read -rp "Enable voice/video calls (LiveKit)? [y/N]: " VOICE
    VOICE="${VOICE:-n}"
    VOICE="${VOICE,,}"

    # -- Video (only if voice enabled) --
    VIDEO_ENABLED="false"
    if [[ "$VOICE" == "y" ]]; then
        read -rp "Enable experimental video/screenshare support? [y/N]: " VIDEO
        VIDEO="${VIDEO:-n}"
        VIDEO="${VIDEO,,}"
        VIDEO_ENABLED=$( [[ "$VIDEO" == "y" ]] && echo "true" || echo "false" )
    fi

    # -- Create environments/compose.yaml from example --
    echo "Creating environments/compose.yaml..."
    SEED="$(generate_seed)"
    VOICE_ENABLED=$( [[ "$VOICE" == "y" ]] && echo "true" || echo "false" )
    sed -e "s|__DOMAIN__|${DOMAIN}|g" \
        -e "s|__SECRET_SEED__|${SEED}|" \
        -e "s|__VOICE_ENABLED__|${VOICE_ENABLED}|g" \
        -e "s|__VIDEO_ENABLED__|${VIDEO_ENABLED}|g" \
        environments/compose.yaml.example > environments/compose.yaml

    echo "  domain:     ${DOMAIN}"
    echo "  secretSeed: ${SEED:0:8}..."
    echo "  voice:      ${VOICE_ENABLED}"
    echo "  video:      ${VIDEO_ENABLED}"

    # -- Non-derivable secrets --
    generate_vapid
    generate_files_key

    echo ""
else
    check_template_drift environments/compose.yaml environments/compose.yaml.example
fi

# ---------------------------------------------------------------------------
# Setup: helmfile2compose.yaml (data root, caddy email)
# ---------------------------------------------------------------------------

if [[ ! -f helmfile2compose.yaml ]]; then
    # -- Data root --
    DEFAULT_DATA="${HOME}/stoat-data"
    read -rp "Data directory [${DEFAULT_DATA}]: " DATA_ROOT
    DATA_ROOT="${DATA_ROOT:-${DEFAULT_DATA}}"

    # -- Email for Let's Encrypt (real domains only) --
    # Caddy uses its internal CA for .local and localhost — no ACME, no email needed
    DOMAIN=$(grep '^domain:' environments/compose.yaml | awk '{print $2}')
    CADDY_EMAIL=""
    if [[ "$DOMAIN" != *.local && "$DOMAIN" != localhost ]]; then
        read -rp "Email for Let's Encrypt certificates: " CADDY_EMAIL
    fi

    # -- Generate from template --
    sed -e "s|__VOLUME_ROOT__|${DATA_ROOT}|" \
        -e "s|__CADDY_EMAIL__|${CADDY_EMAIL}|" \
        helmfile2compose.yaml.template > helmfile2compose.yaml
    # Remove caddy_email line if no email was set
    [[ -z "$CADDY_EMAIL" ]] && sed -i '' '/^caddy_email: ""$/d' helmfile2compose.yaml

    # -- Data directories --
    mkdir -p "${DATA_ROOT}"/{mongodb,redis,rabbitmq,minio}

    echo ""
else
    check_template_drift helmfile2compose.yaml helmfile2compose.yaml.template
fi

# ---------------------------------------------------------------------------
# Generate compose.yml + Caddyfile (via h2c-manager)
# ---------------------------------------------------------------------------

rm -rf configmaps/ secrets/
python3 "$H2C_MANAGER" run -e compose

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

SEED=$(read_seed environments/compose.yaml)
DOMAIN=$(grep '^domain:' environments/compose.yaml | awk '{print $2}')

echo ""
echo "=== Done ==="
echo ""
echo "Make sure DNS resolves to the host running compose:"
echo "  ${DOMAIN}"
echo "  (for local testing: 127.0.0.1 in /etc/hosts)"
echo ""
echo "Credentials (derived from secretSeed):"
echo "  MongoDB:  stoatchat / $(derive_secret "$SEED" "mongo-user")"
echo "  RabbitMQ: stoatchat / $(derive_secret "$SEED" "rabbit-user")"
echo "  MinIO:    $(derive_secret "$SEED" "s3-access") / $(derive_secret "$SEED" "s3-secret")"
echo ""
echo "Start:  docker compose up -d"
echo "Regen:  ./generate-compose.sh"
