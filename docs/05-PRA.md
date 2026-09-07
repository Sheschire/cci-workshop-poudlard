# 05 — Plan de reprise d'activité (PRA)

Ce document est celui que le sujet demande explicitement : **les mesures de
sauvegarde et de reprise d'activité, expliquées en détail**.

Il répond à quatre questions :

1. Que sauvegarde-t-on, avec quel outil, et pourquoi celui-là ?
2. Combien de données peut-on perdre, et combien de temps pour repartir ?
3. Comment restaure-t-on, concrètement, commande par commande ?
4. Comment sait-on que le plan fonctionne réellement ?

---

## 1. Ce qui est sauvegardé

### Le principe : chaque moteur avec son propre outil

**On ne copie jamais des fichiers de base de données pendant qu'un serveur
écrit dedans.** Copier `/var/lib/mysql` à chaud produit une sauvegarde qui se
restaure… parfois. C'est le pire des cas : on croit être protégé, et on
découvre le contraire le jour où on en a besoin.

Chaque moteur possède un outil qui produit un instantané **cohérent**. Ce sont
ceux-là qu'utilise [`scripts/backup.sh`](../scripts/backup.sh).

| Donnée | Outil | Pourquoi celui-là |
|---|---|---|
| **MariaDB** | `mariadb-dump --single-transaction` | Ouvre une transaction cohérente au lieu de verrouiller les tables : GLPI continue de fonctionner pendant la sauvegarde |
| **Elasticsearch** | API `_snapshot` | Incrémental et cohérent, géré par le moteur lui-même |
| **Cassandra** | `nodetool snapshot` | Vide les tampons sur disque puis crée des **liens durs** : instantané, sans copier un octet |
| **Volumes de fichiers** | archive `tar` | Données inertes, aucun serveur n'écrit dedans |
| **Configuration** | archive `tar` | Contient `.env`, `certs/` et `secrets/`, absents de git |

### Le contenu d'une sauvegarde

```
backups/2026-09-07_03-00-00/
├── mariadb.sql.gz                  base GLPI complète (tickets, parc, comptes)
├── elasticsearch-snapshot.json     compte rendu du snapshot
├── elasticsearch-snapshots.tar.gz  le dépôt de snapshots
├── cassandra-snapshot.tar.gz       les fichiers du datalake
├── glpi_files.tar.gz               documents joints aux tickets
├── glpi_config.tar.gz              configuration ET CLÉ DE CHIFFREMENT
├── glpi_plugins.tar.gz             extensions
├── glpi_marketplace.tar.gz         extensions
├── grafana_data.tar.gz             comptes et préférences Grafana
├── configuration.tar.gz            .env, certs/, secrets/, compose, config/
├── SHA256SUMS                      empreintes de chaque archive
└── MANIFESTE.txt                   date, hôte, taille, commande de restauration
```

Volume typique d'une plateforme peu chargée : **150 à 400 Mo**.

### Trois points qui font la différence le jour J

> **`glpi_config` contient la clé de chiffrement de GLPI.** Sans elle, tous les
> mots de passe enregistrés dans l'application — annuaire LDAP, serveur SMTP,
> comptes d'inventaire — sont **irrécupérables**, même avec une base de données
> parfaitement restaurée. Beaucoup de sauvegardes GLPI ne contiennent que le
> dump SQL, et l'oubli ne se découvre qu'à la restauration.

> **`configuration.tar.gz` contient `.env`, `certs/` et `secrets/`**, qui ne sont
> pas dans git. S'ils ne sont pas dans la sauvegarde, ils n'existent nulle part
> ailleurs. L'archive est en droits `600` pour cette raison.

> **`--routines --events --triggers`** sur le dump MariaDB : sans ces options,
> les procédures stockées et les tâches planifiées sont silencieusement perdues.
> On ne s'en aperçoit qu'après restauration, quand des fonctions cessent de
> marcher sans erreur explicite.

### Ce qui n'est délibérément pas sauvegardé

**`prometheus_data`** — 30 jours de métriques. Ce sont des données
d'observation, pas des données métier : leur perte n'empêche personne de
travailler, et elles se reconstituent d'elles-mêmes en quelques minutes après
redémarrage. Les sauvegarder représenterait le plus gros volume du lot pour la
valeur la plus faible. Le tableau de bord Grafana, lui, est versionné dans le
dépôt — c'est ce qui compte.

**`es_data`** — les index Elasticsearch ne sont pas archivés directement : c'est
le **dépôt de snapshots** qui l'est. Copier `es_data` à chaud produirait des
index corrompus.

---

