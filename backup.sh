#!/bin/bash
set -euo pipefail

##### INSTRUCTION
#
# Met en place, puis lance, la sauvegarde borg de cette instance LaBoutik vers
# un serveur borgwarehouse (BWH).  Lance par :  make backup
#
# UNE SEULE PORTE D'ENTREE, IDEMPOTENTE :
#   - sauvegarde deja configuree et depot joignable -> on sauvegarde, point.
#   - sinon -> mise en place complete, qui se termine par une vraie sauvegarde.
#
# ON NE REECRIT PAS LE MECANISME DE SAUVEGARDE : il existe deja et il vit dans
# l'image tibillet/laboutik. cron/cron_task (6h, 14h, 18h UTC) y lance
# cron/dump_and_borg.sh DANS le conteneur laboutik_django. Ce script ne fait que
# lui fournir ce qui lui manque : une cle SSH, un depot cree sur BWH,
# BORG_REPO / BORG_PASSPHRASE dans le .env, et le borg init.
#
# POURQUOI NI ~/.ssh/config NI BORG_RSH : borg construit lui-meme
# `ssh -p <port> borgwarehouse@<hote>` a partir de l'URL ssh://, et ssh trouve
# seul ~/.ssh/id_ed25519 (nom d'identite par defaut). Le dossier ./ssh est monte
# sur /home/tibillet/.ssh (docker-compose.yml) et cron pose HOME=/home/tibillet.
# Il ne manque qu'un known_hosts pre-rempli : sans lui le ssh du cron, qui n'a
# pas de terminal, meurt sur "Host key verification failed" — en silence, tout
# partant dans /Backup/backup.log que personne ne lit.
#
# REGLE ABSOLUE DE CE SCRIPT : on ne reecrit JAMAIS un BORG_REPO ou un
# BORG_PASSPHRASE deja presents dans le .env. Ils ne sont ecrits que lorsqu'on
# vient de les creer. Une passphrase perdue ou abimee, ce sont toutes les
# archives du depot qui deviennent illisibles, y compris celles deja chez BWH.
#
# TOKEN BWH : un seul appel API, le POST qui cree le depot. Un token avec la
# seule permission "create" suffit (Account > Integrations). Il n'est stocke
# nulle part. Lu dans l'ordre : BW_API_TOKEN, borgwarehouse_ccc_api, clavier.
#
# A LANCER SANS SUDO : sudo viderait borgwarehouse_ccc_api et creerait la cle
# SSH sous une identite que le conteneur ne pourra pas lire.
#####

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
SSH_DIR="$SCRIPT_DIR/ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
BACKUP_DIR="$SCRIPT_DIR/backup"
DUMPS_DIR="$BACKUP_DIR/dumps"
TEMOIN_COFFRE="$BACKUP_DIR/.coffre-ok"

SERVICE="laboutik_django"
SERVICE_NGINX="laboutik_nginx"
SCRIPT_CRON="/DjangoFiles/cron/dump_and_borg.sh"
ENV_CRON="/home/tibillet/.env_for_cron_backup"

BW_API_URL_DEFAUT="https://borgwarehouse.codecommun.coop"
BW_SSH_PORT_DEFAUT="2226"

# Alerte BWH, en secondes : 90000 = 25 h. Le cron tourne 3 fois par jour, son
# plus grand intervalle est 18h -> 6h, soit 12 h. 25 h laisse donc passer un
# echec isole sans crier, et alerte des qu'une journee entiere est manquee.
ALERTE=90000

# Au-dela de cet age, l'archive PRECEDENTE prouve que le cron ne tourne plus.
AGE_MAX_HEURES=26


dire()   { echo "[backup] $*"; }
erreur() { echo "[backup] ERREUR : $*" >&2; exit 1; }

demander() {  # demander <invite> [defaut] -> reponse sur stdout
  local invite="$1" defaut="${2:-}" reponse=""
  if [ -n "$defaut" ]; then
    read -r -p "$invite [$defaut] : " reponse || true
    echo "${reponse:-$defaut}"
  else
    read -r -p "$invite : " reponse || true
    echo "$reponse"
  fi
}

# Lit une valeur du .env. Tolere un prefixe `export`, retire uniquement les
# quotes ENCADRANTES (pas celles a l'interieur de la valeur) et un \r final.
# Une lecture qui abime la valeur est dangereuse : elle serait ensuite reecrite
# abimee par-dessus l'originale.
valeur_env() {  # valeur_env <CLE> -> valeur
  local v
  v="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\?$1[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -n1)"
  v="${v%$'\r'}"
  case "$v" in
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
  esac
  printf '%s' "$v"
}

