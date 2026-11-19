# LuantiServer : hébergement d'un serveur Luanti

Projet réseau et système : concevoir une solution d'hébergement d'un serveur [Luanti](https://www.luanti.org/) (anciennement Minetest) avec ses outils d'administration.

## Objectif du projet

- Héberger au moins **5 mondes** : classique, créatif, exploration (carte IGN), survie (VoxelLibre) et un monde personnalisé.
- Administrer le serveur et les mondes avec des **scripts**.
- Publier l'état du serveur et des mondes sur une **page web en HTTPS**.
- **Sécuriser** le serveur, en particulier les comptes des joueurs contre le brute force.

## Contenu du dépôt

| Fichier | Rôle |
|---|---|
| `install-luanti.sh` | Installe le serveur Luanti sur Debian 12 et prépare la configuration du monde créatif. |
| `Script-deb.sh` | Script initial du projet. |

## Prérequis

- Debian 12 sans interface graphique, architecture x86_64.
- Un accès `sudo` et une connexion Internet.
- Le port **UDP 30000** accessible depuis la machine client.

## Installation

```bash
wget https://raw.githubusercontent.com/GRID-source/luanti-project/main/install-luanti.sh
chmod +x install-luanti.sh
sudo ./install-luanti.sh
```

### Ce que fait le script

1. Met à jour le système.
2. Installe les outils nécessaires (`curl`, `unzip`, `jq`, `tmux`, `nano`).
3. Crée l'utilisateur système `luanti` et le dossier `/opt/luanti`.
4. Télécharge la dernière version du serveur (binaire headless précompilé).
5. Extrait l'archive et repère le binaire `luantiserver`.
6. Installe le jeu Minetest Game dans `games/minetest_game`.
7. Crée la configuration `mondes/creatif.conf` et règle les droits.
8. Vérifie que le serveur démarre, puis affiche la configuration à relire.

Variables facultatives : `INSTALL_DIR` (défaut `/opt/luanti`), `LUANTI_USER` (défaut `luanti`), `LUANTI_URL` (URL de l'archive du serveur), `MTG_URL` (URL de Minetest Game).

## Lancer le monde créatif

```bash
cd /opt/luanti/<dossier-extrait>
sudo -u luanti ./bin/luantiserver \
  --config mondes/creatif.conf \
  --world mondes/creatif \
  --gameid minetest_game
```

Le script affiche le chemin exact à la fin de l'installation. Pour vérifier que le serveur écoute :

```bash
ss -ulpn | grep 30000
```

## Configuration du monde créatif

```ini
server_name = Test creatif
port = 30000
name = admin
creative_mode = true
enable_damage = false
default_privs = interact, shout, fly, fast, noclip
```

- `creative_mode` et `enable_damage` : mode créatif sans dégâts.
- `default_privs` : droits donnés à chaque nouveau joueur (vol, course, traversée des blocs).
- `name` : compte administrateur, qui reçoit tous les privilèges.

## Se connecter depuis un client

1. Installer un client Luanti de version proche de celle du serveur.
2. Rejoindre le serveur : adresse = IP de la VM, port 30000.
3. Se connecter avec le pseudo `admin` et choisir un mot de passe.
4. Touches par défaut : `K` voler, `J` courir, `H` traverser les blocs.

## Comment fonctionne Luanti

- Le **moteur** (`luantiserver`) gère le réseau, la carte et la simulation.
- Le **jeu** (Minetest Game, VoxelLibre) définit les blocs et les règles, en Lua.
- Les **mods** étendent le jeu.
- Un **monde** est un dossier : `world.mt`, `map.sqlite`, `auth.sqlite`, `players.sqlite`.
- Un monde, c'est une instance : cinq mondes demandent cinq processus avec chacun son port ou son conteneur.

## Feuille de route

- [x] Installation du serveur et monde créatif
- [ ] Mondes classique, exploration (carte IGN), survie (VoxelLibre) et perso
- [ ] Un conteneur LXC par monde
- [ ] Scripts d'administration (démarrage, sauvegarde, mise à jour)
- [ ] Page d'état en HTTPS
- [ ] Sécurité : pare-feu, Fail2ban contre le brute force

## Ressources

- [Site officiel de Luanti](https://www.luanti.org/)
- [Documentation hébergeurs](https://docs.luanti.org/for-server-hosts/setup/linux/)
- [Exemple de configuration](https://github.com/luanti-org/luanti/blob/master/minetest.conf.example)
- [ContentDB (jeux et mods)](https://content.luanti.org/)
- [Minecraft IGN](https://minecraft.ign.fr/)