## 2. Objectifs : RPO et RTO

Deux chiffres définissent un PRA, et il faut être capable de les annoncer.

**RPO — *Recovery Point Objective*** : quelle quantité de données on accepte de
perdre. C'est l'intervalle entre deux sauvegardes.

**RTO — *Recovery Time Objective*** : combien de temps le service reste
indisponible avant d'être remis en marche.

| Scénario | RPO | RTO | Ce qu'on fait |
|---|---|---|---|
| Un service plante | **0** | **< 1 min** | Rien : `restart: unless-stopped` s'en charge |
| Un conteneur corrompu | **0** | **~ 5 min** | `docker compose up -d --force-recreate <service>` |
| Perte d'un volume | 24 h | **~ 20 min** | Restauration partielle (§3.2) |
| Perte de toutes les données | 24 h | **~ 45 min** | Restauration complète (§3.3) |
| Perte de la machine | 24 h | **~ 90 min** | Reconstruction sur une nouvelle machine (§3.4) |

**Le RPO de 24 h suppose une sauvegarde quotidienne** (§4). Il se réduit
mécaniquement en augmentant la fréquence : une sauvegarde toutes les 6 heures
donne un RPO de 6 heures, au prix de quatre fois plus d'espace disque.

Les RTO annoncés sont des **majorants pour une plateforme en production**. Sur
une installation neuve, l'exercice réel (§5) a mesuré **1 min 59 s** pour une
restauration complète après destruction de tous les volumes. Le temps grandit
avec le volume de données, l'étape déterminante étant le rejeu du dump MariaDB.
Mieux vaut annoncer un RTO tenable que le meilleur chiffre observé.

---

## 3. Les procédures de reprise

### 3.1 — Sauvegarder

```bash
make backup                          # dans backups/<horodatage>/
./scripts/backup.sh /mnt/nas         # ailleurs
RETENTION=14 ./scripts/backup.sh     # conserver 14 sauvegardes au lieu de 7
```

Le script **échoue explicitement** plutôt que de produire une sauvegarde
inutilisable : il refuse un dump MariaDB vide (un dump raté fait 20 octets et ne
lève aucune erreur), et il vérifie que le snapshot Elasticsearch s'est bien
terminé en `SUCCESS`. Une sauvegarde qui échoue bruyamment vaut infiniment mieux
qu'une sauvegarde qui réussit à moitié.

Il purge aussi le snapshot Cassandra après l'avoir archivé : les liens durs
retiennent l'espace disque des fichiers compactés, et sans cette purge le volume
grossit à chaque sauvegarde.

### 3.2 — Restaurer un seul service

Le cas le plus fréquent, et le plus rapide. Exemple avec GLPI :

```bash
docker compose stop glpi

# La base
gunzip -c backups/2026-09-07_03-00-00/mariadb.sql.gz \
  | docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'

# Les fichiers
docker run --rm -v dockerwarts_glpi_files:/target \
  -v "$PWD/backups/2026-09-07_03-00-00:/backup:ro" alpine:3.22 \
  sh -c 'rm -rf /target/* && tar xzf /backup/glpi_files.tar.gz -C /target'

docker compose up -d glpi
make verify
```

**RTO : environ 20 minutes.** Les autres services ne sont pas interrompus.

### 3.3 — Restauration complète

```bash
make restore FROM=backups/2026-09-07_03-00-00
```

Le script [`restore.sh`](../scripts/restore.sh) déroule dans l'ordre :

| # | Étape | Détail |
|---|---|---|
| 0 | **Vérification des empreintes** | `sha256sum -c` — s'arrête AVANT de rien détruire si la sauvegarde est corrompue |
| 1 | Confirmation | Il faut taper « restaurer » |
| 2 | `docker compose down` | Rien ne doit écrire pendant la restauration |
| 3 | Volumes de fichiers | Vidés puis remplis depuis les archives |
| 4 | Dépôt Elasticsearch | Volume `es_data` recréé, dépôt de snapshots replacé et `chown` en uid 1000 |
| 5 | MariaDB | Volume recréé vierge, puis rejeu du dump |
| 6 | Elasticsearch | Nœud neuf démarré, dépôt redéclaré, index fermés, snapshot restauré |
| 7 | Cassandra | Nœud démarré, **schéma recréé d'abord**, SSTables replacées dans les répertoires réels, `chown` en uid 999, `nodetool refresh` |
| 8 | `docker compose up -d` | Tout repart |

**RTO : environ 45 minutes** en production ; **1 min 59 s** mesurées sur
l'installation de démonstration (§5).

