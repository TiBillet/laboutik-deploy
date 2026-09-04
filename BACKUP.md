# Sauvegarde d'une instance LaBoutik vers borgwarehouse

```bash
docker compose up -d      # la stack doit tourner
make backup               # met en place la sauvegarde, puis en lance une
```

`make backup` est **idempotent** : la première fois il configure tout, ensuite il
lance simplement une sauvegarde. Une seule commande à retenir.

---

## Ce qui est sauvegardé, et ce qui ne l'est pas

| | |
|---|---|
| ✅ **La base PostgreSQL** | `pg_dumpall`, donc toutes les bases, les rôles et les mots de passe du cluster |
| ❌ **Les médias** (`www/media`) | images de produits, fichiers téléversés |
| ❌ **Le `.env`** | secrets de l'instance — il va **au coffre**, voir plus bas |
| ❌ **Les logs** | sans valeur |

**Lis bien la deuxième ligne.** Perdre le serveur, c'est retrouver les données
mais pas les images. Si ça n'est pas acceptable pour cette instance, il faut une
seconde sauvegarde pour `www/` — le [kit borgwarehouse en type
`folder`](https://github.com/CoopCodeCommun/borgwarehouse/tree/main/scripts) fait
exactement ça, sur l'hôte, avec son propre dépôt.

---

## Comment ça marche

Rien de neuf n'a été inventé : le mécanisme vit **déjà dans l'image
`tibillet/laboutik`**, et `make backup` ne fait que lui fournir ce qui lui
manquait.

```
conteneur laboutik_django
  └── cron  (6h, 14h, 18h UTC)
        └── /DjangoFiles/cron/dump_and_borg.sh
              ├── pg_dumpall  ──►  /Backup/dumps/<domaine>-M<migration>-<date>.sql.gz
              ├── borg create ──►  ssh://borgwarehouse@…  (dépôt distant, chiffré)
              └── borg prune       (rétention, voir plus bas)
```

- `./backup/` (hôte) est monté sur `/Backup` : les dumps y sont visibles, et
  effacés **au passage suivant du script** s'ils ont plus de 30 minutes — le dump
  de 6h01 reste donc là jusqu'à 14h01. Le log est dans `backup/backup.log`.
- `./ssh/` est monté sur `/home/tibillet/.ssh` : la clé privée du dépôt y vit.
- Les archives sont nommées `<domaine>-M<numéro de migration>-<date>`, ce qui
  indique quelle version du schéma une archive contient.

### Pourquoi il n'y a ni `~/.ssh/config` ni `BORG_RSH`

À partir de l'URL `ssh://borgwarehouse@hôte:2226/./c1ddd097`, borg construit
lui-même `ssh -p 2226 borgwarehouse@hôte`, et `ssh` trouve seul
`~/.ssh/id_ed25519` — un nom d'identité par défaut. Il ne manque qu'un
`known_hosts` pré-rempli, que `make backup` écrit avec `ssh-keyscan` : sans lui,
le `ssh` lancé par cron n'a pas de terminal pour demander confirmation et meurt
sur `Host key verification failed`, en silence.

---

## Première mise en place

### Ce qu'on te demandera

Dans cet ordre :

| Question | Défaut | Remarque |
|---|---|---|
| URL de borgwarehouse | `https://borgwarehouse.codecommun.coop` | `https://` obligatoire : le token y transite |
| Port SSH | `2226` | celui de borgwarehouse, pas celui du serveur |
| Token API | — | saisie masquée ; **vide = création manuelle** |
| Quota du dépôt, en Go | `10` | seulement si un token a été fourni |

**Le token n'a besoin que de la permission `create`** (*Account → Integrations*
sur borgwarehouse). C'est le seul appel que fait le script :
`POST /api/v1/repositories`. Tout le reste — `init`, `create`, `prune`, `list` —
passe par SSH avec la clé dédiée. Un token *create-only* qui fuiterait ne
permettrait ni de lister ni de supprimer tes dépôts.

Il n'est **jamais stocké**. Il est lu dans cet ordre :

```bash
BW_API_TOKEN=xxx make backup      # passage ponctuel
# puis la variable d'environnement borgwarehouse_ccc_api
# puis, à défaut, la saisie au clavier

borgwarehouse_ccc_api= make backup   # pour forcer la méthode manuelle
```

