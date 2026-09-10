/**
 * rogue-box - La Boite Magique de Severus Rogue
 * Outil CLI pour automatiser les operations git (add, commit, push)
 *
 * Defi 14 - CCI Workshop Poudlard
 */

#include <iostream>
#include <string>
#include <vector>
#include <cstdlib>
#include <cstdio>
#include <array>
#include <sstream>

#ifdef _WIN32
    #define popen _popen
    #define pclose _pclose
#endif

// Codes ANSI pour les couleurs (desactives sur Windows CMD par defaut)
namespace Color {
    #ifdef _WIN32
        const std::string RESET   = "";
        const std::string RED     = "";
        const std::string GREEN   = "";
        const std::string YELLOW  = "";
        const std::string BLUE    = "";
        const std::string MAGENTA = "";
        const std::string CYAN    = "";
        const std::string BOLD    = "";
    #else
        const std::string RESET   = "\033[0m";
        const std::string RED     = "\033[31m";
        const std::string GREEN   = "\033[32m";
        const std::string YELLOW  = "\033[33m";
        const std::string BLUE    = "\033[34m";
        const std::string MAGENTA = "\033[35m";
        const std::string CYAN    = "\033[36m";
        const std::string BOLD    = "\033[1m";
    #endif
}

/**
 * Execute une commande shell et retourne la sortie
 */
std::string execCommand(const std::string& cmd, int& exitCode) {
    std::array<char, 128> buffer;
    std::string result;

    std::string fullCmd = cmd + " 2>&1";
    FILE* pipe = popen(fullCmd.c_str(), "r");

    if (!pipe) {
        exitCode = -1;
        return "Erreur: Impossible d'executer la commande";
    }

    while (fgets(buffer.data(), buffer.size(), pipe) != nullptr) {
        result += buffer.data();
    }

    exitCode = pclose(pipe);
    #ifndef _WIN32
        exitCode = WEXITSTATUS(exitCode);
    #endif

    return result;
}

/**
 * Verifie si on est dans un repository git
 */
bool isGitRepo() {
    int exitCode;
    execCommand("git rev-parse --is-inside-work-tree", exitCode);
    return exitCode == 0;
}

/**
 * Obtient le nom de la branche courante
 */
std::string getCurrentBranch() {
    int exitCode;
    std::string branch = execCommand("git branch --show-current", exitCode);
    // Supprimer le retour a la ligne
    if (!branch.empty() && branch.back() == '\n') {
        branch.pop_back();
    }
    return exitCode == 0 ? branch : "main";
}

/**
 * Affiche le statut git avec couleurs
 */
void showStatus() {
    int exitCode;

    std::cout << Color::BOLD << Color::MAGENTA;
    std::cout << "\n  La Boite Magique de Severus Rogue\n";
    std::cout << "  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n" << Color::RESET;

    std::string branch = getCurrentBranch();
    std::cout << Color::CYAN << "\n  Branche: " << Color::BOLD << branch << Color::RESET << "\n\n";

    std::string status = execCommand("git status --short", exitCode);

    if (exitCode != 0) {
        std::cout << Color::RED << "  Erreur lors de la recuperation du statut\n" << Color::RESET;
        return;
    }

    if (status.empty()) {
        std::cout << Color::GREEN << "  Rien a commiter, le repertoire de travail est propre.\n" << Color::RESET;
        return;
    }

    std::cout << Color::YELLOW << "  Fichiers modifies:\n" << Color::RESET;

    std::istringstream iss(status);
    std::string line;
    while (std::getline(iss, line)) {
        if (line.empty()) continue;

        char statusChar = line[0];
        std::string filename = line.substr(3);

        switch (statusChar) {
            case 'M':
                std::cout << Color::YELLOW << "    [M] " << filename << " (modifie)" << Color::RESET << "\n";
                break;
            case 'A':
                std::cout << Color::GREEN << "    [A] " << filename << " (ajoute)" << Color::RESET << "\n";
                break;
            case 'D':
                std::cout << Color::RED << "    [D] " << filename << " (supprime)" << Color::RESET << "\n";
                break;
            case '?':
                std::cout << Color::BLUE << "    [?] " << filename << " (non suivi)" << Color::RESET << "\n";
                break;
            default:
                std::cout << "    [" << statusChar << "] " << filename << "\n";
        }
    }
    std::cout << "\n";
}

/**
 * Execute git add -A (ajoute tous les fichiers du repo)
 */