Trois décisions de conception méritent explication :

> **L'intégrité est vérifiée en premier, avant toute destruction.** Restaurer
> depuis une archive corrompue après avoir effacé les données en place est la
> façon la plus sûre de transformer un incident en catastrophe.

> **Les volumes sont vidés avant d'être remplis.** Sans cela, des fichiers de
> l'ancienne installation survivent dans la nouvelle et produisent des
> incohérences qu'on découvre des semaines plus tard, sans jamais faire le lien.

> **MariaDB repart d'un volume vierge et rejoue le dump**, plutôt que de
> restaurer `db_data` tel quel. C'est plus lent, mais c'est la seule méthode qui
> fonctionne quelle que soit la version de MariaDB qui a produit la sauvegarde.
> Un volume de données n'est pas portable entre versions majeures.

Le mode non interactif, pour les exercices automatisés :

```bash
./scripts/restore.sh backups/2026-09-07_03-00-00 --oui-je-suis-sur
```

### 3.4 — Reconstruction sur une machine neuve

Le scénario le plus grave couvert par ce plan : la machine est perdue, on repart
d'un serveur nu.

```bash
# 1. Sur la nouvelle machine : Docker, puis le dépôt.
git clone <url-du-dépôt> && cd cci-workshop-poudlard

# 2. Récupérer une sauvegarde depuis son stockage externe.
scp -r sauvegardes:/backups/2026-09-07_03-00-00 ./backups/

# 3. Restaurer la configuration : .env, certificats, empreinte du compte.
#    Ces fichiers ne sont PAS dans git — c'est ici qu'ils reviennent.
tar xzf backups/2026-09-07_03-00-00/configuration.tar.gz

# 4. Télécharger les images et restaurer les données.
docker compose pull
./scripts/restore.sh backups/2026-09-07_03-00-00 --oui-je-suis-sur

# 5. Contrôler.
make verify
```

**RTO : environ 90 minutes**, dont une bonne moitié en téléchargement d'images.
Sur un site où le temps compte, on garde les images dans un registre local ou on
les exporte avec `docker save`.

> **L'étape 3 est celle qu'on oublie.** Sans `configuration.tar.gz`, on a les
> données mais plus les mots de passe qui vont avec : la base restaurée attend
> l'ancien mot de passe GLPI, qui n'existe plus nulle part. C'est la raison pour
> laquelle `backup.sh` archive `.env`, `certs/` et `secrets/`.

---

## 4. Automatiser les sauvegardes

Le script est conçu pour être appelé par le planificateur de la machine.

```bash
# crontab -e — tous les jours à 3 h du matin
0 3 * * * cd /opt/dockerwarts && ./scripts/backup.sh >> /var/log/dockerwarts-backup.log 2>&1
```

**Le script sort en code non nul si quoi que ce soit échoue** : `cron` envoie
alors un courriel, et l'échec ne passe pas inaperçu. Une sauvegarde silencieuse
qui a cessé de fonctionner depuis six mois est un cas classique.

La rotation est automatique : `RETENTION` sauvegardes conservées (7 par défaut),
les plus anciennes effacées.

> **La règle 3-2-1.** Trois copies, sur deux supports, dont une hors site.
> `backups/` sur la même machine ne remplit qu'un tiers de la règle : il protège
> d'une erreur humaine ou d'une corruption logicielle, **pas** de la perte de la
> machine. Passez une destination au script pour l'améliorer :
>
> ```bash
> ./scripts/backup.sh /mnt/nas/dockerwarts        # deuxième support
> rsync -a backups/ sauvegardes-distantes:/dockerwarts/   # hors site
> ```

---

## 5. Tester le plan

**Une sauvegarde jamais restaurée n'est pas une sauvegarde : c'est un fichier.**
La seule preuve qu'un PRA fonctionne est de l'avoir exécuté.

### Test mensuel — 20 minutes

```bash
# 1. Vérifier l'intégrité de la dernière sauvegarde.
cd backups/$(ls -t backups | head -1) && sha256sum -c SHA256SUMS && cd -

# 2. Vérifier que le dump SQL contient bien les tables de GLPI.
gunzip -c backups/$(ls -t backups | head -1)/mariadb.sql.gz \
  | grep -c 'CREATE TABLE'          # doit dépasser 400 sur un GLPI installé

# 3. Vérifier le compte rendu du snapshot Elasticsearch.
grep -o '"state":"[A-Z]*"' backups/$(ls -t backups | head -1)/elasticsearch-snapshot.json
```

### Test trimestriel — 90 minutes, exercice complet

Sur une machine de test, jamais en production :

