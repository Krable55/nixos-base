#!/usr/bin/env bash
# Script to add encrypted secrets to agenix
# Usage: ./scripts/add-secret.sh [secret-path] [secret-value]
#
# Examples:
#   ./scripts/add-secret.sh secrets/media-center/kometa/plex-token.age "your-secret-token"
#   ./scripts/add-secret.sh secrets/networking/service/api-key.age (will prompt for value)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running in nixos-base directory
if [[ ! -f "secrets.nix" ]]; then
    echo -e "${RED}Error: Must be run from nixos-base repository root${NC}"
    exit 1
fi

# Check if agenix is available
if ! command -v agenix &> /dev/null; then
    echo -e "${RED}Error: agenix command not found${NC}"
    echo "Please ensure you're in the nix environment with agenix available"
    echo "Try: nix-shell -p agenix"
    exit 1
fi

# Function to display usage
usage() {
    echo "Usage: $0 <secret-path> [secret-value]"
    echo ""
    echo "Arguments:"
    echo "  secret-path   Path to the .age file (e.g., secrets/host/service/secret-name.age)"
    echo "  secret-value  (Optional) The secret value. If not provided, will prompt securely"
    echo ""
    echo "Examples:"
    echo "  $0 secrets/media-center/kometa/plex-token.age"
    echo "  $0 secrets/networking/service/api-key.age 'my-secret-value'"
    echo ""
    exit 1
}

# Check arguments
if [[ $# -lt 1 ]]; then
    usage
fi

SECRET_PATH="$1"
SECRET_VALUE="${2:-}"

# Validate secret path
if [[ ! "$SECRET_PATH" =~ ^secrets/.+\.age$ ]]; then
    echo -e "${RED}Error: Secret path must start with 'secrets/' and end with '.age'${NC}"
    echo "Got: $SECRET_PATH"
    exit 1
fi

# Check if the secret already exists
if [[ -f "$SECRET_PATH" ]]; then
    echo -e "${YELLOW}Warning: Secret file already exists: $SECRET_PATH${NC}"
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Create directory if it doesn't exist
SECRET_DIR=$(dirname "$SECRET_PATH")
if [[ ! -d "$SECRET_DIR" ]]; then
    echo -e "${YELLOW}Creating directory: $SECRET_DIR${NC}"
    mkdir -p "$SECRET_DIR"
fi

# Get secret value if not provided
if [[ -z "$SECRET_VALUE" ]]; then
    echo "Enter secret value (input will be hidden):"
    read -rs SECRET_VALUE
    echo

    if [[ -z "$SECRET_VALUE" ]]; then
        echo -e "${RED}Error: Secret value cannot be empty${NC}"
        exit 1
    fi
fi

# Create the encrypted secret using agenix
echo -e "${GREEN}Creating encrypted secret...${NC}"

# Use a temporary wrapper script to pass the secret value to agenix
# Note: We use echo -n to avoid adding a trailing newline
TEMP_EDITOR=$(mktemp)
cat > "$TEMP_EDITOR" << 'WRAPPER_EOF'
#!/bin/sh
# printf, not `echo -n`: on this machine /bin/sh's echo doesn't treat -n as
# a flag, it prints "-n " literally and still appends a newline -- silently
# corrupting every secret written this way (prefix + trailing newline).
printf '%s' "$SECRET_VALUE" > "$1"
WRAPPER_EOF
chmod +x "$TEMP_EDITOR"

# Export the secret value for the wrapper script and run agenix
export SECRET_VALUE
EDITOR="$TEMP_EDITOR" agenix -e "$SECRET_PATH" 2>&1 | grep -v "warning:" || true

# Clean up
rm -f "$TEMP_EDITOR"
unset SECRET_VALUE

# Verify the file was created
if [[ -f "$SECRET_PATH" ]]; then
    echo -e "${GREEN}✓ Secret successfully created: $SECRET_PATH${NC}"
    ls -lh "$SECRET_PATH"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Ensure the secret is defined in secrets.nix"
    echo "2. Add the secret definition to the host configuration"
    echo "3. Deploy: nixos-rebuild switch --flake .#<host>"
else
    echo -e "${RED}✗ Failed to create secret file${NC}"
    exit 1
fi
