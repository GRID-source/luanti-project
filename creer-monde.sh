#!/usr/bin/env bash
# creer-monde.sh : crée un conteneur LXC avec un serveur Luanti et UN monde dedans.
#
# À lancer sur l'HÔTE (Debian 12) :  sudo ./creer-monde.sh
# Le script pose quelques questions, crée le conteneur, y installe Luanti,
# écrit une configuration de départ selon le type de monde choisi,
# lance le serveur et ouvre un port UDP sur l'hôte vers ce conteneur.
# Ensuite, vous personnalisez la configuration à la main.
#
# Chaque conteneur contient la même arborescence :
#   /opt/luanti/<racine>/monde.conf   configuration du serveur
#   /opt/luanti/<racine>/monde/       dossier du monde (carte SQLite, comptes...)
#   /opt/luanti/<racine>/monde.log    journal du moteur
#   service systemd : luanti.service

set -euo pipefail

REGISTRE="/etc/luanti-mondes.list"      # une ligne par monde : nom  ip  port_externe
NAT_FILE="/etc/luanti-nat.nft"          # redirections UDP générées à partir du registre
DHCP_HOSTS="/etc/lxc/dhcp-hosts"        # réservations d'adresses IP des conteneurs
DNSMASQ_CONF="/etc/lxc/dnsmasq.conf"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mAttention : %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mErreur : %s\033[0m\n' "$*" >&2; exit 1; }

ask() {   # ask VARIABLE "question" "valeur par défaut"
  local var="$1" prompt="$2" def="${3:-}" val
  read -rp "$prompt${def:+ [$def]} : " val
  printf -v "$var" '%s' "${val:-$def}"
}
ask_yn() { # ask_yn VARIABLE "question" o|n   -> VARIABLE = true|false
  local var="$1" prompt="$2" def="${3:-n}" val
  read -rp "$prompt [$def] : " val
  val="${val:-$def}"
  if [[ "${val,,}" == "o" || "${val,,}" == "y" ]]; then printf -v "$var" 'true'; else printf -v "$var" 'false'; fi
}

[[ $EUID -eq 0 ]] || die "lance ce script avec sudo : sudo ./creer-monde.sh"
[[ "$(uname -m)" == "x86_64" ]] || die "les binaires Luanti précompilés sont en x86_64 uniquement"
[[ -t 0 ]] || die "ce script est interactif : lance-le depuis un terminal"

# ================================================================ Préparation de l'hôte
preparer_hote() {
  log "Préparation de l'hôte (LXC, réseau, pare-feu)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y lxc debootstrap gnupg wget xz-utils iptables nftables jq curl

  touch "$REGISTRE" "$DHCP_HOSTS" "$DNSMASQ_CONF"
  local changed=0

  if ! grep -q '^USE_LXC_BRIDGE="true"' /etc/default/lxc-net 2>/dev/null; then
    echo 'USE_LXC_BRIDGE="true"' >> /etc/default/lxc-net; changed=1
  fi
  if ! grep -q "^LXC_DHCP_CONFILE=$DNSMASQ_CONF" /etc/default/lxc-net; then
    echo "LXC_DHCP_CONFILE=$DNSMASQ_CONF" >> /etc/default/lxc-net; changed=1
  fi
  if ! grep -q "^dhcp-hostsfile=$DHCP_HOSTS" "$DNSMASQ_CONF"; then
    echo "dhcp-hostsfile=$DHCP_HOSTS" >> "$DNSMASQ_CONF"; changed=1
  fi

  systemctl enable lxc-net >/dev/null 2>&1 || true
  if ! ip link show lxcbr0 >/dev/null 2>&1; then
    systemctl start lxc-net
  elif [[ $changed -eq 1 ]]; then
    if [[ -z "$(lxc-ls --running 2>/dev/null)" ]]; then
      systemctl restart lxc-net
    else
      warn "des conteneurs tournent déjà : redémarre le service lxc-net quand tu pourras (systemctl restart lxc-net) pour activer les IP fixes."
    fi
  fi
  ip link show lxcbr0 >/dev/null 2>&1 || die "le pont lxcbr0 n'existe pas (voir : systemctl status lxc-net)"

  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-luanti.conf
  sysctl -q -w net.ipv4.ip_forward=1

  [[ -f "$NAT_FILE" ]] || printf '# généré par creer-monde.sh\n' > "$NAT_FILE"
  if [[ -f /etc/nftables.conf ]] && ! grep -q "$NAT_FILE" /etc/nftables.conf; then
    echo "include \"$NAT_FILE\"" >> /etc/nftables.conf
  fi
  systemctl enable nftables >/dev/null 2>&1 || true
}

# ================================================================ Redirections UDP (nftables)
appliquer_nat() {
  {
    echo "# généré par creer-monde.sh : ne pas modifier à la main"
    echo "table ip luanti_nat {"
    echo "  chain prerouting {"
    echo "    type nat hook prerouting priority dstnat; policy accept;"
    while read -r n ip port; do
      [[ -z "${n:-}" || "$n" == \#* ]] && continue
      echo "    udp dport $port dnat to $ip:30000 comment \"$n\""
    done < "$REGISTRE"
    echo "  }"
    echo "}"
  } > "$NAT_FILE"
  nft delete table ip luanti_nat 2>/dev/null || true
  nft -f "$NAT_FILE"
}

# ================================================================ Questions
preparer_hote

BRIDGE_IP="$(ip -4 -o addr show lxcbr0 | awk '{print $4}' | cut -d/ -f1 | head -1)"
[[ -n "$BRIDGE_IP" ]] || die "pas d'adresse IP sur lxcbr0"
PREFIXE="${BRIDGE_IP%.*}"
HOTE_IP="$(hostname -I | awk '{print $1}')"

log "Création d'un nouveau monde"
echo "Type de monde :"
echo "  1) classique    : jeu de base, droits par défaut"
echo "  2) creatif      : créatif, vol/course/traversée des blocs, sans dégâts"
echo "  3) exploration  : pas de construction, course possible, sans dégâts"
echo "  4) survie       : VoxelLibre, avec dégâts"
echo "  5) perso        : tu choisis les réglages"
ask CHOIX "Ton choix (1-5)" "1"
case "$CHOIX" in
  1) PRESET=classique;   CREATIVE=false; DAMAGE=true;  PRIVS="interact, shout";                 GAME_PKG="Luanti/minetest_game" ;;
  2) PRESET=creatif;     CREATIVE=true;  DAMAGE=false; PRIVS="interact, shout, fly, fast, noclip"; GAME_PKG="Luanti/minetest_game" ;;
  3) PRESET=exploration; CREATIVE=false; DAMAGE=false; PRIVS="shout, fast";                     GAME_PKG="Luanti/minetest_game" ;;
  4) PRESET=survie;      CREATIVE=false; DAMAGE=true;  PRIVS="interact, shout";                 GAME_PKG="Wuzzy/mineclone2" ;;
  5) PRESET=perso;       CREATIVE=false; DAMAGE=true;  PRIVS="interact, shout";                 GAME_PKG="Luanti/minetest_game" ;;
  *) die "choix invalide" ;;