# Ecrit une cle dans le .env EN PLACE : on ne recopie jamais le .env.template
# par-dessus un .env de production. Si la ligne n'existe pas (vieux .env sans le
# bloc borg), on l'ajoute — un simple sed n'aurait rien fait, sans rien dire.
#
# La valeur est echappee : un '&' dans un remplacement sed vaut "toute la ligne
# trouvee", et corromprait le fichier en y recopiant l'ancienne valeur au milieu
# de la nouvelle. On relit derriere pour ne pas croire une ecriture qui n'a pas
# eu lieu.
ecrire_env() {  # ecrire_env <CLE> <VALEUR>
  local cle="$1" val="$2" echappee
  echappee="$(printf '%s' "$val" | sed -e 's/[&|\\]/\\&/g')"
  if grep -q "^[[:space:]]*\(export[[:space:]]\+\)\?$cle[[:space:]]*=" "$ENV_FILE"; then
    sed -i "s|^[[:space:]]*\(export[[:space:]]\+\)\?$cle[[:space:]]*=.*|$cle='$echappee'|" "$ENV_FILE"
  else
    printf "%s='%s'\n" "$cle" "$val" >> "$ENV_FILE"
  fi
  [ "$(valeur_env "$cle")" = "$val" ] || erreur "echec d'ecriture de $cle dans $ENV_FILE.
         Une copie du fichier d'avant est dans $ENV_FILE.avant-backup"
}

# borg s'execute TOUJOURS dans le conteneur : c'est le seul endroit ou il est
# installe, c'est le meme binaire que celui du cron quotidien, et il y voit la
# cle SSH montee.
#
# BORG_REPO / BORG_PASSPHRASE sont passes explicitement : sans ca, borg ne les
# aurait que si le conteneur avait deja ete recree avec le nouveau .env, et un
# `borg init` sans passphrase la demanderait au clavier — le depot serait alors
# initialise avec une passphrase differente de celle du .env.
#
# Les deux BORG_*_OK et le </dev/null evitent que borg attende une reponse sur
# une question (depot relocalise) dont l'invite serait avalee par un 2>/dev/null
# — le script resterait bloque, ecran vide. dump_and_borg.sh:36-37 pose deja ces
# deux variables de son cote.
borg_conteneur() {
  docker compose exec -T \
    -e BORG_REPO="$BORG_REPO" \
    -e BORG_PASSPHRASE="$BORG_PASSPHRASE" \
    -e BORG_RELOCATED_REPO_ACCESS_IS_OK=yes \
    -e BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes \
    "$SERVICE" borg "$@" </dev/null
}


#### PREREQUIS ####
[ -t 0 ] || erreur "ce script est interactif (saisie du token, confirmations) : lance-le depuis un terminal."
[ -f "$ENV_FILE" ] || erreur ".env introuvable. Lance d'abord : make setup-env"

for outil in docker ssh-keygen ssh-keyscan openssl curl zcat; do
  command -v "$outil" >/dev/null || erreur "$outil introuvable dans le PATH."
done

# `docker compose ps -q` ne renvoie rien pour un conteneur arrete : le seul
# diagnostic honnete couvre les deux cas.
CID="$(docker compose ps -q "$SERVICE" 2>/dev/null || true)"
[ -n "$CID" ] || erreur "le conteneur $SERVICE n'existe pas, ou ne tourne pas.
         Demarre la stack d'abord :  docker compose up -d"

DOMAIN="$(valeur_env DOMAIN)"
[ -n "$DOMAIN" ] || erreur "DOMAIN est vide dans le .env. Lance d'abord : make setup-env"

BORG_REPO="$(valeur_env BORG_REPO)"
BORG_PASSPHRASE="$(valeur_env BORG_PASSPHRASE)"

# Le demon cron tourne-t-il ? C'est lui, et lui seul, qui declenchera les
# sauvegardes automatiques. Tout le reste de ce script peut reussir avec un cron
# mort : on ne s'en apercevrait qu'a la restauration.
#
# On lit /proc plutot que d'appeler pgrep, absent de l'image (pas de procps).
# `cat | grep` plutot que `grep -l /proc/*/comm` : ce dernier sort en 2 des
# qu'un processus disparait pendant le parcours, ce qui ferait annoncer un cron
# mort alors qu'il tourne.
cron_tourne() {
  docker compose exec -T "$SERVICE" \
    sh -c 'cat /proc/[0-9]*/comm 2>/dev/null | grep -qx cron' >/dev/null 2>&1
}

