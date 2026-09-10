cmake_minimum_required(VERSION 3.10)
project(rogue-box VERSION 1.0 LANGUAGES CXX)

# C++17 standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Définir l'exécutable
add_executable(rogue-box src/main.cpp)

# Configuration spécifique Windows
if(WIN32)
    # Activer le support Unicode sur Windows
    target_compile_definitions(rogue-box PRIVATE _UNICODE UNICODE)
endif()

# Installation
install(TARGETS rogue-box DESTINATION bin)

# Message de configuration
message(STATUS "Configuring rogue-box v${PROJECT_VERSION}")
message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
