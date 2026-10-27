#!/usr/bin/env bash
# Script to add multiple encrypted secrets for a service
# Usage: ./scripts/add-service-secrets.sh <host> <service> <secret1=value1> [secret2=value2] ...
#
# Examples:
#   ./scripts/add-service-secrets.sh media-center kometa plex-token=abc123 tmdb-apikey=xyz789
#   ./scripts/add-service-secrets.sh networking atuin jwt-secret=random123

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running in nixos-base directory
if [[ ! -f "secrets.nix" ]]; then
    echo -e "${RED}Error: Must be run from nixos-base repository root${NC}"
    exit 1
fi

# Check if add-secret.sh exists
if [[ ! -f "scripts/add-secret.sh" ]]; then
    echo -e "${RED}Error: scripts/add-secret.sh not found${NC}"
    exit 1
fi

# Function to display usage
usage() {
    echo "Usage: $0 <host> <service> <secret1=value1> [secret2=value2] ..."
    echo ""
    echo "Arguments:"
    echo "  host          Host name (e.g., media-center, networking, trader)"
    echo "  service       Service name (e.g., kometa, atuin, supabase)"
    echo "  secret=value  One or more secret key-value pairs"
    echo ""
    echo "The script will create encrypted files at:"
    echo "  secrets/<host>/<service>/<secret-key>.age"
    echo ""
    echo "Examples:"
    echo "  $0 media-center kometa plex-token=abc123 tmdb-apikey=xyz789"
    echo "  $0 networking atuin jwt-secret=random123 db-key=secret456"
    echo ""
    exit 1
}

# Check arguments
if [[ $# -lt 3 ]]; then
    usage
fi

HOST="$1"
SERVICE="$2"
shift 2

# Create directory if it doesn't exist
SECRET_DIR="secrets/$HOST/$SERVICE"
if [[ ! -d "$SECRET_DIR" ]]; then
    echo -e "${BLUE}Creating directory: $SECRET_DIR${NC}"
    mkdir -p "$SECRET_DIR"
fi

# Track success/failure
SUCCESS_COUNT=0
FAIL_COUNT=0
TOTAL_SECRETS=$#

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Adding $TOTAL_SECRETS secret(s) for $SERVICE on $HOST${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Process each secret
for SECRET_PAIR in "$@"; do
    # Parse key=value
    if [[ ! "$SECRET_PAIR" =~ ^([^=]+)=(.+)$ ]]; then
        echo -e "${RED}✗ Invalid format: $SECRET_PAIR (expected key=value)${NC}"
        ((FAIL_COUNT++))
        continue
    fi

    SECRET_NAME="${BASH_REMATCH[1]}"
    SECRET_VALUE="${BASH_REMATCH[2]}"
    SECRET_PATH="$SECRET_DIR/$SECRET_NAME.age"

    echo -e "${YELLOW}Processing: $SECRET_NAME${NC}"

    # Call add-secret.sh for each secret
    if ./scripts/add-secret.sh "$SECRET_PATH" "$SECRET_VALUE"; then
        ((SUCCESS_COUNT++))
    else
        echo -e "${RED}✗ Failed to create: $SECRET_PATH${NC}"
        ((FAIL_COUNT++))
    fi
    echo ""
done

# Summary
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ Successfully created: $SUCCESS_COUNT/$TOTAL_SECRETS secrets${NC}"
if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "${RED}✗ Failed: $FAIL_COUNT/$TOTAL_SECRETS secrets${NC}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Show next steps
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Add secret definitions to secrets.nix:"
echo -e "   ${BLUE}(mkServiceSecrets \"$HOST\" $HOST \"$SERVICE\" [${NC}"
for SECRET_PAIR in "$@"; do
    if [[ "$SECRET_PAIR" =~ ^([^=]+)= ]]; then
        SECRET_NAME="${BASH_REMATCH[1]}"
        echo -e "     ${BLUE}\"$SECRET_NAME\"${NC}"
    fi
done
echo -e "   ${BLUE}])${NC}"
echo ""
echo "2. Add secret references to hosts/$HOST.nix"
echo ""
echo "3. Add secret handling to modules/$SERVICE.nix"
echo ""
echo "4. Deploy: nixos-rebuild switch --flake .#$HOST"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