rapport_cron() {
  if cron_tourne; then
    dire "demon cron actif dans $SERVICE."
  else
    dire "ATTENTION : le demon cron ne tourne PAS dans $SERVICE."
    dire "Cette sauvegarde-ci a marche, mais AUCUNE sauvegarde automatique"
    dire "n'aura lieu. Redemarre :  docker compose restart $SERVICE"
  fi
}


#### CE QUI EST DEJA EN PLACE ####
CONFIGURE=0
if [ -n "$BORG_REPO" ] && [ -n "$BORG_PASSPHRASE" ] && [ -f "$SSH_KEY" ]; then
  dire "configuration trouvee dans le .env — je verifie le depot..."
  # On garde l'erreur borg : sans elle, une coupure reseau passagere serait
  # confondue avec un depot inexistant, et on basculerait dans le chemin de
  # mise en place alors que tout est deja en place.
  if ERR_BORG="$(borg_conteneur list --short "$BORG_REPO" 2>&1 >/dev/null)"; then
    CONFIGURE=1
    dire "depot joignable : $BORG_REPO"
  else
    dire "le depot ne repond pas. Reponse de borg :"
    printf '%s\n' "$ERR_BORG" | sed 's/^/         /'
    dire "je termine la mise en place (aucune valeur existante ne sera reecrite)."
  fi
fi


#### LE COFFRE-FORT ####
# Reaffiche tant qu'il n'a pas ete acquitte. Sans ces elements, les archives
# sont un bloc chiffre illisible : c'est le seul maillon que la sauvegarde ne
# peut pas se sauvegarder elle-meme.
# `borg key export DEPOT` sans chemin n'ecrit sur stdout qu'a partir de borg
# 1.2. Le conteneur tourne sur Debian bullseye, donc borg 1.1.16, ou le chemin
# est OBLIGATOIRE : sans lui, "output file to export key to expected". On exporte
# donc vers un fichier temporaire DANS le conteneur, on l'affiche, on l'efface —
# ca marche sur les deux versions, et la cle ne touche jamais le disque de
# l'hote.
exporter_cle() {
  local f="/tmp/borg-key-$$.txt"
  borg_conteneur key export "$BORG_REPO" "$f" >/dev/null || return 1
  docker compose exec -T "$SERVICE" sh -c "cat '$f'; rm -f '$f'"
}

coffre_fort() {
  [ -f "$TEMOIN_COFFRE" ] && return 0

  echo
  echo "================================================================"
  echo " A METTRE DANS UN COFFRE-FORT NUMERIQUE, MAINTENANT."
  echo
  echo " Sans ces elements, les archives sont un bloc chiffre"
  echo " definitivement illisible, et la base restauree serait"
  echo " inutilisable."
  echo "================================================================"
  echo
  echo "Instance   : $DOMAIN"
  echo "Depot      : $BORG_REPO"
  echo "Passphrase : $BORG_PASSPHRASE"
  echo
  echo "Cle du depot (borg key export) :"
  echo "----------------------------------------------------------------"
  exporter_cle || {
    echo "  (export indisponible — voir le message ci-dessus)"
    echo
    echo "  Ce n'est pas bloquant : le depot est en repokey-blake2, la cle est"
    echo "  DANS le depot. L'adresse et la passphrase ci-dessus suffisent a"
    echo "  restaurer. La cle exportee n'est qu'une ceinture supplementaire."
  }
  echo "----------------------------------------------------------------"
  echo
  echo "ET AUSSI, indispensables le jour ou ce serveur n'existe plus :"
  echo
  echo "  * le fichier  $ENV_FILE  en entier."
  echo "    FERNET_KEY y chiffre en base les cles Stripe, Sunmi et Discovery :"
  echo "    sans lui, la base restauree est amputee. POSTGRES_PASSWORD et"
  echo "    DJANGO_SECRET y sont aussi."
  echo
  echo "  * la cle privee  $SSH_KEY"
  echo "    C'est elle qui ouvre la connexion SSH au depot. A defaut, il faudra"
  echo "    un acces au compte borgwarehouse pour autoriser une nouvelle cle"
  echo "    publique sur le depot (Edit > SSH public key)."
  echo
  if [ "$(demander "Tape OUI quand TOUT est copie au coffre" "")" = "OUI" ]; then
    mkdir -p "$BACKUP_DIR"
    date +"acquitte le %Y-%m-%d %H:%M:%S" > "$TEMOIN_COFFRE"
    dire "coffre acquitte. Ce bloc ne sera plus reaffiche."
    dire "(pour le revoir : rm $TEMOIN_COFFRE)"
  else
    dire "PAS acquitte : ce bloc sera reaffiche au prochain make backup."
  fi
}


