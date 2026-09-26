#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="sshturbo/online-gateway"
VERSION="${1:-latest}"
ARCH=$(uname -m)

APP_ROOT="/opt/online-service"
RELEASES_DIR="$APP_ROOT/releases"
CURRENT_LINK="$APP_ROOT/current"
CONFIG_DIR="/etc/online-service"
CONFIG_FILE="$CONFIG_DIR/.env"
LEGACY_CONFIG_FILE="$CONFIG_DIR/online-service.env"
STATE_DIR="/var/lib/online-service"
LOG_DIR="/var/log/online-service"
UNIT_FILE="/etc/systemd/system/online-gateway.service"

die() {
    printf 'Erro: %s\n' "$*" >&2
    exit 1
}

print_centered() {
    printf '\e[33m%s\e[0m\n' "$1"
}

[[ $EUID -eq 0 ]] || die 'execute este script como root (ex.: sudo bash install-module.sh)'
command -v systemctl >/dev/null 2>&1 || die 'systemd/systemctl não encontrado'
[[ $VERSION == latest || $VERSION =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "versão inválida: $VERSION"

case "$ARCH" in
    x86_64)
        GOARCH=amd64
        ;;
    aarch64)
        GOARCH=arm64
        ;;
    *)
        die "arquitetura não suportada: $ARCH"
        ;;
esac