bool gitAdd() {
    int exitCode;
    std::cout << Color::CYAN << "  Ajout des fichiers (git add -A)..." << Color::RESET << "\n";
    execCommand("git add -A", exitCode);

    if (exitCode == 0) {
        std::cout << Color::GREEN << "  Fichiers ajoutes avec succes!" << Color::RESET << "\n";
        return true;
    } else {
        std::cout << Color::RED << "  Erreur lors de l'ajout des fichiers" << Color::RESET << "\n";
        return false;
    }
}

/**
 * Execute git pull --rebase
 */
bool gitPull() {
    int exitCode;
    std::string branch = getCurrentBranch();

    std::cout << Color::CYAN << "  Pull depuis origin/" << branch << " (rebase)..." << Color::RESET << "\n";

    std::string cmd = "git pull origin " + branch + " --rebase";
    std::string output = execCommand(cmd, exitCode);

    if (exitCode == 0) {
        std::cout << Color::GREEN << "  Pull reussi!" << Color::RESET << "\n";
        return true;
    } else {
        std::cout << Color::RED << "  Erreur lors du pull" << Color::RESET << "\n";
        std::cout << output << "\n";
        return false;
    }
}

/**
 * Execute git commit
 */
bool gitCommit(const std::string& message) {
    int exitCode;
    std::cout << Color::CYAN << "  Commit en cours..." << Color::RESET << "\n";

    std::string cmd = "git commit -m \"" + message + "\"";
    std::string output = execCommand(cmd, exitCode);

    if (exitCode == 0) {
        std::cout << Color::GREEN << "  Commit reussi: " << message << Color::RESET << "\n";
        return true;
    } else {
        if (output.find("nothing to commit") != std::string::npos) {
            std::cout << Color::YELLOW << "  Rien a commiter" << Color::RESET << "\n";
        } else {
            std::cout << Color::RED << "  Erreur lors du commit" << Color::RESET << "\n";
            std::cout << output << "\n";
        }
        return false;
    }
}

/**
 * Execute git push
 */
bool gitPush(bool autoPull = false) {
    int exitCode;
    std::string branch = getCurrentBranch();

    std::cout << Color::CYAN << "  Push vers origin/" << branch << "..." << Color::RESET << "\n";

    std::string cmd = "git push origin " + branch;
    std::string output = execCommand(cmd, exitCode);

    if (exitCode == 0) {
        std::cout << Color::GREEN << "  Push reussi!" << Color::RESET << "\n";
        return true;
    } else {
        // Verifier si c'est un probleme de fast-forward (besoin de pull)
        if (output.find("fetch first") != std::string::npos ||
            output.find("non-fast-forward") != std::string::npos) {
            std::cout << Color::YELLOW << "  Le remote a des commits plus recents.\n" << Color::RESET;

            if (autoPull) {
                std::cout << Color::CYAN << "  Pull automatique...\n" << Color::RESET;
                if (gitPull()) {
                    return gitPush(false); // Reessayer le push sans auto-pull
                }
            } else {
                std::cout << Color::YELLOW << "  Utilisez --pull pour synchroniser automatiquement.\n" << Color::RESET;
            }
        } else {
            std::cout << Color::RED << "  Erreur lors du push" << Color::RESET << "\n";
            std::cout << output << "\n";
        }
        return false;
    }
}

/**
 * Genere un message de commit automatique
 */
std::string generateAutoMessage() {
    int exitCode;
    std::string status = execCommand("git status --short", exitCode);

    int added = 0, modified = 0, deleted = 0;

    std::istringstream iss(status);
    std::string line;
    while (std::getline(iss, line)) {
        if (line.empty()) continue;
        char c = line[0];
        if (c == '?' || c == 'A') added++;
        else if (c == 'M') modified++;
        else if (c == 'D') deleted++;
    }

    std::stringstream msg;
    msg << "Update: ";

    std::vector<std::string> parts;
    if (added > 0) parts.push_back(std::to_string(added) + " fichier(s) ajoute(s)");
    if (modified > 0) parts.push_back(std::to_string(modified) + " fichier(s) modifie(s)");
    if (deleted > 0) parts.push_back(std::to_string(deleted) + " fichier(s) supprime(s)");

    for (size_t i = 0; i < parts.size(); i++) {
        if (i > 0) msg << ", ";
        msg << parts[i];
    }

    if (parts.empty()) {
        msg << "mise a jour";
    }

    return msg.str();
}

/**
 * Affiche l'aide
 */