#### LA SAUVEGARDE ELLE-MEME ####

# Le dump vient d'etre ecrit dans ./backup/dumps (monte sur /Backup). On le lit
# avant que le passage suivant de dump_and_borg.sh ne l'efface.
#
# Pourquoi ce controle : dump_and_borg.sh fait `pg_dumpall | gzip` sans
# pipefail. Si pg_dumpall echoue, gzip reussit, `set -e` ne voit rien, et un
# .sql.gz de quelques octets part dans borg. Cote borgwarehouse une ecriture a
# bien eu lieu : l'alerte ne se declenchera pas. On aurait une sauvegarde qui a
# l'air parfaite et qui ne restaure rien.
#
# Le `|| true` est essentiel : sur un .gz TRONQUE, zcat sort en erreur, et sans
# lui pipefail tuerait le script avant d'afficher le message d'alerte — c'est-a-
# dire exactement dans le cas ou l'alerte compte le plus (disque plein).
verifier_dump() {
  local dump fin
  dump="$(ls -t "$DUMPS_DIR"/*.sql.gz 2>/dev/null | head -n1 || true)"
  [ -n "$dump" ] || erreur "aucun dump dans $DUMPS_DIR : le dump n'a pas eu lieu."

  fin="$(zcat "$dump" 2>/dev/null | tail -n 5 || true)"
  if printf '%s\n' "$fin" | grep -q '^-- PostgreSQL database cluster dump complete'; then
    dire "dump complet et coherent : $(basename "$dump")"
  else
    erreur "DUMP TRONQUE OU ILLISIBLE : $(basename "$dump")
         Le marqueur de fin de pg_dumpall est absent. L'archive vient de partir
         chez BWH, mais elle N'EST PAS restaurable.
         Regarde  docker compose logs laboutik_postgres  et l'espace disque."
  fi
}

# Le seul controle qui attrape "le cron est mort depuis trois semaines".
# rapport_cron dit si le demon tourne, pas si les sauvegardes passent ; et
# personne ne lit backup/backup.log. L'archive PRECEDENTE, elle, ne ment pas.
verifier_cadence() {
  local precedente age_h
  precedente="$(borg_conteneur list --format '{time:%Y-%m-%d %H:%M:%S}{NL}' "$BORG_REPO" 2>/dev/null \
                | tail -n 2 | head -n 1 || true)"
  if [ -z "$precedente" ]; then
    dire "premiere archive du depot : pas de cadence a verifier."
    return 0
  fi
  age_h=$(( ( $(date +%s) - $(date -d "$precedente" +%s) ) / 3600 ))
  if [ "$age_h" -le "$AGE_MAX_HEURES" ]; then
    dire "cadence correcte : l'archive precedente date de ${age_h} h."
  else
    dire "ATTENTION : l'archive precedente date de ${age_h} h (seuil ${AGE_MAX_HEURES} h)."
    dire "Les sauvegardes AUTOMATIQUES ne passent plus. Regarde :"
    dire "  tail -n 50 backup/backup.log"
  fi
}

sauvegarder() {
  echo
  dire "sauvegarde en cours ($SCRIPT_CRON dans le conteneur)..."
  docker compose exec -T "$SERVICE" bash "$SCRIPT_CRON"
  echo
  verifier_dump
  verifier_cadence
  echo
  dire "dernieres archives du depot :"
  # Purement informatif : un listage qui echoue ne doit pas faire passer une
  # sauvegarde reussie pour un echec.
  borg_conteneur list "$BORG_REPO" 2>&1 | tail -n 5 || dire "(listage indisponible)"
}