esac

ask NAME "Nom du conteneur (lettres minuscules, chiffres, tirets)" "luanti-$PRESET"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "nom invalide : $NAME"
if lxc-info -n "$NAME" >/dev/null 2>&1; then die "le conteneur '$NAME' existe déjà"; fi

ask SERVER_NAME "Nom affiché du serveur" "Luanti $PRESET"
ask ADMIN "Pseudo administrateur (reçoit tous les privilèges)" "admin"
ask MAX_USERS "Nombre maximum de joueurs" "20"
[[ "$MAX_USERS" =~ ^[0-9]+$ ]] || die "nombre de joueurs invalide"

if [[ "$PRESET" == "perso" ]]; then
  ask GAME_PKG "Jeu ContentDB (auteur/nom)" "$GAME_PKG"
  ask_yn CREATIVE "Mode créatif ? (o/n)" "n"
  ask_yn DAMAGE "Dégâts activés ? (o/n)" "o"
  ask PRIVS "Privilèges donnés aux nouveaux joueurs" "$PRIVS"
fi
[[ "$GAME_PKG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "jeu invalide (format attendu : auteur/nom)"
GAME_ID="${GAME_PKG#*/}"

# IP : première adresse libre à partir de .11, d'après le registre
n=11
while grep -qE "^[^ ]+ ${PREFIXE}\.${n} " "$REGISTRE" 2>/dev/null; do n=$((n+1)); done
ask IP "Adresse IP du conteneur" "${PREFIXE}.${n}"
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "adresse IP invalide"
grep -qE "^[^ ]+ ${IP} " "$REGISTRE" && die "l'IP $IP est déjà utilisée par un autre monde"

# Port UDP externe : premier port libre à partir de 30000
p=30000
while grep -qE " ${p}\$" "$REGISTRE" 2>/dev/null || ss -uln | grep -q ":${p} "; do p=$((p+1)); done
ask PORT_EXT "Port UDP ouvert sur l'hôte pour ce monde" "$p"
[[ "$PORT_EXT" =~ ^[0-9]+$ ]] || die "port invalide"
grep -qE " ${PORT_EXT}\$" "$REGISTRE" && die "le port $PORT_EXT est déjà utilisé par un autre monde"

ask RAM_MO "Limite de mémoire en Mo (vide = aucune)" ""

echo
echo "-------------------- Récapitulatif --------------------"
echo " Conteneur    : $NAME"
echo " Type         : $PRESET"
echo " Jeu          : $GAME_PKG"
echo " Serveur      : $SERVER_NAME (admin : $ADMIN, max $MAX_USERS joueurs)"
echo " Règles       : creative_mode=$CREATIVE  enable_damage=$DAMAGE"
echo " Privilèges   : $PRIVS"
echo " Réseau       : $IP  ->  UDP $PORT_EXT de l'hôte vers 30000 du conteneur"
echo " Mémoire max  : ${RAM_MO:-aucune}"
echo "-------------------------------------------------------"
ask_yn OK "Créer ce monde ? (o/n)" "o"
[[ "$OK" == "true" ]] || die "annulé"

# ================================================================ Création du conteneur
log "Création du conteneur $NAME (Debian 12)"
lxc-create -n "$NAME" -t download -- --dist debian --release bookworm --arch amd64

CFG="/var/lib/lxc/$NAME/config"
{
  echo ""
  echo "# ajouts de creer-monde.sh"
  echo "lxc.start.auto = 1"
  [[ -n "$RAM_MO" ]] && echo "lxc.cgroup2.memory.max = $((RAM_MO * 1024 * 1024))"
} >> "$CFG"

# Réservation de l'adresse IP (le conteneur annonce son nom au DHCP)
echo "$NAME,$IP" >> "$DHCP_HOSTS"
if [[ -f /run/lxc/dnsmasq.pid ]]; then kill -HUP "$(cat /run/lxc/dnsmasq.pid)" || true; fi

log "Démarrage du conteneur"
lxc-start -n "$NAME"
IP_REEL=""
for _ in $(seq 1 60); do
  IP_REEL="$(lxc-info -n "$NAME" -iH 2>/dev/null | head -1 || true)"
  [[ -n "$IP_REEL" ]] && break
  sleep 1
done
[[ -n "$IP_REEL" ]] || die "le conteneur n'a pas obtenu d'adresse IP (voir : lxc-info -n $NAME)"
if [[ "$IP_REEL" != "$IP" ]]; then
  warn "IP obtenue : $IP_REEL (au lieu de $IP). La réservation sera prise en compte au prochain redémarrage du pont lxc-net."
  IP="$IP_REEL"
fi

echo "Test de l'accès à Internet depuis le conteneur..."
NET_OK=0
for _ in $(seq 1 20); do
  if lxc-attach -n "$NAME" -- getent hosts deb.debian.org >/dev/null 2>&1; then NET_OK=1; break; fi
  sleep 1
done
[[ $NET_OK -eq 1 ]] || die "le conteneur n'accède pas à Internet (DNS ou NAT). Vérifie : systemctl status lxc-net, iptables -t nat -S"

# ================================================================ Fichiers poussés dans le conteneur
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

cat > "$TMPD/monde.env" <<EOF
PRESET="$PRESET"
SERVER_NAME="$SERVER_NAME"
ADMIN="$ADMIN"
MAX_USERS="$MAX_USERS"
GAME_PKG="$GAME_PKG"
GAME_ID="$GAME_ID"
CREATIVE="$CREATIVE"
DAMAGE="$DAMAGE"
PRIVS="$PRIVS"
EOF

# ---- Script exécuté DANS le conteneur ----------------------------------------
cat > "$TMPD/installer-luanti.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source /root/monde.env

INSTALL_DIR="/opt/luanti"
LUANTI_USER="luanti"
RELEASES_API="https://api.github.com/repos/rollerozxa/luantiserver/releases/latest"

log() { printf '\n\033[1;36m  [conteneur] %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m  [conteneur] Erreur : %s\033[0m\n' "$*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
log "Mise à jour et outils"
apt-get update
apt-get install -y curl ca-certificates unzip tar jq nano \
  libcurl4 libncurses6 libsqlite3-0 libzstd1 zlib1g

log "Utilisateur dédié"
id "$LUANTI_USER" >/dev/null 2>&1 || \
  adduser --system --group --home "$INSTALL_DIR" --no-create-home --shell /usr/sbin/nologin "$LUANTI_USER"
mkdir -p "$INSTALL_DIR"

log "Téléchargement du serveur Luanti"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mapfile -t URLS < <(curl -fsSL "$RELEASES_API" | jq -r '.assets[].browser_download_url' \
  | grep -Eiv 'debug|dbg|symbol|\.sha|\.sig|\.asc' || true)
URL="$(printf '%s\n' "${URLS[@]}" | grep -Ei '\.tar|\.tgz' | grep -Ei 'linux|x86|amd64' | head -1 || true)"
[[ -n "$URL" ]] || URL="$(printf '%s\n' "${URLS[@]}" | grep -Ei '\.tar|\.tgz' | head -1 || true)"
if [[ -z "$URL" ]]; then
  printf '  %s\n' "${URLS[@]}" >&2
  die "aucune archive de serveur reconnue dans la dernière release"
fi
echo "Archive : $URL"
curl -fL --retry 3 -o "$TMP/server.tar" "$URL"
tar -xf "$TMP/server.tar" -C "$INSTALL_DIR"

BIN="$(find "$INSTALL_DIR" -type f -name luantiserver | head -1)"
[[ -n "$BIN" ]] || die "binaire luantiserver introuvable"
if [[ "$(basename "$(dirname "$BIN")")" == "bin" ]]; then ROOT="$(dirname "$(dirname "$BIN")")"; else ROOT="$(dirname "$BIN")"; fi
chmod +x "$BIN"

log "Installation du jeu $GAME_PKG"
AUTEUR="${GAME_PKG%/*}"; NOM="${GAME_PKG#*/}"
REL="$(curl -fsSL "https://content.luanti.org/api/packages/?q=$NOM&type=game" \
  | jq -r --arg a "$AUTEUR" --arg n "$NOM" '.[] | select(.author==$a and .name==$n) | .release' | head -1)"
[[ "$REL" =~ ^[0-9]+$ ]] || die "jeu '$GAME_PKG' introuvable sur ContentDB (type game)"
curl -fL --retry 3 -o "$TMP/jeu.zip" "https://content.luanti.org/packages/$AUTEUR/$NOM/releases/$REL/download/"
mkdir -p "$TMP/jeu" "$ROOT/games"
unzip -q "$TMP/jeu.zip" -d "$TMP/jeu"
GC="$(find "$TMP/jeu" -name game.conf | head -1)"
[[ -n "$GC" ]] || die "game.conf introuvable dans l'archive du jeu"
rm -rf "$ROOT/games/$GAME_ID"
mv "$(dirname "$GC")" "$ROOT/games/$GAME_ID"

log "Configuration du serveur"
cat > "$ROOT/monde.conf" <<EOF
# Monde "$PRESET" : configuration générée, à personnaliser
server_name = $SERVER_NAME
server_description = Monde $PRESET du projet LuantiServer
motd = Bienvenue sur $SERVER_NAME
port = 30000
name = $ADMIN
max_users = $MAX_USERS
creative_mode = $CREATIVE
enable_damage = $DAMAGE
default_privs = $PRIVS
disallow_empty_password = true
server_announce = false
EOF

chown -R "$LUANTI_USER:$LUANTI_USER" "$INSTALL_DIR"
chmod -R u+rwX,g+rwX,o-rwx "$INSTALL_DIR"

log "Service systemd"
cat > /etc/systemd/system/luanti.service <<EOF
[Unit]
Description=Serveur Luanti - monde $PRESET
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$LUANTI_USER
Group=$LUANTI_USER
WorkingDirectory=$ROOT
ExecStart=$BIN --config $ROOT/monde.conf --world $ROOT/monde --gameid $GAME_ID --logfile $ROOT/monde.log
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now luanti
sleep 5
systemctl is-active --quiet luanti || { journalctl -u luanti -n 30 --no-pager; die "le service luanti ne démarre pas"; }
echo "$ROOT" > /root/racine-luanti.txt
echo "Service luanti actif. Racine : $ROOT"
INNER

lxc-attach -n "$NAME" -- tee /root/monde.env >/dev/null < "$TMPD/monde.env"
lxc-attach -n "$NAME" -- tee /root/installer-luanti.sh >/dev/null < "$TMPD/installer-luanti.sh"

log "Installation de Luanti dans le conteneur $NAME"
lxc-attach -n "$NAME" -- bash /root/installer-luanti.sh
ROOT_CONT="$(lxc-attach -n "$NAME" -- cat /root/racine-luanti.txt)"

# ================================================================ Redirection du port et registre
log "Ouverture du port UDP $PORT_EXT sur l'hôte"
echo "$NAME $IP $PORT_EXT" >> "$REGISTRE"
appliquer_nat

# ================================================================ Fin
cat <<EOF

====================================================================
 Monde "$PRESET" prêt dans le conteneur $NAME
====================================================================
 Connexion client : $HOTE_IP  port $PORT_EXT (UDP)   pseudo : $ADMIN
 Conteneur        : $NAME  ($IP)

 Personnaliser :
   sudo lxc-attach -n $NAME -- nano $ROOT_CONT/monde.conf
   sudo lxc-attach -n $NAME -- systemctl restart luanti

 Surveiller :
   sudo lxc-ls -f                                   état de tous les conteneurs
   sudo lxc-attach -n $NAME -- systemctl status luanti
   sudo lxc-attach -n $NAME -- tail -f $ROOT_CONT/monde.log

 Contrôler :
   sudo lxc-stop -n $NAME      /     sudo lxc-start -n $NAME

 Registre des mondes : $REGISTRE
EOF
if [[ "$PRESET" == "exploration" ]]; then
  echo
  echo " Exploration : la carte IGN reste à importer dans $ROOT_CONT/monde/ (format Minecraft à convertir)."
fi
echo "===================================================================="
