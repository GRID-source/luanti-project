# LuantiServer : hébergement de serveurs Luanti avec LXC

Projet réseau et système : héberger plusieurs mondes [Luanti](https://www.luanti.org/) (anciennement Minetest) sur une seule machine Debian, **un conteneur LXC par monde**, avec un script qui crée chaque monde en quelques questions.

## Objectifs du projet

- Héberger au moins **5 mondes** : classique, créatif, exploration (carte IGN), survie (VoxelLibre) et un monde personnalisé.
- Administrer les mondes avec des **scripts**.
- Publier l'état du serveur et des mondes sur une **page web en HTTPS**.
- **Sécuriser** le serveur, en particulier les comptes des joueurs contre le brute force.

## Principe

Un processus `luantiserver` ne sert qu'**un seul monde**. Pour plusieurs mondes, on lance donc plusieurs instances. Ici, chaque instance vit dans son propre conteneur LXC, ce qui isole les mondes les uns des autres.

```
Machine hôte (Debian 12)
├── LXC, pare-feu nftables, redirection des ports UDP
├── conteneur luanti-creatif     → Luanti + Minetest Game + monde créatif
├── conteneur luanti-survie      → Luanti + VoxelLibre    + monde survie
└── … un conteneur par monde
```

- L'**hôte** gère les conteneurs et redirige un port UDP différent vers chacun.
- Chaque **conteneur** contient le moteur, un jeu, un monde (fichiers SQLite) et un service systemd.
- Les joueurs choisissent le monde en changeant le **port** dans leur client Luanti. Il n'y a pas de portails automatiques entre les mondes.

## Prérequis

- Debian 12, architecture x86_64, accès `sudo` et Internet.
- Les ports UDP choisis ouverts depuis les machines clientes.

## Utilisation

Sur l'hôte :

```bash
wget https://raw.githubusercontent.com/GRID-source/luanti-project/main/creer-monde.sh
chmod +x creer-monde.sh
sudo ./creer-monde.sh
```

Relancez le script pour chaque nouveau monde.

### Questions posées

| Question | Valeur proposée |
|---|---|
| Type de monde | classique, créatif, exploration, survie ou perso |
| Nom du conteneur | `luanti-<type>` |
| Nom du serveur, pseudo admin, joueurs max | valeurs par défaut |
| Adresse IP du conteneur | première IP libre à partir de `.11` |
| Port UDP ouvert sur l'hôte | premier port libre à partir de 30000 |
| Limite de mémoire (Mo) | aucune |

### Types de monde

| Type | Jeu | Règles |
|---|---|---|
| classique | Minetest Game | standard, privilèges `interact, shout` |
| creatif | Minetest Game | mode créatif, sans dégâts, privilèges `fly, fast, noclip` en plus |
| exploration | Minetest Game | sans dégâts, pas de construction (`interact` retiré), course autorisée |
| survie | VoxelLibre | dégâts activés |
| perso | au choix | réglages choisis pendant les questions |

L'import de la carte IGN du monde exploration reste à faire à la main : elle est au format Minecraft et doit être convertie.

## Ce que fait le script

1. Prépare l'hôte (LXC, pont `lxcbr0`, réservation d'IP, nftables).
2. Crée un conteneur Debian 12 avec démarrage automatique et limite de mémoire optionnelle.
3. Installe dans le conteneur le moteur Luanti (binaire serveur précompilé), le jeu choisi et un service `luanti`.
4. Écrit `monde.conf` selon le type de monde.
5. Ouvre le port UDP choisi sur l'hôte vers le port 30000 du conteneur.
6. Note le monde dans `/etc/luanti-mondes.list`.

## Après la création

```bash
sudo lxc-ls -f                                              # état des conteneurs
sudo lxc-attach -n NOM -- nano /opt/luanti/<racine>/monde.conf   # personnaliser
sudo lxc-attach -n NOM -- systemctl restart luanti          # appliquer
sudo lxc-attach -n NOM -- systemctl status luanti
sudo lxc-stop -n NOM    /    sudo lxc-start -n NOM
```

Le script affiche le chemin exact de `<racine>` à la fin de la création.

### Contenu d'un conteneur

```
/opt/luanti/<racine>/
├── bin/luantiserver     moteur
├── games/<jeu>/         jeu installé
├── monde.conf           configuration
├── monde/               monde (world.mt, map.sqlite, auth.sqlite, players.sqlite)
└── monde.log            journal du moteur
```

## Se connecter

1. Installer un client Luanti de version proche de celle du serveur.
2. Rejoindre : adresse = IP de l'hôte, port = celui du monde.
3. Se connecter avec le pseudo administrateur et choisir un mot de passe.
4. Touches par défaut : `K` voler, `J` courir, `H` traverser les blocs.

## Comment fonctionne Luanti

- Le **moteur** gère le réseau, la carte et la simulation.
- Le **jeu** (Minetest Game, VoxelLibre) définit les blocs et les règles, en Lua.
- Les **mods** étendent le jeu.
- Un **monde** est un dossier de fichiers SQLite : sauvegarder un monde, c'est copier son dossier.
- Les **privilèges** (`interact`, `shout`, `fly`, `fast`, `noclip`…) définissent ce que chaque joueur peut faire.

## Dépannage

- **Le conteneur n'a pas Internet** : vérifier `systemctl status lxc-net` et `iptables -t nat -S`.
- **L'IP obtenue n'est pas celle demandée** : redémarrer le pont avec `sudo systemctl restart lxc-net` quand aucun conteneur ne tourne.
- **Le service ne démarre pas** : `sudo lxc-attach -n NOM -- journalctl -u luanti -n 50`.
- **Le client ne se connecte pas** : vérifier le port UDP, le pare-feu et que la version du client est proche de celle du serveur.

## Feuille de route

- [x] Script de création d'un monde dans un conteneur LXC
- [ ] Mondes classique, créatif, exploration (carte IGN), survie et perso
- [ ] Scripts d'administration (sauvegarde, mise à jour, suppression d'un monde)
- [ ] Page d'état en HTTPS
- [ ] Sécurité : pare-feu, Fail2ban contre le brute force

## Ressources

- [Site officiel de Luanti](https://www.luanti.org/)
- [Documentation pour hébergeurs](https://docs.luanti.org/for-server-hosts/setup/linux/)
- [Exemple de configuration](https://github.com/luanti-org/luanti/blob/master/minetest.conf.example)
- [ContentDB (jeux et mods)](https://content.luanti.org/)
- [Minecraft IGN](https://minecraft.ign.fr/)