void showHelp() {
    std::cout << Color::BOLD << Color::MAGENTA;
    std::cout << "\n  La Boite Magique de Severus Rogue\n";
    std::cout << "  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~\n" << Color::RESET;
    std::cout << "\n  Outil CLI pour automatiser les operations git\n\n";

    std::cout << Color::YELLOW << "  Usage:" << Color::RESET << "\n";
    std::cout << "    rogue-box                  Mode interactif\n";
    std::cout << "    rogue-box -m \"message\"     Commit avec message personnalise\n";
    std::cout << "    rogue-box --status         Affiche le statut git\n";
    std::cout << "    rogue-box --help           Affiche cette aide\n\n";

    std::cout << Color::YELLOW << "  Options:" << Color::RESET << "\n";
    std::cout << "    -m, --message <msg>  Message de commit personnalise\n";
    std::cout << "    -s, --status         Affiche uniquement le statut\n";
    std::cout << "    -h, --help           Affiche l'aide\n";
    std::cout << "    -p, --pull           Pull avant de push (synchronise)\n";
    std::cout << "    --no-push            Ne pas push apres le commit\n\n";

    std::cout << Color::CYAN << "  Defi 14 - CCI Workshop Poudlard\n\n" << Color::RESET;
}

/**
 * Mode interactif
 */
void interactiveMode() {
    showStatus();

    // Verifier s'il y a des changements
    int exitCode;
    std::string status = execCommand("git status --short", exitCode);

    if (status.empty()) {
        return;
    }

    std::cout << Color::YELLOW << "  Voulez-vous envoyer ces modifications? (o/n): " << Color::RESET;
    std::string response;
    std::getline(std::cin, response);

    if (response != "o" && response != "O" && response != "oui" && response != "y" && response != "Y") {
        std::cout << Color::CYAN << "\n  Operation annulee.\n\n" << Color::RESET;
        return;
    }

    std::cout << Color::YELLOW << "  Message de commit (laisser vide pour auto): " << Color::RESET;
    std::string message;
    std::getline(std::cin, message);

    if (message.empty()) {
        message = generateAutoMessage();
        std::cout << Color::CYAN << "  Message auto: " << message << Color::RESET << "\n";
    }

    std::cout << "\n";

    if (gitAdd() && gitCommit(message)) {
        std::cout << Color::YELLOW << "\n  Voulez-vous push? (o/n): " << Color::RESET;
        std::getline(std::cin, response);

        if (response == "o" || response == "O" || response == "oui" || response == "y" || response == "Y") {
            gitPush();
        }
    }

    std::cout << "\n";
}

/**
 * Point d'entree principal
 */
int main(int argc, char* argv[]) {
    // Verifier qu'on est dans un repo git
    if (!isGitRepo()) {
        std::cout << Color::RED << "\n  Erreur: Ce repertoire n'est pas un repository git.\n";
        std::cout << "  Executez 'git init' ou naviguez vers un repo existant.\n\n" << Color::RESET;
        return 1;
    }

    // Parser les arguments
    std::string commitMessage;
    bool statusOnly = false;
    bool noPush = false;
    bool autoPull = false;

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];

        if (arg == "-h" || arg == "--help") {
            showHelp();
            return 0;
        }
        else if (arg == "-s" || arg == "--status") {
            statusOnly = true;
        }
        else if (arg == "--no-push") {
            noPush = true;
        }
        else if (arg == "-p" || arg == "--pull") {
            autoPull = true;
        }
        else if (arg == "-m" || arg == "--message") {
            if (i + 1 < argc) {
                commitMessage = argv[++i];
            } else {
                std::cout << Color::RED << "  Erreur: -m necessite un message\n" << Color::RESET;
                return 1;
            }
        }
        else {
            std::cout << Color::RED << "  Option inconnue: " << arg << "\n" << Color::RESET;
            showHelp();
            return 1;
        }
    }

    // Mode status uniquement
    if (statusOnly) {
        showStatus();
        return 0;
    }

    // Mode avec message specifie (non-interactif)
    if (!commitMessage.empty()) {
        showStatus();

        int exitCode;
        std::string status = execCommand("git status --short", exitCode);

        if (status.empty()) {
            return 0;
        }

        std::cout << Color::CYAN << "  Execution automatique...\n\n" << Color::RESET;

        if (gitAdd() && gitCommit(commitMessage)) {
            if (!noPush) {
                gitPush(autoPull);
            }
        }

        std::cout << "\n";
        return 0;
    }

    // Mode interactif par defaut
    interactiveMode();

    return 0;
}
