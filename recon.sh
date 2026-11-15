#!/bin/bash
# passive_recon.sh - subdomain recon pipeline for bug bounty
# usage: ./passive_recon.sh <domain.com>
# only run it against targets you are authorized to test

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# banner
clear
echo -e "${NC}"
cat << "EOF"
  ____        __  __            _   _______   _      _   
 |  _ \      |  \/  |          (_) |__   __| (_)    | |  
 | | | | __ _| \  / |__ _  __ _ _  ___ | |_ __ _  ___| | __
 | | | |/ _` | |\/| / _` |/ _` | |/ __| | | '__| |/ __| |/ /
 | |_| | (_| | |  | | (_| | (_|| | (__  | | |  | | (__|   < 
 |____/ \__,_|_|  |_|\__,_|\__,|_|\___| |_|_|  |_|\___|_|\_\
                           / |                              
                          |___/                             
EOF
echo -e "${NC}"
echo -e " ${NC} Reconnaissance passive de sous-domaines ${NC}"
echo -e "${YELLOW}========================================================================${NC}"
echo -e " Ce script a été réalisé par ${CYAN}DaMagicTrick - Mathis Roussé${NC}."
echo -e " ${RED}⚠️  ATTENTION : À n'utiliser que sur une cible qui donne son accord.${NC}"
echo -e "${YELLOW}========================================================================${NC}\n"

# --- argument check ---

if [ -z "$1" ]; then
    echo "Pour utiliser : ./passive_recon.sh <domaine.com>"
    exit 1
fi

# the domain ends up inside bash -c strings below, so only accept a plain hostname
if [[ ! "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]]; then
    echo "Domaine invalide : $1"
    exit 1
fi

# --- setup ---

DOMAIN=$1
DATE=$(date +%F)
DOMAIN_NAME="${DOMAIN%.*}"
# override with BASE_DIR=/some/path ./passive_recon.sh ...
BASE_DIR="${BASE_DIR:-$HOME/bug_bounty/programmes}"
OUT_DIR="${BASE_DIR}/${DOMAIN_NAME}/${DATE}"

# one folder per target and per day, so runs don't overwrite each other
mkdir -p "$OUT_DIR"
cd "$OUT_DIR" || { echo "Erreur : Impossible d'accéder à $OUT_DIR"; exit 1; }

echo "[+] Démarrage de la reconnaissance pour : $DOMAIN"
echo "[+] Dossier de sortie : $OUT_DIR"
echo "---------------------------------------------------"

# stderr of every tool goes here, truncated at each run
ERROR_LOG="erreurs_outils.log"
> "$ERROR_LOG"

# --- tool wrapper ---

# max runtime per tool
GLOBAL_TIMEOUT="10m"

# run_tool <name> <command> [output file]
# runs the command under timeout, logs stderr, prints a short summary
run_tool() {
    local tool_name=$1
    local command_to_run=$2
    local output_file=$3

    echo -e "  [${CYAN}*${NC}] Lancement de ${YELLOW}$tool_name${NC} (Timeout max: $GLOBAL_TIMEOUT)..."

    # bash -c so pipes and redirections inside the command string still work
    timeout "$GLOBAL_TIMEOUT" bash -c "$command_to_run" 2>> "$ERROR_LOG"
    local exit_status=$?

    if [ $exit_status -eq 0 ]; then
        echo -e "  [${GREEN}✔${NC}] $tool_name a terminé avec succès."

        # only report on the output file if there is one and it isn't empty
        if [ -n "$output_file" ] && [ -s "$output_file" ]; then
            local count=$(wc -l < "$output_file" | awk '{print $1}')
            echo "      -> $count résultats trouvés."
            echo "      -> Aperçu :"
            head -n 10 "$output_file" | sed 's/^/         - /'
        elif [ -n "$output_file" ]; then
            echo "      -> 0 résultat trouvé (le fichier est vide)."
        fi

    # timeout exits with 124 when it kills the command
    elif [ $exit_status -eq 124 ]; then
        echo -e "  [${RED}TIMEOUT${NC}] $tool_name a été interrompu (A dépassé les $GLOBAL_TIMEOUT)."
        echo "      -> On skip et on passe à l'outil suivant..."

    else
        echo -e "  [${RED}!${NC}] AVERTISSEMENT : $tool_name a rencontré un problème (Code: $exit_status)."
        echo "      -> Vérifie $ERROR_LOG pour plus de détails. On continue..."
    fi

    # small pause between tools, to go easy on the APIs
    sleep 2
}

# --- phase 1: passive enumeration ---

run_tool "Subfinder" "subfinder -d $DOMAIN -all -silent > subfinder.txt" "subfinder.txt"

run_tool "Assetfinder" "assetfinder --subs-only $DOMAIN > assetfinder.txt" "assetfinder.txt"

# needs CHAOS_KEY in the environment
run_tool "Chaos" "chaos -d $DOMAIN -silent -o chaos.txt" "chaos.txt"

run_tool "Findomain" "findomain -t $DOMAIN -q -u findomain.txt" "findomain.txt"

# token comes from the environment, never hardcode it here
if [ -n "$GITHUB_TOKEN" ]; then
    run_tool "Github-Subdomains" "github-subdomains -d $DOMAIN -t $GITHUB_TOKEN -raw -o /dev/null > github.txt" "github.txt"
else
    echo -e "  [${YELLOW}-${NC}] GITHUB_TOKEN non défini, Github-Subdomains ignoré."
fi

# merge and dedupe
echo "---------------------------------------------------"
echo "[+] Fusion des résultats passifs dans all_sub.txt..."

cat subfinder.txt assetfinder.txt chaos.txt findomain.txt github.txt 2>/dev/null | sort -u > all_sub.txt
COUNT_PASSIVE=$(wc -l < all_sub.txt | awk '{print $1}')
echo "    -> $COUNT_PASSIVE sous-domaines uniques trouvés passivement."

# --- phase 2: DNS filtering ---
echo "---------------------------------------------------"
echo "[+] Filtrage DNS : Suppression des faux positifs (Wildcards) avec dnsx..."

# -wd drops hosts that only resolve because of a wildcard record
run_tool "Dnsx" "dnsx -l all_sub.txt -wd $DOMAIN -silent | sort -u > clean_sub.txt" "clean_sub.txt"

# --- phase 3: HTTP probing ---
echo "---------------------------------------------------"
echo "[+] Lancement de httpx pour vérifier les services web..."

# input is the filtered list, not all_sub.txt
run_tool "Httpx" "httpx -l clean_sub.txt -ports 443,80,8080,8000,8888 -threads 50 -silent | sort -u > alive_sub.txt" "alive_sub.txt"

echo "---------------------------------------------------"
if [ -s alive_sub.txt ]; then
    COUNT_ALIVE=$(wc -l < alive_sub.txt | awk '{print $1}')
    echo -e "[${GREEN}✔${NC}] BINGO ! Reconnaissance terminée avec succès."
    echo -e "[${GREEN}✔${NC}] $COUNT_ALIVE URL actives trouvées."
    echo -e "[${GREEN}✔${NC}] Fichier final disponible ici : $OUT_DIR/alive_sub.txt"
else
    echo -e "[${RED}!${NC}] La reconnaissance est terminée, mais httpx n'a trouvé aucune URL active."
fi

# --- cleanup and screenshots ---

# leftover resume file from the ProjectDiscovery tools
rm -f resume.cfg

# screenshots + results stored in a local sqlite db
run_tool "Gowitness" "gowitness scan file -f $OUT_DIR/alive_sub.txt --threads 20 --write-db --write-db-uri sqlite://gowitness.sqlite3" ""

gowitness report generate

# drop the error log if nothing was written to it
if [ ! -s "$ERROR_LOG" ]; then
    rm "$ERROR_LOG"
fi
