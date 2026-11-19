#!/usr/bin/env bash
# install-luanti.sh : installe un serveur Luanti sur Debian 12 (x86_64)
# et prépare l'étape "configuration du serveur et des mondes".
#
# Usage : sudo ./install-luanti.sh
# Variables facultatives :
#   INSTALL_DIR  dossier d'installation          (défaut : /opt/luanti)
#   LUANTI_USER  utilisateur qui fait tourner le serveur (défaut : luanti)
#   LUANTI_URL   URL directe de l'archive du serveur (sinon : dernière release GitHub)
#   MTG_URL      URL du zip de Minetest Game

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/luanti}"
LUANTI_USER="${LUANTI_USER:-luanti}"
LUANTI_URL="${LUANTI_URL:-}"
MTG_URL="${MTG_URL:-https://content.luanti.org/packages/Luanti/minetest_game/releases/38214/download/}"
RELEASES_API="https://api.github.com/repos/rollerozxa/luantiserver/releases/latest"
ADMIN_USER="${SUDO_USER:-}"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mAttention : %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mErreur : %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "lance ce script avec sudo : sudo ./install-luanti.sh"
[[ "$(uname -m)" == "x86_64" ]] || die "les binaires précompilés sont en x86_64 uniquement (ici : $(uname -m))"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- 1. Mise à jour
log "1/8 Mise à jour du système"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade

# ---------------------------------------------------------------- 2. Dépendances
log "2/8 Installation des outils nécessaires"
apt-get install -y curl ca-certificates unzip tar jq nano tmux

# ---------------------------------------------------------------- 3. Utilisateur dédié
log "3/8 Utilisateur dédié '$LUANTI_USER' et dossier $INSTALL_DIR"
if ! id "$LUANTI_USER" >/dev/null 2>&1; then
  adduser --system --group --home "$INSTALL_DIR" --no-create-home \
          --shell /usr/sbin/nologin "$LUANTI_USER"
fi
mkdir -p "$INSTALL_DIR"

# ---------------------------------------------------------------- 4. Téléchargement du serveur
log "4/8 Téléchargement du serveur Luanti"
if [[ -z "$LUANTI_URL" ]]; then
  mapfile -t URLS < <(curl -fsSL "$RELEASES_API" \
    | jq -r '.assets[].browser_download_url' \
    | grep -Eiv 'debug|dbg|symbol|\.sha|\.sig|\.asc' || true)
  LUANTI_URL="$(printf '%s\n' "${URLS[@]}" | grep -Ei '\.tar|\.tgz' | grep -Ei 'linux|x86|amd64' | head -1 || true)"
  if [[ -z "$LUANTI_URL" ]]; then
    LUANTI_URL="$(printf '%s\n' "${URLS[@]}" | grep -Ei '\.tar|\.tgz' | head -1 || true)"
  fi
  if [[ -z "$LUANTI_URL" ]]; then
    echo "Archives trouvées dans la dernière release :" >&2
    printf '  %s\n' "${URLS[@]}" >&2
    die "aucune archive reconnue. Relance avec : sudo LUANTI_URL=<url> ./install-luanti.sh"
  fi
fi
echo "Archive : $LUANTI_URL"
curl -fL --retry 3 -o "$TMP/luanti-server.tar" "$LUANTI_URL"

# ---------------------------------------------------------------- 5. Extraction
log "5/8 Extraction dans $INSTALL_DIR"
tar -xf "$TMP/luanti-server.tar" -C "$INSTALL_DIR"

BIN="$(find "$INSTALL_DIR" -type f -name luantiserver | head -1)"
[[ -n "$BIN" ]] || die "binaire 'luantiserver' introuvable après extraction (voir : ls -R $INSTALL_DIR)"
if [[ "$(basename "$(dirname "$BIN")")" == "bin" ]]; then
  ROOT="$(dirname "$(dirname "$BIN")")"