# .env_for_cron_backup est ecrit par start_services.sh AU DEMARRAGE du
# conteneur, a partir de son environnement. Ecrire dans le .env ne suffit donc
# pas : tant que le conteneur n'a pas ete recree, le cron garde les anciennes
# valeurs. On compare les DEUX : un depot identique avec une passphrase perimee
# donne un cron qui echoue en silence toutes les nuits.
env_cron_a_jour() {
  local vals
  vals="$(docker compose exec -T "$SERVICE" \
            bash -c "source $ENV_CRON 2>/dev/null; printf '%s\n%s' \"\$BORG_REPO\" \"\$BORG_PASSPHRASE\"" \
            2>/dev/null | tr -d '\r')"
  [ "$vals" = "$(printf '%s\n%s' "$BORG_REPO" "$BORG_PASSPHRASE")" ]
}

recreer_conteneur() {
  echo
  dire "Le conteneur $SERVICE doit etre recree pour que le cron reprenne la"
  dire "nouvelle configuration."
  echo
  dire "TOUTE L'APPLICATION SERA COUPEE 30 A 60 s, le temps des migrations et du"
  dire "collectstatic. Supervisor pilote dans ce conteneur :"
  dire "  - gunicorn (8000) : interfaces de vente, admin, kiosk"
  dire "  - daphne   (8001) : tous les websockets"
  dire "  - celery / celerybeat : les taches de fond"
  echo
  dire "SURTOUT : PAS PENDANT QU'UNE CARTE EST PRESENTEE SUR LE TPE. La tache"
  dire "celery qui surveille l'intention de paiement Stripe (htmxview/tasks.py)"
  dire "serait tuee en plein vol, et le paiement resterait en suspens."
  # Defaut volontairement "non" : c'est la seule question du script qui coupe la
  # production, elle ne doit pas pouvoir repondre oui toute seule sur une Entree
  # ou un Ctrl-D.
  [ "$(demander "Continuer ? (oui/non)" "non")" = "oui" ] \
    || erreur "abandon. Relance make backup quand tu peux couper l'application."

  # --no-deps : sans lui, compose converge aussi laboutik_postgres et
  # laboutik_redis. Ils ont `env_file: .env`, dont l'empreinte change des qu'on
  # y ecrit BORG_* : la base redemarrerait, pour rien.
  docker compose up -d --no-deps "$SERVICE"

  # nginx resout laboutik_django:8000 a son propre demarrage. Le conteneur
  # recree peut avoir une autre IP : sans ce restart, nginx rend des 502.
  docker compose restart "$SERVICE_NGINX"

  # On attend que l'application soit prete, pas seulement que le fichier existe :
  # start_services.sh ecrit .env_for_cron_backup dans la premiere seconde, mais
  # lance ensuite migrate et collectstatic. Lancer pg_dumpall pendant les
  # migrations donnerait au mieux un dump qui attend des verrous, au pire un
  # dump rate sur une table supprimee en cours de route. supervisor ne demarre
  # gunicorn qu'apres les migrations : le port 8000 qui s'ouvre est le signal.
  #
  # On presente le DOMAIN du .env comme en-tete Host. En production,
  # Cashless/settings.py fait  ALLOWED_HOSTS = [DOMAIN]  : une requete sur
  # http://localhost:8000/ est REJETEE, journalisee en ERROR par
  # django.security.DisallowedHost, et remonte dans Sentry a chaque recreation
  # de conteneur. Avec le bon Host, la requete est legitime — et elle prouve que
  # Django SERT, pas seulement que la socket de gunicorn est ouverte.
  #
  # On se connecte sur 127.0.0.1 et non sur le domaine : on veut savoir si
  # l'application est prete, pas si le DNS public et Traefik repondent.
  dire "attente de la fin des migrations (Django doit repondre)..."
  local i=0
  until docker compose exec -T "$SERVICE" \
          curl -s -o /dev/null -H "Host: $DOMAIN" http://127.0.0.1:8000/ 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 90 ] || erreur "Django ne repond toujours pas sur le port 8000 apres 3 min.
         Regarde :  docker compose logs $SERVICE"
    sleep 2
  done

  env_cron_a_jour || erreur "$ENV_CRON ne contient toujours pas la configuration attendue
         apres recreation. Regarde :  docker compose logs $SERVICE"
  dire "conteneur pret."
}


#### CHEMIN COURT : tout est en place, on sauvegarde ####
if [ "$CONFIGURE" = 1 ]; then
  env_cron_a_jour || recreer_conteneur
  coffre_fort
  sauvegarder
  echo
  rapport_cron
  dire "termine."
  exit 0
fi


