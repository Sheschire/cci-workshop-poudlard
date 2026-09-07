# ADR-0010 — Métriques MinIO exposées en `public` sur le réseau interne plutôt que par jeton

**Statut** : Accepté — 2026-09-07
**Complète** : ADR-0008 (MinIO + restic + snapshots natifs)

## Contexte

Le CDC §7.7 prévoit que les métriques MinIO soient récupérées « via token Prometheus », et `scripts/init-secrets.sh` générait à cet effet un secret `dw_minio_prometheus_token` (64 octets aléatoires).

À la réalisation, ce mécanisme s'avère techniquement inapplicable tel que décrit :

- MinIO n'accepte pas un jeton porteur arbitraire. Avec la valeur par défaut `MINIO_PROMETHEUS_AUTH_TYPE=jwt`, l'endpoint `/minio/v2/metrics/*` exige un **JWT signé en HS512 avec la clé secrète du compte root**, tel que produit par `mc admin prometheus generate`. Un secret aléatoire est rejeté avec un `403`.
- Ce JWT n'est donc pas un secret indépendant : c'est un dérivé des identifiants root. Le placer dans le coffre revient à y stocker une seconde fois le mot de passe root, sous une forme qui ne peut pas être révoquée séparément.
- Il porte une date d'expiration. Un jeton expiré ne casse pas MinIO : il casse **la supervision de MinIO**, silencieusement, jusqu'à ce que `MinIOCapacityLow` ne puisse plus être évalué faute de série. C'est exactement le mode de panne que le monitoring est censé détecter chez les autres.
- Le régénérer périodiquement supposerait qu'un job réécrive un secret Docker — or les secrets Swarm sont immuables : il faudrait en créer un nouveau, redéployer Prometheus, supprimer l'ancien, à chaque rotation. Une chaîne de trois opérations dont l'échec est invisible, pour protéger des métriques de capacité disque.

La seule autre valeur acceptée par MinIO est `MINIO_PROMETHEUS_AUTH_TYPE=public`.

## Décision

- `MINIO_PROMETHEUS_AUTH_TYPE=public` sur le service `minio`.
- L'endpoint `/minio/v2/metrics/cluster` n'est **jamais** publié par Traefik : seule la console MinIO l'est (`minio.${DOMAIN}`, derrière `admin-chain@file`). L'API S3 et les métriques ne sont joignables que depuis le réseau overlay `data`, qui est `internal: true` (aucune route vers l'extérieur) **et chiffré par IPsec** (§5.4, ADR-0007).
- La découverte reste la découverte Swarm générique : labels `prometheus.job=minio`, `prometheus.port=9000`, `prometheus.path=/minio/v2/metrics/cluster`. Aucun job Prometheus dédié, aucun fichier de jeton monté.
- Le secret `dw_minio_prometheus_token` est retiré de `scripts/init-secrets.sh` : un secret généré et jamais consommé est un faux sentiment de sécurité et un élément de plus à faire tourner.

## Alternatives étudiées

- **Générer le JWT dans `minio-init.sh` et le monter dans Prometheus** : impossible sans recréer un objet secret Docker à chaque rotation, et fait dépendre la supervision d'une expiration silencieuse.
- **Signer nous-mêmes le JWT dans `init-secrets.sh`** (la clé root y est disponible) : reproduit un format interne à MinIO, non contractuel, qui casserait à la première évolution du produit — et laisse le problème d'expiration entier.
- **Exposer les métriques derrière Traefik avec `admin-chain@file`** : ajoute une traversée du proxy et une authentification HTTP pour un trafic strictement interne, et ferait dépendre la supervision de MinIO de la disponibilité de Traefik.
- **Renoncer aux métriques MinIO** : inacceptable, `MinIOCapacityLow` est l'alerte qui prévient que le dépôt de sauvegarde se remplit — c'est-à-dire que les sauvegardes vont cesser.

## Conséquences

- Tout conteneur attaché au réseau `data` peut lire les métriques MinIO. Ces métriques ne contiennent ni objet, ni nom de bucket, ni identifiant : uniquement des compteurs d'occupation, d'E/S et d'erreurs. Le risque résiduel est une fuite d'information de capacité vers un service déjà à l'intérieur du périmètre chiffré.
- Un secret de moins à conserver et à faire tourner ; la supervision de MinIO ne peut plus tomber en panne par expiration.
- Si MinIO devait un jour être remplacé par **Garage** (alternative validée en ADR-0008), la question ne se pose plus : Garage expose ses métriques sans authentification par défaut, avec le même raisonnement de confinement réseau.
