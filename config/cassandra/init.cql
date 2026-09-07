-- ============================================================================
-- Cassandra — schéma initial du datalake
--
-- Joué une seule fois par le service `cassandra-init` au premier démarrage.
-- Toutes les instructions sont IF NOT EXISTS : rejouer ce fichier ne casse
-- rien, ce qui compte le jour d'une restauration.
--
-- Documentation : docs/01-architecture.md
-- ============================================================================

-- SimpleStrategy et replication_factor 1 : un seul nœud, donc une seule copie.
-- Sur un vrai cluster, on passerait à NetworkTopologyStrategy avec un facteur
-- de 3 — c'est la seule ligne à changer, et elle est isolée ici exprès.
CREATE KEYSPACE IF NOT EXISTS dockerwarts
  WITH replication = {
    'class': 'SimpleStrategy',
    'replication_factor': 1
  };

USE dockerwarts;

-- ----------------------------------------------------------------------------
-- Événements bruts collectés par la plateforme.
--
-- Clé de partition (source, jour) : les lectures se font toujours « une source,
-- une journée ». Prendre l'identifiant de l'événement comme partition aurait
-- rendu impossible toute lecture par plage — l'erreur de conception classique
-- avec Cassandra, et elle ne se rattrape pas après coup.
--
-- Clé de tri décroissante sur l'horodatage : les événements récents en premier,
-- sans coût de tri à la lecture.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS evenements (
    source      text,
    jour        date,
    horodatage  timestamp,
    id          uuid,
    niveau      text,
    message     text,
    attributs   map<text, text>,
    PRIMARY KEY ((source, jour), horodatage, id)
) WITH CLUSTERING ORDER BY (horodatage DESC, id ASC)
  -- Écritures massives et immuables, jamais de mise à jour : la compaction par
  -- fenêtres temporelles est faite pour ce cas et évite de réécrire sans fin
  -- des données anciennes.
  AND compaction = {
    'class': 'TimeWindowCompactionStrategy',
    'compaction_window_unit': 'DAYS',
    'compaction_window_size': 1
  }
  -- 90 jours de conservation par défaut, appliqués par Cassandra lui-même.
  AND default_time_to_live = 7776000;

-- ----------------------------------------------------------------------------
-- Mesures numériques agrégées (une ligne par métrique et par heure).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS mesures (
    metrique    text,
    jour        date,
    horodatage  timestamp,
    valeur      double,
    unite       text,
    PRIMARY KEY ((metrique, jour), horodatage)
) WITH CLUSTERING ORDER BY (horodatage DESC)
  AND compaction = {
    'class': 'TimeWindowCompactionStrategy',
    'compaction_window_unit': 'DAYS',
    'compaction_window_size': 1
  };

-- ----------------------------------------------------------------------------
-- Témoin de bon fonctionnement : une ligne écrite ici prouve que le keyspace
-- existe, que le schéma est appliqué et que le nœud accepte les écritures.
-- C'est ce que vérifie `make verify` après une restauration.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sante (
    cle         text PRIMARY KEY,
    valeur      text,
    horodatage  timestamp
);

INSERT INTO sante (cle, valeur, horodatage)
  VALUES ('initialisation', 'ok', toTimestamp(now()));
