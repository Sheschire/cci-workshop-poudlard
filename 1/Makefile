# =============================================================================
# Dockerwarts N°1 — raccourcis
#
#   make          affiche cette aide
#   make init     prépare .env, le certificat et le compte d'administration
#   make up       démarre la plateforme
#   make verify   vérifie que tout répond réellement
#
# Rien d'indispensable ici : chaque cible tient en une commande docker compose,
# rappelée dans docs/02-installation.md.
# =============================================================================

.DEFAULT_GOAL := help
.PHONY: help init up down restart logs ps verify backup restore firewall config clean

help: ## Affiche cette aide
	@printf '\nDockerwarts N°1 — cibles disponibles\n\n'
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

init: ## Prépare .env, le certificat TLS et le compte d'administration
	@./scripts/init.sh

up: ## Démarre la plateforme
	docker compose up -d
	@printf '\n  Démarrage en cours. Suivi : make logs — vérification : make verify\n'
	@printf '  GLPI met environ deux minutes à s'\''installer au premier lancement.\n\n'

down: ## Arrête la plateforme (les données sont conservées)
	docker compose down

restart: ## Redémarre tous les services
	docker compose restart

logs: ## Suit les journaux (make logs S=glpi pour un seul service)
	docker compose logs -f --tail=100 $(S)

ps: ## Etat des conteneurs
	docker compose ps

verify: ## Vérifie que chaque service répond réellement
	@./scripts/verify.sh

backup: ## Sauvegarde complète dans backups/<horodatage>/
	@./scripts/backup.sh

restore: ## Restaure une sauvegarde (make restore FROM=backups/2026-...)
	@test -n "$(FROM)" || { echo "Usage : make restore FROM=backups/<horodatage>"; exit 1; }
	@./scripts/restore.sh "$(FROM)"

firewall: ## Affiche les règles de pare-feu hôte (n'applique rien)
	@./scripts/firewall.sh

config: ## Valide et affiche la configuration Compose résolue
	docker compose config

clean: ## SUPPRIME tout, y compris les données. Irréversible.
	@printf '\033[31m  Ceci supprime les volumes et donc toutes les données.\033[0m\n'
	@read -r -p '  Taper « supprimer » pour confirmer : ' r; \
	  [ "$$r" = "supprimer" ] || { echo "  Annulé."; exit 1; }
	docker compose down -v