#### 1. CLE SSH ####
# Nom volontairement par defaut : ssh la trouve seul dans ~/.ssh, donc
# dump_and_borg.sh n'a besoin d'aucune configuration.
echo
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

CLE_NEUVE=0
if [ -f "$SSH_KEY" ]; then
  dire "cle SSH existante reutilisee : $SSH_KEY"
else
  ssh-keygen -t ed25519 -N '' -C "laboutik-$DOMAIN" -f "$SSH_KEY" >/dev/null
  CLE_NEUVE=1
  dire "cle SSH generee : $SSH_KEY"
fi
chmod 600 "$SSH_KEY"

# La cle est creee par l'utilisateur de l'hote, mais elle est lue par tibillet
# dans le conteneur. Un 0600 appartenant a un autre uid lui est illisible : ssh
# echoue en "Permission denied (publickey)" sans jamais dire que le probleme est
# un droit de fichier.
#
# On refuse d'aller plus loin plutot que de chown : un chown vers l'uid du
# conteneur rendrait ssh/ inaccessible a l'hote, et TOUTES les executions
# suivantes de ce script echoueraient sans issue. ssh exige un 0600 appartenant
# a celui qui l'utilise : il n'existe pas de mode qui satisfasse les deux uid.
UID_CONTENEUR="$(docker compose exec -T "$SERVICE" id -u | tr -d '\r')"
UID_SSH="$(stat -c %u "$SSH_KEY")"
if [ "$UID_SSH" != "$UID_CONTENEUR" ]; then
  erreur "la cle $SSH_KEY appartient a l'uid $UID_SSH, mais le conteneur tourne
         en uid $UID_CONTENEUR : elle lui serait illisible.
         Relance make backup depuis un compte dont l'uid vaut $UID_CONTENEUR
         (et surtout PAS avec sudo)."
fi

# Cas tordu mais reel : le .env designe un depot, mais la cle a disparu. On en
# regenere une — il faut alors l'autoriser a la main sur le depot existant.
if [ -n "$BORG_REPO" ] && [ "$CLE_NEUVE" = 1 ]; then
  echo
  dire "ATTENTION : le .env designe deja un depot, mais la cle SSH avait disparu."
  dire "Le depot BWH n'autorise que l'ANCIENNE cle. Va coller celle-ci sur le"
  dire "depot existant (Edit > SSH public key) avant de continuer :"
  echo
  cat "${SSH_KEY}.pub"
  echo
  [ "$(demander "Tape OUI quand c'est fait" "")" = "OUI" ] || erreur "abandon."
fi


#### 2. LE SERVEUR BORGWAREHOUSE ####
echo
if [ -n "$BORG_REPO" ]; then
  # Reprise : hote et port se deduisent de l'adresse du depot.
  dire "depot repris du .env : $BORG_REPO"
  reste="${BORG_REPO#ssh://}"
  reste="${reste#*@}"
  HOTE_BWH="${reste%%[:/]*}"
  case "$reste" in
    *:*) BW_SSH_PORT="${reste#*:}"; BW_SSH_PORT="${BW_SSH_PORT%%/*}" ;;
    *)   BW_SSH_PORT="22" ;;
  esac
  dire "hote : $HOTE_BWH, port SSH : $BW_SSH_PORT"
else
  BW_API_URL="$(demander "URL de borgwarehouse" "$BW_API_URL_DEFAUT")"
  # Sans https, le token partirait en clair sur le reseau.
  case "$BW_API_URL" in
    https://*) : ;;
    *) erreur "l'URL doit commencer par https:// (le token API y transite)." ;;
  esac
  BW_SSH_PORT="$(demander "Port SSH de borgwarehouse" "$BW_SSH_PORT_DEFAUT")"
  HOTE_BWH="$(printf '%s' "$BW_API_URL" | sed -e 's#^https://##' -e 's#/.*##' -e 's#:.*##')"
  [ -n "$HOTE_BWH" ] || erreur "URL borgwarehouse invalide : $BW_API_URL"
fi


#### 3. KNOWN_HOSTS ####
# Le ssh lance par cron n'a pas de terminal : sans cette entree il refuse la
# connexion et la sauvegarde meurt en silence dans /Backup/backup.log.
touch "$KNOWN_HOSTS"
chmod 644 "$KNOWN_HOSTS"