else
  ROOT="$(dirname "$BIN")"
fi
echo "Binaire : $BIN"
echo "Racine  : $ROOT"

# ---------------------------------------------------------------- 6. Jeu Minetest Game
log "6/8 Installation du jeu Minetest Game"
curl -fL --retry 3 -o "$TMP/mtg.zip" "$MTG_URL"
mkdir -p "$TMP/mtg" "$ROOT/games"
unzip -q "$TMP/mtg.zip" -d "$TMP/mtg"
GAMECONF="$(find "$TMP/mtg" -name game.conf | head -1)"
[[ -n "$GAMECONF" ]] || die "game.conf introuvable dans l'archive de Minetest Game"
rm -rf "$ROOT/games/minetest_game"
mv "$(dirname "$GAMECONF")" "$ROOT/games/minetest_game"

# ---------------------------------------------------------------- 7. Structure et droits
log "7/8 Structure des dossiers et droits"
mkdir -p "$ROOT/mondes"

CONF="$ROOT/mondes/creatif.conf"
if [[ ! -f "$CONF" ]]; then
  cat > "$CONF" <<'EOF'
# Monde créatif : configuration de l'instance
server_name = Test creatif
server_description = Monde creatif du projet LuantiServer
port = 30000
# Le compte "admin" reçoit tous les privilèges
name = admin
creative_mode = true
enable_damage = false
default_privs = interact, shout, fly, fast, noclip
EOF
fi

# Fichier d'environnement réutilisable par les futurs scripts
cat > "$INSTALL_DIR/luanti.env" <<EOF
LUANTI_ROOT="$ROOT"
LUANTI_BIN="$BIN"
LUANTI_USER="$LUANTI_USER"
EOF

chmod +x "$BIN"
chown -R "$LUANTI_USER:$LUANTI_USER" "$INSTALL_DIR"
chmod -R u+rwX,g+rwX,o-rwx "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod g+s {} +

if [[ -n "$ADMIN_USER" && "$ADMIN_USER" != "root" ]]; then
  usermod -aG "$LUANTI_USER" "$ADMIN_USER"
  echo "L'utilisateur '$ADMIN_USER' est ajouté au groupe '$LUANTI_USER' (droits d'écriture)."
  echo "Reconnecte-toi en SSH, ou lance 'newgrp $LUANTI_USER', pour que cela prenne effet."
fi

# ---------------------------------------------------------------- 8. Vérification
log "8/8 Vérification"
if (cd "$ROOT" && runuser -u "$LUANTI_USER" -- "$BIN" --version); then
  echo "Le serveur répond."
else
  warn "le binaire ne se lance pas. Une bibliothèque manque peut-être (voir le message ci-dessus)."
fi

# ---------------------------------------------------------------- Configuration
cat <<EOF

====================================================================
 Installation terminée. On arrive à l'étape de configuration.
====================================================================
 Racine du serveur : $ROOT
 Jeu installé      : $ROOT/games/minetest_game
 Config du monde   : $CONF
 Dossier des mondes: $ROOT/mondes

 Contenu actuel de la configuration :
--------------------------------------------------------------------
$(cat "$CONF")
--------------------------------------------------------------------

 Pour lancer le monde créatif :
   cd $ROOT
   sudo -u $LUANTI_USER ./bin/luantiserver \\
     --config mondes/creatif.conf \\
     --world mondes/creatif \\
     --gameid minetest_game

 Pour vérifier qu'il écoute :  ss -ulpn | grep 30000
====================================================================
EOF

if [[ -t 0 ]]; then
  read -rp "Modifier la configuration du monde créatif maintenant ? [o/N] " REP
  if [[ "${REP,,}" == "o" ]]; then
    "${EDITOR:-nano}" "$CONF"
    chown "$LUANTI_USER:$LUANTI_USER" "$CONF"
    echo "Configuration enregistrée."
  fi
fi