Sans token, le script affiche la clé publique et te laisse créer le dépôt dans
l'interface. Pense alors à **régler Alert toi-même sur 25 h (90000 s)** : c'est
l'API qui le fait automatiquement, pas l'interface.

### Le coffre-fort

Le script s'arrête et te demande de taper `OUI`. **C'est le seul maillon que la
sauvegarde ne peut pas se sauvegarder elle-même.** Quatre choses à mettre dans un
gestionnaire de mots de passe — pas dans un fichier sur ce serveur :

| | Pourquoi |
|---|---|
| **L'adresse du dépôt** | sans elle, on ne sait pas où sont les archives |
| **La passphrase** | sans elle, les archives sont un bloc chiffré illisible |
| **`borg key export`** | la clé du dépôt |
| **Le fichier `.env` en entier** | `FERNET_KEY` y chiffre **en base** les clés Stripe, Sunmi et Discovery (`APIcashless/models.py`). Sans lui, la base restaurée est amputée. `POSTGRES_PASSWORD` et `DJANGO_SECRET` y sont aussi. |
| **La clé privée `ssh/id_ed25519`** | c'est elle qui ouvre la connexion SSH au dépôt. À défaut, il faut un accès au compte borgwarehouse pour autoriser une nouvelle clé publique sur le dépôt (*Edit → SSH public key*). |

Tant que tu n'as pas tapé `OUI`, le bloc est **réaffiché à chaque `make backup`**.
Une fois acquitté, un témoin est posé dans `backup/.coffre-ok` ; pour revoir le
bloc, supprime ce fichier.

### Le redémarrage

Une fois SSH, borgwarehouse et `borg init` validés, le script **recrée le
conteneur `laboutik_django`** et te demande confirmation (la réponse par défaut
est *non*). C'est nécessaire : `.env_for_cron_backup`, le fichier que lit le
cron, est écrit au démarrage du conteneur à partir de son environnement —
écrire dans le `.env` ne suffit pas.

**L'application est coupée 30 à 60 secondes** (migrations, `collectstatic`,
redémarrage de gunicorn/daphne/celery). **Les TPE seront hors ligne pendant ce
temps.** Ne lance pas la première mise en place pendant un événement.

Le conteneur est recréé avec `--no-deps`, donc sans toucher à la base. En
contrepartie, le prochain `docker compose up -d` complet (celui de
`update-laboutik.sh`) recréera aussi `laboutik_postgres` et `laboutik_redis`,
dont l'empreinte `env_file` a changé : quelques secondes de base coupée à la
prochaine mise à jour.

### Sur borgwarehouse, après coup

Deux réglages sans lesquels l'alerte ne sert à rien :

1. *Account settings* → activer **Email alert** (désactivé par défaut).
2. Vérifier que l'instance borgwarehouse a bien un SMTP configuré.

L'alerte est réglée à **25 h**. Le cron tourne 3 fois par jour, son plus grand
intervalle est 18h → 6h, soit 12 h : 25 h laisse donc passer un échec isolé sans
crier, et prévient dès qu'une journée entière est manquée.

Le dépôt est créé en `appendOnlyMode: false`, parce que `dump_and_borg.sh` fait
un `borg prune` — qui a besoin de supprimer. Conséquence à connaître : quelqu'un
qui prendrait la main sur la caisse pourrait effacer les archives distantes.

---

## Au quotidien

### Lancer une sauvegarde à la main

```bash
make backup
```

Il détecte que tout est en place et sauvegarde directement, sans reposer les
questions de configuration. Il peut quand même demander deux choses : de
confirmer une recréation du conteneur si l'environnement du cron est périmé, et
l'acquittement du coffre s'il ne l'a jamais été.

Évite `06:01`, `14:01` et `18:01` **UTC** : le cron y tourne déjà, et deux borg
simultanés se disputent le verrou du dépôt.

### Ce que `make backup` vérifie, et que le cron ne vérifie pas

```
[backup] dump complet et coherent : cashless.exemple.org-M0263-…sql.gz
[backup] cadence correcte : l'archive precedente date de 8 h.
```

- **La première ligne** relit le dump et cherche le marqueur de fin de
  `pg_dumpall`. Voir « Le piège à connaître » plus bas.
- **La seconde** regarde l'âge de l'archive **précédente**. Au-delà de 26 h, les
  sauvegardes automatiques ne passent plus — c'est le seul contrôle qui attrape
  « le cron est mort depuis trois semaines ».

