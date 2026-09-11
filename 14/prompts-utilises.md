# Prompts utilisés - Défi 14 : La Boîte Magique de Severus Rogue

## Description du défi
Outil CLI cross-platform en C++ pour automatiser les opérations git (add, commit, push).

---

## Prompt principal

> Voici le sujet du défi en PDF. L'objectif est de créer un outil en ligne de commande qui automatise les opérations Git courantes : add, commit et push.
>
> Résous l'exercice sans faire trop complexe. C'est un projet étudiant et ce n'est pas à destination d'une production d'entreprise.
>
> Contraintes :
> - Doit être cross-platform (Linux, macOS, Windows)
> - Utiliser C++ avec CMake pour la compilation
> - Mode interactif et mode avec arguments
> - Affichage coloré du statut git

---

## Prompt complémentaire

> Ajoute les fonctionnalités suivantes :
> - Option --pull pour synchroniser avant de push
> - Option --no-push pour ne pas push après le commit
> - Génération automatique du message de commit si non spécifié
> - Détection de la branche courante
>
> Garde le code simple et lisible.

---

## Approche générale

Le projet utilise :
- CMake pour la portabilité de la compilation
- C++17 pour les fonctionnalités modernes
- Appels système à git via popen/system
- Codes ANSI pour les couleurs (avec détection Windows)
