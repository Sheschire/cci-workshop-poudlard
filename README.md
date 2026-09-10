# La Boite Magique de Severus Rogue

Outil CLI cross-platform pour automatiser les operations git (add, commit, push).

## Compilation

### Prerequis

- CMake 3.10 ou superieur
- Compilateur C++ supportant C++17 (GCC, Clang, MSVC)
- Git installe et accessible dans le PATH

### Linux / macOS

```bash
cd 14
mkdir build && cd build
cmake ..
make
```

L'executable `rogue-box` sera genere dans le dossier `build/`.

### Windows (Visual Studio)

```cmd
cd 14
mkdir build && cd build
cmake ..
cmake --build . --config Release
```

### Windows (MinGW)

```cmd
cd 14
mkdir build && cd build
cmake -G "MinGW Makefiles" ..
mingw32-make
```

## Utilisation

### Mode interactif

```bash
./rogue-box
```

Affiche le statut des fichiers et propose de les envoyer avec un commit interactif.

### Commit avec message personnalise

```bash
./rogue-box -m "Mon message de commit"
```

Execute automatiquement: add -> commit -> push

### Avec pull automatique

```bash
./rogue-box -m "Message" --pull
```

Pull automatiquement si le remote a des commits plus recents.

### Afficher le statut uniquement

```bash
./rogue-box --status
```

### Sans push

```bash
./rogue-box -m "Message" --no-push
```

### Aide

```bash
./rogue-box --help
```

## Options

| Option | Description |
|--------|-------------|
| `-m, --message <msg>` | Message de commit personnalise |
| `-s, --status` | Affiche uniquement le statut git |
| `-p, --pull` | Pull avant de push (synchronise) |
| `--no-push` | Ne pas push apres le commit |
| `-h, --help` | Affiche l'aide |

## Fonctionnalites

- Affichage colore du statut git (fichiers modifies, ajoutes, supprimes, non suivis)
- Generation automatique de message de commit si non specifie
- Mode interactif avec confirmation avant chaque action
- Detection automatique de la branche courante
- Pull automatique en cas de conflit (option --pull)
- Compatible Linux, macOS et Windows

## Structure du projet

```
14/
├── CMakeLists.txt    # Configuration CMake
├── README.md         # Cette documentation
├── src/
│   └── main.cpp      # Code source principal
└── build/            # Dossier de compilation (genere)
```

---

*Defi 14 - CCI Workshop Poudlard*