# ssh-keyscan ecrit AUSSI des lignes de commentaire "# hote:port SSH-2.0-..."
# sur sa sortie standard. Sans le filtre, elles s'accumuleraient dans
# known_hosts a chaque passage, et surtout le test de non-vacuite ci-dessous
# passerait alors qu'aucune CLE n'a ete recuperee.
SCAN="$(ssh-keyscan -p "$BW_SSH_PORT" "$HOTE_BWH" 2>/dev/null | grep -v '^[[:space:]]*#' || true)"
[ -n "$SCAN" ] || erreur "ssh-keyscan n'a recupere aucune cle pour $HOTE_BWH:$BW_SSH_PORT.
         Hote injoignable, ou port SSH incorrect ?"

while IFS= read -r ligne; do
  [ -n "$ligne" ] || continue
  grep -qxF "$ligne" "$KNOWN_HOSTS" || printf '%s\n' "$ligne" >> "$KNOWN_HOSTS"
done <<< "$SCAN"
dire "cle d'hote de $HOTE_BWH:$BW_SSH_PORT enregistree dans $KNOWN_HOSTS"


#### 4. PASSPHRASE ####
# Generee UNIQUEMENT si absente. Une passphrase deja presente n'est ni relue de
# travers ni reecrite : on ne la touche pas du tout (voir etape 6).
PASSPHRASE_NEUVE=0
if [ -z "$BORG_PASSPHRASE" ]; then
  BORG_PASSPHRASE="$(openssl rand -base64 32)"
  PASSPHRASE_NEUVE=1
  dire "passphrase generee."
else
  dire "passphrase deja presente dans le .env : laissee intacte."
fi


#### 5. CREATION DU DEPOT SUR BORGWAREHOUSE ####
# Rien ne doit s'intercaler entre l'appel API et l'ecriture du .env : un depot
# cree dont on perdrait l'adresse laisserait une cle publique deja consommee
# cote BWH, et le rejeu prendrait un 409.
REPO_NEUF=0
if [ -z "$BORG_REPO" ]; then
  REPO_NEUF=1
  echo
  dire "Creation du depot sur borgwarehouse."
  dire "Un token API automatise cette etape (Account > Integrations)."
  dire "La permission 'create' SEULE suffit : c'est le seul appel qu'on fait."
  dire "Sans token, tu creeras le depot a la main dans l'interface."
  echo

  BW_API_TOKEN="${BW_API_TOKEN:-${borgwarehouse_ccc_api:-}}"
  if [ -n "$BW_API_TOKEN" ]; then
    dire "token trouve dans l'environnement : creation automatique."
    dire "(pour forcer la methode manuelle :  borgwarehouse_ccc_api= make backup)"
  else
    read -r -s -p "[backup] Token API BWH, permission 'create' (vide = methode manuelle) : " BW_API_TOKEN || true
    echo
  fi

  if [ -n "${BW_API_TOKEN:-}" ]; then
    # storageSize doit etre un entier JSON non quote, strictement positif.
    while true; do
      QUOTA="$(demander "Quota du depot, en Go" "10")"
      case "$QUOTA" in
        ''|*[!0-9]*) echo "  Entier attendu." ;;
        0)           echo "  Doit etre superieur a 0." ;;
        *)           break ;;
      esac
    done

    REPONSE="$(mktemp)"
    trap 'rm -f "$REPONSE"' EXIT

    dire "POST $BW_API_URL/api/v1/repositories"
    # Pas de --fail-with-body : il exige curl >= 7.76, absent d'Ubuntu 20.04
    # (7.68) et de Debian 11 (7.74), ou curl mourrait sur "unknown option"
    # avant meme d'appeler l'API.
    CODE="$(curl -sS -o "$REPONSE" -w '%{http_code}' -X POST "$BW_API_URL/api/v1/repositories" \
      -H "Authorization: Bearer $BW_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary @- <<EOF
{
  "alias": "$DOMAIN",
  "sshPublicKey": "$(cat "${SSH_KEY}.pub")",
  "storageSize": $QUOTA,
  "comment": "LaBoutik — cree par make backup",
  "alert": $ALERTE,
  "lanCommand": false,
  "appendOnlyMode": false
}
EOF
    )" || erreur "impossible de joindre $BW_API_URL. Rien n'est perdu : relance make backup."

    if [ "$CODE" != "200" ] && [ "$CODE" != "201" ]; then
      echo "--- reponse de l'API ---" >&2
      cat "$REPONSE" >&2
      echo >&2
      echo "------------------------" >&2
      case "$CODE" in
        401|403) erreur "token refuse (HTTP $CODE). Verifie qu'il a la permission 'create'." ;;
        409)     erreur "HTTP 409 : cette cle publique est deja utilisee par un depot BWH.
         Le depot existe donc deja : recupere son adresse sur BWH et relance en
         methode manuelle :   borgwarehouse_ccc_api= make backup" ;;
        *)       erreur "l'API BWH a repondu HTTP $CODE. Rien n'est perdu : relance make backup." ;;
      esac
    fi

    NOM_DEPOT="$(sed -n 's/.*"repositoryName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$REPONSE")"
    [ -n "$NOM_DEPOT" ] || erreur "reponse inattendue de l'API : $(cat "$REPONSE")"

    # L'adresse SSH n'est pas dans la reponse : elle est deterministe.
    BORG_REPO="ssh://borgwarehouse@$HOTE_BWH:$BW_SSH_PORT/./$NOM_DEPOT"
    dire "depot cree : $NOM_DEPOT"
  else
    echo
    dire "Sur $BW_API_URL :"
    dire "  1. New repository"
    dire "  2. colle la cle publique ci-dessous"
    dire "  3. regle Alert sur 25 h (90000 s) — c'est elle qui previendra"
    dire "     si une sauvegarde manque"
    dire "  4. copie l'adresse SSH du depot (icone en haut a droite de sa vignette)"
    echo
    cat "${SSH_KEY}.pub"
    echo
  fi

  BORG_REPO="$(demander "Adresse SSH du depot" "$BORG_REPO")"
  case "$BORG_REPO" in
    ssh://*) : ;;
    *) erreur "adresse invalide : elle doit commencer par ssh://" ;;
  esac