Le cron automatique ne fait **ni l'un ni l'autre** : il vient de l'image et n'a
pas été modifié. D'où l'intérêt d'un `make backup` à la main de temps en temps.

### Vérifier à la main

```bash
tail -f backup/backup.log                                    # le log du cron
docker compose exec laboutik_django bash -c \
  'source ~/.env_for_cron_backup; borg list "$BORG_REPO"'    # les archives
```

Et sur l'interface borgwarehouse : la date de dernière sauvegarde du dépôt.

### Rétention

Fixée dans `dump_and_borg.sh` (image LaBoutik) :

```
--keep-within=3d --keep-daily=60 --keep-weekly=4 --keep-monthly=-1 --keep-yearly=-1
```

Tout ce qui a moins de 3 jours, 60 quotidiennes, 4 hebdomadaires, puis **toutes**
les mensuelles et annuelles.

---

## Restaurer

> ⚠️ **Cette procédure n'a pas été rejouée en conditions réelles.** Fais-le une
> fois sur une instance jetable, avant d'en avoir besoin. Une sauvegarde dont on
> n'a jamais testé la restauration n'est pas une sauvegarde.

**Avant de commencer, il te faut le coffre** : l'adresse du dépôt, la passphrase,
la clé SSH privée (ou un accès borgwarehouse), et **le `.env` d'origine**. Ce
dernier n'est pas un confort : `pg_dumpall` rejoue `ALTER ROLE … PASSWORD`, donc
le mot de passe de la base redevient celui du dump. Avec un `.env` neuf, Django
ne se connecte plus — et sans l'ancienne `FERNET_KEY`, les clés Stripe, Sunmi et
Discovery stockées en base sont illisibles.

```bash
# 1. Lister les archives
docker compose exec laboutik_django bash -c \
  'source ~/.env_for_cron_backup; borg list "$BORG_REPO"'

# 2. Extraire une archive dans /Backup (visible dans ./backup côté hôte)
docker compose exec -w /Backup laboutik_django bash -c \
  'source ~/.env_for_cron_backup; borg extract "$BORG_REPO::<archive>"'
#    -> ./backup/Backup/dumps/<domaine>-M0263-<date>.sql.gz

# 3. Vérifier le dump AVANT de toucher à la base
zcat backup/Backup/dumps/<fichier>.sql.gz | tail -n 5
#    doit contenir : -- PostgreSQL database cluster dump complete

# 4. Repartir d'un cluster vierge, application arrêtée
docker compose stop laboutik_django laboutik_nginx
docker compose rm -sf laboutik_postgres
sudo rm -rf database/data        # sudo : le dossier appartient à l'uid du conteneur
docker compose up -d laboutik_postgres
docker compose logs -f laboutik_postgres   # attendre "ready to accept connections"

# 5. Recharger
zcat backup/Backup/dumps/<fichier>.sql.gz \
  | docker compose exec -T laboutik_postgres psql -U laboutik_user -d postgres \
  > restore.log 2>&1

# 6. VÉRIFIER — psql sort en 0 même quand tout a échoué
grep '^ERROR' restore.log | grep -v 'already exists'   # doit être VIDE
docker compose exec -T laboutik_postgres \
  psql -U laboutik_user -d laboutik -c '\dt' | head

# 7. Relancer, puis effacer le dump en clair
docker compose up -d
rm -rf backup/Backup
```

**L'étape 6 n'est pas optionnelle.** `psql` sans `ON_ERROR_STOP` ignore chaque
instruction en erreur et sort quand même en 0 : une restauration à moitié faite
ressemble exactement à une restauration réussie. Les seules erreurs normales sont
`role … already exists` et `database … already exists` — l'entrypoint postgres
les a créées avant toi.

Ne relance **jamais** `docker compose up -d` (complet) entre les étapes 4 et 5 :
`laboutik_django` exécuterait `migrate` puis `manage.py install` sur la base
vierge, et le rejeu du dump tomberait ensuite sur des tables déjà créées.

**Depuis une autre machine**, sans ce serveur : installe **borg 1.x** (borg 2 ne
lit pas les dépôts écrits par le borg 1.1 du conteneur), remets la clé privée du
coffre dans `~/.ssh/`, et rejoue `borg list` / `borg extract` avec l'adresse et
la passphrase du coffre.

---

## Quand ça ne marche pas

