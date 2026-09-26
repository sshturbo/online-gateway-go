#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-v1.0.0}"
ASSET_VERSION="${VERSION#v}"
ARCH=$(uname -m)

APP_ROOT=/opt/online-service
RELEASES_DIR="$APP_ROOT/releases"
CURRENT_LINK="$APP_ROOT/current"
CONFIG_DIR=/etc/online-service
CONFIG_FILE="$CONFIG_DIR/.env"
LEGACY_CONFIG_FILE="$CONFIG_DIR/online-service.env"
UNIT_FILE=/etc/systemd/system/online-gateway.service
DOWNLOAD_URL="https://github.com/sshturbo/online-gateway-go/releases/download/$VERSION/online-gateway-$ASSET_VERSION.zip"

die() {
    printf 'Erro: %s\n' "$*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die 'execute como root: sudo bash install/install.sh'
[[ $ARCH == x86_64 ]] || die "esta release suporta x86_64; arquitetura detectada: $ARCH"
[[ $VERSION =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "versão inválida: $VERSION"
command -v systemctl >/dev/null 2>&1 || die 'systemd/systemctl não encontrado'

missing=()
for command_name in wget unzip openssl; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
if ((${#missing[@]})); then
    command -v apt-get >/dev/null 2>&1 || die "instale as dependências: ${missing[*]}"
    apt-get update
    apt-get install -y --no-install-recommends "${missing[@]}"
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT

printf 'Baixando online-gateway %s...\n' "$VERSION"
wget --timeout=30 --tries=2 -O "$TMP_DIR/online-gateway.zip" "$DOWNLOAD_URL"
unzip -q "$TMP_DIR/online-gateway.zip" -d "$TMP_DIR/package"

for file in .env.example online-gateway online-gateway.service; do
    [[ -f $TMP_DIR/package/$file ]] || die "arquivo $file não encontrado no pacote"
done

getent group online-service >/dev/null 2>&1 || groupadd --system online-service
getent passwd online-service >/dev/null 2>&1 || \
    useradd --system --gid online-service --home-dir /nonexistent --shell /usr/sbin/nologin --no-create-home online-service

install -d -o root -g root -m 0755 "$APP_ROOT" "$RELEASES_DIR" "$CONFIG_DIR"
install -d -o root -g root -m 0755 "$RELEASES_DIR/$ASSET_VERSION"

if [[ ! -e $CONFIG_FILE ]]; then
    if [[ -f $LEGACY_CONFIG_FILE ]]; then
        install -o root -g root -m 0600 "$LEGACY_CONFIG_FILE" "$CONFIG_FILE"
    else
        install -o root -g root -m 0600 "$TMP_DIR/package/.env.example" "$CONFIG_FILE"
    fi
fi
[[ -f $CONFIG_FILE && ! -L $CONFIG_FILE ]] || die "$CONFIG_FILE precisa ser um arquivo regular"

encryption_key=$(sed -n 's/^ONLINE_REGISTRY_ENCRYPTION_KEY=//p' "$CONFIG_FILE" | head -n 1 | tr -d '\r')
if [[ -z $encryption_key ]]; then
    encryption_key=$(openssl rand -base64 32 | tr -d '\r\n')
    if grep -q '^ONLINE_REGISTRY_ENCRYPTION_KEY=' "$CONFIG_FILE"; then
        sed -i "s|^ONLINE_REGISTRY_ENCRYPTION_KEY=.*|ONLINE_REGISTRY_ENCRYPTION_KEY=$encryption_key|" "$CONFIG_FILE"
    else
        printf '\nONLINE_REGISTRY_ENCRYPTION_KEY=%s\n' "$encryption_key" >>"$CONFIG_FILE"
    fi
fi
[[ $encryption_key =~ ^[A-Za-z0-9+/]{43}=?$ ]] || die "ONLINE_REGISTRY_ENCRYPTION_KEY inválida em $CONFIG_FILE"
chown root:root "$CONFIG_FILE"
chmod 0600 "$CONFIG_FILE"

install -o root -g online-service -m 0750 "$TMP_DIR/package/online-gateway" \
    "$RELEASES_DIR/$ASSET_VERSION/online-gateway"
TEMP_LINK="$APP_ROOT/.current.$$"
rm -f -- "$TEMP_LINK"
ln -s "releases/$ASSET_VERSION" "$TEMP_LINK"
mv -Tf "$TEMP_LINK" "$CURRENT_LINK"

install -o root -g root -m 0644 "$TMP_DIR/package/online-gateway.service" "$UNIT_FILE"
sed -i "s|^EnvironmentFile=.*|EnvironmentFile=$CONFIG_FILE|" "$UNIT_FILE"
systemctl daemon-reload
systemctl enable online-gateway.service
if systemctl is-active --quiet online-gateway.service; then
    systemctl restart online-gateway.service
else
    systemctl start online-gateway.service
fi

printf 'online-gateway %s instalado e ativo. Configuração: %s\n' "$VERSION" "$CONFIG_FILE"