install_missing_dependencies() {
    local missing=()
    command -v unzip >/dev/null 2>&1 || missing+=(unzip)
    command -v wget >/dev/null 2>&1 || missing+=(wget)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    ((${#missing[@]} == 0)) && return

    command -v apt-get >/dev/null 2>&1 || die "instale manualmente as dependências: ${missing[*]}"
    apt-get update
    apt-get install -y --no-install-recommends "${missing[@]}"
}

install_missing_dependencies

TMP_DIR=$(mktemp -d)
cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

if [[ $VERSION == latest ]]; then
    RELEASE_URL="https://github.com/$REPOSITORY/releases/latest/download"
else
    RELEASE_URL="https://github.com/$REPOSITORY/releases/download/$VERSION"
fi

case "$ARCH" in
    x86_64)
        ASSET_NAMES=("online-gateway-linux-$GOARCH.zip" "online-gateway-linux-$ARCH.zip" "online-gateway-$ARCH.zip" "online-gateway.zip")
        ;;
    aarch64)
        ASSET_NAMES=("online-gateway-linux-$GOARCH.zip" "online-gateway-linux-$ARCH.zip" "online-gateway-$ARCH.zip" "online-gateway.zip")
        ;;
esac
if [[ -n ${ONLINE_GATEWAY_ASSET_NAME:-} ]]; then
    ASSET_NAMES=("$ONLINE_GATEWAY_ASSET_NAME")
fi

ARCHIVE="$TMP_DIR/online-gateway.zip"
DOWNLOADED_ASSET=""
for asset in "${ASSET_NAMES[@]}"; do
    if wget --timeout=30 --tries=2 -q -O "$ARCHIVE" "$RELEASE_URL/$asset"; then
        DOWNLOADED_ASSET=$asset
        break
    fi
done
[[ -n $DOWNLOADED_ASSET ]] || die "não foi possível baixar um ZIP do release $VERSION de $REPOSITORY"

print_centered "Baixando $DOWNLOADED_ASSET de $REPOSITORY ($VERSION, $ARCH)..."
mkdir -p "$TMP_DIR/unpacked"
unzip -q "$ARCHIVE" -d "$TMP_DIR/unpacked" || die 'não foi possível descompactar o pacote baixado'

BINARY_SOURCE=$(find "$TMP_DIR/unpacked" -type f -name online-gateway -print -quit)
[[ -n $BINARY_SOURCE ]] || die 'o ZIP não contém o executável online-gateway'

find_in_archive() {
    find "$TMP_DIR/unpacked" -type f -name "$1" -print -quit
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENV_EXAMPLE=$(find_in_archive .env.example)
if [[ -z $ENV_EXAMPLE && -f $SCRIPT_DIR/.env.example ]]; then
    ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
fi
[[ -n $ENV_EXAMPLE ]] || die 'não encontrei .env.example no ZIP nem ao lado deste script'

SERVICE_SOURCE=$(find_in_archive online-gateway.service)
if [[ -z $SERVICE_SOURCE && -f $SCRIPT_DIR/online-gateway.service ]]; then
    SERVICE_SOURCE="$SCRIPT_DIR/online-gateway.service"
fi
if [[ -z $SERVICE_SOURCE && -f $SCRIPT_DIR/../deploy/online-gateway.service ]]; then
    SERVICE_SOURCE="$SCRIPT_DIR/../deploy/online-gateway.service"
fi
[[ -n $SERVICE_SOURCE ]] || die 'não encontrei online-gateway.service no ZIP nem ao lado deste script'

PREVIOUS_TARGET=""
if [[ -e $CURRENT_LINK && ! -L $CURRENT_LINK ]]; then
    die "$CURRENT_LINK existe e não é um link simbólico; preserve a instalação atual e resolva o caminho antes de continuar"
fi
if [[ -L $CURRENT_LINK ]]; then
    CURRENT_TARGET=$(readlink -f -- "$CURRENT_LINK")
    case "$CURRENT_TARGET" in
        "$RELEASES_DIR"/*) ;;
        *) die "o destino atual de $CURRENT_LINK está fora de $RELEASES_DIR" ;;
    esac
    PREVIOUS_TARGET=$CURRENT_TARGET
fi

if ! getent group online-service >/dev/null 2>&1; then
    groupadd --system online-service
fi
if ! getent passwd online-service >/dev/null 2>&1; then
    useradd --system --gid online-service --home-dir /nonexistent \
        --shell /usr/sbin/nologin --no-create-home online-service
fi

install -d -o root -g root -m 0755 "$APP_ROOT" "$RELEASES_DIR" "$CONFIG_DIR"
install -d -o online-service -g online-service -m 0700 "$STATE_DIR"
install -d -o online-service -g online-service -m 0750 "$LOG_DIR"

if [[ ! -e $CONFIG_FILE ]]; then
    if [[ -f $LEGACY_CONFIG_FILE ]]; then
        install -o root -g root -m 0600 "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"
    else
        install -o root -g root -m 0600 "$ENV_EXAMPLE" "$CONFIG_FILE"
    fi
fi
[[ -f $CONFIG_FILE && ! -L $CONFIG_FILE ]] || die "$CONFIG_FILE precisa ser um arquivo regular, sem link simbólico"

encryption_key=$(sed -n 's/^ONLINE_REGISTRY_ENCRYPTION_KEY=//p' "$CONFIG_FILE" | head -n 1 | tr -d '\r')
if [[ -z $encryption_key ]]; then
    encryption_key=$(openssl rand -base64 32 | tr -d '\r\n') || die 'não foi possível gerar ONLINE_REGISTRY_ENCRYPTION_KEY'
    [[ $encryption_key =~ ^[A-Za-z0-9+/]{43}=?$ ]] || die 'a chave gerada para ONLINE_REGISTRY_ENCRYPTION_KEY é inválida'
    if grep -q '^ONLINE_REGISTRY_ENCRYPTION_KEY=' "$CONFIG_FILE"; then
        sed -i "s|^ONLINE_REGISTRY_ENCRYPTION_KEY=.*|ONLINE_REGISTRY_ENCRYPTION_KEY=$encryption_key|" "$CONFIG_FILE"
    else
        printf '\nONLINE_REGISTRY_ENCRYPTION_KEY=%s\n' "$encryption_key" >>"$CONFIG_FILE"
    fi
fi
[[ $encryption_key =~ ^[A-Za-z0-9+/]{43}=?$ ]] || die "ONLINE_REGISTRY_ENCRYPTION_KEY inválida em $CONFIG_FILE; recupere a chave original ou gere uma somente para uma instalação nova"
chown root:root "$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"

release_name="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RELEASE_DIR="$RELEASES_DIR/$release_name"
install -d -o root -g root -m 0755 "$RELEASE_DIR"
cp -a "$TMP_DIR/unpacked/." "$RELEASE_DIR/"
install -o root -g online-service -m 0750 "$BINARY_SOURCE" "$RELEASE_DIR/online-gateway"
chown -R root:root "$RELEASE_DIR"
chown root:online-service "$RELEASE_DIR/online-gateway"
chmod 0750 "$RELEASE_DIR/online-gateway"

TEMP_LINK="$APP_ROOT/.current.$$"
rm -f -- "$TEMP_LINK"
ln -s "releases/$release_name" "$TEMP_LINK"
mv -Tf -- "$TEMP_LINK" "$CURRENT_LINK"

install -o root -g root -m 0644 "$SERVICE_SOURCE" "$TMP_DIR/online-gateway.service"
if grep -q '^EnvironmentFile=' "$TMP_DIR/online-gateway.service"; then
    sed -i "s|^EnvironmentFile=.*|EnvironmentFile=$CONFIG_FILE|" "$TMP_DIR/online-gateway.service"
else
    sed -i "/^\[Service\]$/a EnvironmentFile=$CONFIG_FILE" "$TMP_DIR/online-gateway.service"
fi
PREVIOUS_UNIT=""
if [[ -f $UNIT_FILE ]]; then
    cp -- "$UNIT_FILE" "$TMP_DIR/previous-online-gateway.service"
    PREVIOUS_UNIT="$TMP_DIR/previous-online-gateway.service"
fi
install -o root -g root -m 0644 "$TMP_DIR/online-gateway.service" "$UNIT_FILE"

systemctl daemon-reload
systemctl enable online-gateway.service
if ! systemctl restart online-gateway.service; then
    printf 'Falha ao iniciar a nova versão; restaurando a instalação anterior.\n' >&2
    if [[ -n $PREVIOUS_TARGET ]]; then
        TEMP_LINK="$APP_ROOT/.rollback.$$"
        rm -f -- "$TEMP_LINK"
        ln -s "$PREVIOUS_TARGET" "$TEMP_LINK"
        mv -Tf -- "$TEMP_LINK" "$CURRENT_LINK"
        if [[ -n $PREVIOUS_UNIT ]]; then
            install -o root -g root -m 0644 "$PREVIOUS_UNIT" "$UNIT_FILE"
        else
            rm -f -- "$UNIT_FILE"
        fi
        systemctl daemon-reload || true
        systemctl restart online-gateway.service || true
    else
        systemctl disable --now online-gateway.service || true
    fi
    journalctl -u online-gateway.service -n 40 --no-pager >&2 || true
    die 'instalação não iniciada; consulte o journal do serviço'
fi

print_centered "online-gateway $VERSION instalado e ativo."
printf 'Release: %s\nConfiguração: %s (somente root)\n' "$RELEASE_DIR" "$CONFIG_FILE"
printf 'Chave ONLINE_REGISTRY_ENCRYPTION_KEY preservada/gerada; mantenha uma cópia segura para restaurar os dados SQLite.\n'