| Symptôme | Cause | Quoi faire |
|---|---|---|
| `Host key verification failed` dans `backup/backup.log` | `ssh/known_hosts` vide, ou clé d'hôte de borgwarehouse changée | vérifie la nouvelle empreinte, puis `ssh-keygen -R "[hôte]:2226" -f ssh/known_hosts` et `ssh-keyscan -p 2226 <hôte> \| grep -v '^#' >> ssh/known_hosts` |
| `Permission denied (publickey)` | la clé n'est plus autorisée sur le dépôt, ou `ssh/id_ed25519` n'appartient pas à l'uid du conteneur | recolle `ssh/id_ed25519.pub` sur le dépôt dans borgwarehouse (*Edit → SSH public key*) ; pour l'uid, `make backup` te donne la commande exacte |
| `HTTP 409` à la création du dépôt | cette clé publique est déjà utilisée par un dépôt | le dépôt existe déjà : `borgwarehouse_ccc_api= make backup` et colle son adresse |
| `Repository already exists` au `borg init` | le dépôt est initialisé, mais la passphrase du `.env` ne l'ouvre pas | remets la passphrase du coffre dans le `.env`, puis `make backup` (il recréera le conteneur pour que le cron la reprenne) |
| `Failed to create/acquire the lock` | un borg a été interrompu, ou deux sauvegardes simultanées | `docker compose exec laboutik_django bash -c 'source ~/.env_for_cron_backup; borg break-lock "$BORG_REPO"'` |
| `DUMP TRONQUE OU ILLISIBLE` | `pg_dumpall` a échoué (disque plein, postgres injoignable) alors que `gzip` a réussi | `docker compose logs laboutik_postgres` et `df -h`. **L'archive envoyée n'est pas restaurable.** |
| `l'archive precedente date de N h` | le cron ne passe plus depuis N heures | `tail -n 50 backup/backup.log` |
| Rien dans `backup/backup.log`, aucune archive | le démon cron ne tourne pas dans le conteneur | `docker compose restart laboutik_django`, puis `docker compose logs laboutik_django` |

### Le piège à connaître

`dump_and_borg.sh` fait `pg_dumpall | gzip` **sans `pipefail`**. Si `pg_dumpall`
échoue, `gzip` réussit quand même, `set -e` ne voit rien, et un `.sql.gz` de
quelques octets part dans borg. Côté borgwarehouse une écriture a bien eu lieu :
**l'alerte ne se déclenche pas.** On se retrouve avec une sauvegarde qui a l'air
parfaite et qui ne restaure rien.

C'est ce que `make backup` vérifie après chaque sauvegarde, en relisant le dump
laissé dans `backup/dumps/`.

---

## Fichiers

| Chemin | |
|---|---|
| `backup.sh` | la mise en place et le lancement (`make backup`) |
| `.env` | `BORG_REPO` et `BORG_PASSPHRASE`, en `chmod 600`, hors git |
| `.env.avant-backup` | copie faite avant toute écriture dans le `.env` |
| `ssh/id_ed25519` | clé privée du dépôt, hors git |
| `ssh/known_hosts` | clé d'hôte de borgwarehouse |
| `backup/dumps/` | dumps temporaires |
| `backup/backup.log` | le log du cron |
| `backup/.coffre-ok` | témoin d'acquittement du coffre-fort |

`.gitignore` couvre `.env*`, `ssh/` et `backup/`. **Ne les commite jamais** : ce
dépôt est cloné sur le serveur, et un `git add -A` distrait y pousserait la
passphrase et la clé privée.

---

## Une note sur `make setup-env`

> ⚠️ **Ne relance jamais `make setup-env` sur une instance en production.**
> Il régénère `POSTGRES_PASSWORD` (Django ne se connectera plus à la base
> existante), `FERNET_KEY` (les clés Stripe, Sunmi et Discovery stockées en base
> deviennent illisibles) et `DJANGO_SECRET`.

Ce qu'il ne casse **plus** : la configuration de sauvegarde. `BORG_REPO` et
`BORG_PASSPHRASE` sont désormais recopiés verbatim depuis l'ancien `.env`, et il
ne génère plus de passphrase — elle appartient à `make backup`. Régénérer une
passphrase sur une instance qui sauvegarde déjà rendrait **toutes ses archives
définitivement illisibles**, sans un mot d'avertissement.

La reprise n'a lieu que si un `.env` existait au moment du lancement : un
`.env.bak` laissé par une exécution précédente n'est jamais réutilisé.