fi


#### 6. ECRITURE DU .ENV ####
# On n'ecrit QUE ce qu'on vient de creer. Une valeur deja presente n'est jamais
# relue puis reecrite : ce trajet aller-retour abimerait une passphrase
# contenant une quote, un commentaire de fin de ligne ou un caractere special,
# et une passphrase abimee rend TOUTES les archives illisibles.
cp -p "$ENV_FILE" "$ENV_FILE.avant-backup"
dire "copie de securite : $ENV_FILE.avant-backup"

if [ "$REPO_NEUF" = 1 ]; then
  ecrire_env BORG_REPO "$BORG_REPO"
  dire "BORG_REPO ecrit dans le .env."
else
  dire "BORG_REPO deja dans le .env : inchange."
fi

if [ "$PASSPHRASE_NEUVE" = 1 ]; then
  ecrire_env BORG_PASSPHRASE "$BORG_PASSPHRASE"
  dire "BORG_PASSPHRASE ecrite dans le .env."
else
  dire "BORG_PASSPHRASE deja dans le .env : inchangee."
fi

chmod 600 "$ENV_FILE"


#### 7. INIT DU DEPOT ####
# Dans le conteneur, avec le meme borg que le cron : ca valide du meme coup que
# le conteneur atteint bien BWH avec la cle montee et le known_hosts.
if borg_conteneur list "$BORG_REPO" >/dev/null 2>&1; then
  dire "depot deja initialise."
else
  dire "initialisation du depot (repokey-blake2)..."
  borg_conteneur init -e repokey-blake2 "$BORG_REPO"
fi


#### 8. LE COFFRE-FORT ####
coffre_fort


#### 9. LE CONTENEUR PREND LA NOUVELLE CONFIG ####
# En dernier, une fois SSH, BWH et borg init prouves : c'est la seule etape qui
# coupe la production.
env_cron_a_jour || recreer_conteneur


#### 10. PREMIERE SAUVEGARDE, POUR DE VRAI ####
sauvegarder


#### FIN ####
echo
dire "Sauvegarde en place. Le cron du conteneur prend le relais a 6h, 14h et 18h UTC."
echo
echo "  Deux choses a faire sur borgwarehouse, sinon l'alerte ne servira a rien :"
echo "    1. Account settings > active 'Email alert' (desactive par defaut)."
echo "    2. Verifie que l'instance BWH a bien un SMTP configure."
echo "  Sans ces deux points, un cron qui meurt ne previendra personne."
echo
echo "  Pour relancer une sauvegarde a la main :  make backup"
echo "  (evite 06:01, 14:01 et 18:01 UTC : le cron y tourne deja)"
echo
rapport_cron