```bash
# 1. Créer un repère vérifiable dans les données.
#    Ouvrir un ticket dans GLPI intitulé « repère PRA <date> ».

# 2. Sauvegarder.
make backup

# 3. Simuler le désastre.
make clean            # supprime tout, y compris les volumes

# 4. Restaurer.
make init             # NE PAS relancer : restaurer la configuration à la place
tar xzf backups/<horodatage>/configuration.tar.gz
./scripts/restore.sh backups/<horodatage> --oui-je-suis-sur

# 5. Vérifier.
make verify
#    Puis ouvrir GLPI et retrouver le ticket « repère PRA <date> ».
```

**Chronométrez.** Le RTO annoncé au §2 est une promesse : elle se vérifie, et se
corrige si l'exercice montre autre chose.

### L'exercice réellement mené sur cette plateforme

Ce plan n'est pas théorique : il a été exécuté en entier, et il a échoué deux
fois avant de fonctionner. Les deux échecs sont corrigés dans `restore.sh`, et
valaient d'être compris.

**Déroulé.** Un témoin `TEMOIN-42` a été écrit dans les trois moteurs — une
ligne dans `dockerwarts.sante` (Cassandra), une table `repere_pra` dans la base
`glpi` (MariaDB), un document dans l'index `repere-pra` (Elasticsearch). Puis
`backup.sh`, puis `docker compose down -v` — **destruction des neuf volumes**,
zéro survivant — puis `restore.sh`.

**Résultat.** Les trois témoins sont revenus, et `verify.sh` est repassé au
vert intégralement.

```
Cassandra : TEMOIN-42
MariaDB   : TEMOIN-42
Elastic   : TEMOIN-42
Restauration complète : 1 min 59 s
```

**Le premier échec : l'ordre des opérations sur Cassandra.** Chaque table est
rangée dans un répertoire suffixé d'un identifiant tiré à sa création
(`sante-98e033c0aac6…`). La première version de `restore.sh` replaçait les
SSTables *avant* de recréer le schéma : les fichiers atterrissaient dans un
répertoire portant l'ancien identifiant, Cassandra créait les siens à côté, et
le nœud s'arrêtait sur un `NoSuchFileException`. Le schéma est désormais recréé
en premier, et les fichiers sont copiés dans les répertoires réellement créés,
retrouvés **par le nom de la table** et non par l'identifiant.

**Le second échec : les droits.** Les fichiers replacés par un conteneur
auxiliaire appartenaient à `root`, alors que Cassandra tourne en uid 999 et
Elasticsearch en uid 1000. Un `chown` explicite conclut désormais chaque
restauration de volume.

Aucun de ces deux défauts n'était visible à la lecture du script. C'est
précisément l'argument de ce paragraphe : **seule l'exécution le prouve.**

### La liste à cocher après restauration

- [ ] `make verify` sort en code 0
- [ ] Le ticket repère est présent dans GLPI
- [ ] Les documents joints aux tickets s'ouvrent (volume `glpi_files`)
- [ ] La connexion à l'annuaire fonctionne encore (clé de chiffrement de GLPI)
- [ ] Les index Elasticsearch sont là : `docker compose exec elasticsearch curl -s localhost:9200/_cat/indices?v`
- [ ] Le keyspace Cassandra répond : `docker compose exec cassandra cqlsh -e "SELECT * FROM dockerwarts.sante"`
- [ ] Le tableau de bord Grafana affiche des courbes
- [ ] Les interfaces d'administration refusent toujours l'accès anonyme

---

## 6. Ce que ce plan ne couvre pas

**Le site.** Une sauvegarde stockée dans `backups/` sur la machine disparaît avec
elle. La copie hors site (§4) n'est pas automatisée ici : elle dépend de
l'infrastructure de destination, qui n'existe pas dans le périmètre du projet.

**Le chiffrement des sauvegardes.** `configuration.tar.gz` contient des secrets
en clair, protégé seulement par ses droits `600`. Sur un stockage externe
partagé, il faut chiffrer :

```bash
gpg --symmetric --cipher-algo AES256 backups/<horodatage>/configuration.tar.gz
```

**La sauvegarde continue.** Le RPO est de 24 h par construction. Un RPO proche
de zéro demanderait la journalisation binaire de MariaDB et un archivage continu
— une autre échelle de complexité, et un autre périmètre.

**Les erreurs applicatives.** Un ticket supprimé par mégarde il y a trois jours
n'est récupérable que si une sauvegarde de plus de trois jours existe encore.
Avec `RETENTION=7`, la fenêtre est d'une semaine.
