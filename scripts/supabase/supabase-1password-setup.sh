#!/bin/bash
set -e

# Usage information
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    echo "Usage: $0 <hostname> [template_path]"
    echo ""
    echo "Creates a Supabase instance in 1Password and exports secrets to agenix"
    echo ""
    echo "Examples:"
    echo "  $0 trader" 
    echo "  $0 powerball"
    echo "  $0 networking"
    echo "  $0 production"
    echo ""
    echo "This will create:"
    echo "  - 1Password item: 'Supabase <Hostname> Instance'"
    echo "  - Agenix directory: 'secrets/<hostname>/supabase/'"
    exit 0
fi

# Configuration
VAULT_NAME="Private"
TEMPLATE_PATH="${2:-scripts/supabase/supabase-template.json}"
HOSTNAME="${1:-trader}"

# Derive item title and agenix directory from hostname
HOSTNAME_CAPITALIZED="$(tr '[:lower:]' '[:upper:]' <<< ${HOSTNAME:0:1})${HOSTNAME:1}"
ITEM_TITLE="Supabase $HOSTNAME_CAPITALIZED Instance"
AGENIX_DIR="secrets/$HOSTNAME/supabase"

echo "Creating 1Password item: $ITEM_TITLE"

# Create 1Password item from template
op item create --template "$TEMPLATE_PATH" --vault "$VAULT_NAME" --title "$ITEM_TITLE"

# Get the item ID (get the most recently created one if multiple exist)
ITEM_ID=$(op item list --format json | jq -r ".[] | select(.title==\"$ITEM_TITLE\") | {id, created_at} | \"\(.created_at) \(.id)\"" | sort -r | head -1 | awk '{print $2}')

if [ -z "$ITEM_ID" ]; then
    echo "Error: Could not find created item"
    exit 1
fi

echo "Item created with ID: $ITEM_ID"

# Wait a moment for the item to be fully created
sleep 2

# Generate passwords since 1Password CLI doesn't auto-generate from templates
echo "Generating secure passwords..."

# Generate passwords using openssl
ADMIN_PASSWORD=$(openssl rand -base64 16)
POSTGRES_PASSWORD=$(openssl rand -base64 20) 
JWT_SECRET=$(openssl rand -base64 48)
SECRET_KEY_BASE=$(openssl rand -base64 48)
VAULT_ENC_KEY=$(openssl rand -base64 32)  # 32 bytes required for AES-256-GCM encryption

# Update 1Password with generated passwords
echo "Updating 1Password with generated passwords..."
op item edit "$ITEM_ID" admin_password="$ADMIN_PASSWORD"
op item edit "$ITEM_ID" postgres_password="$POSTGRES_PASSWORD"
op item edit "$ITEM_ID" jwt_secret="$JWT_SECRET"
op item edit "$ITEM_ID" secret_key_base="$SECRET_KEY_BASE"
op item edit "$ITEM_ID" vault_enc_key="$VAULT_ENC_KEY"

echo "Generating JWT tokens..."

# Generate current timestamp and 5-year expiration
IAT=$(date +%s)
EXP=$((IAT + 157680000))  # 5 years in seconds

# Generate ANON_KEY
ANON_PAYLOAD=$(cat <<EOF
{
  "role": "anon",
  "iss": "supabase",
  "iat": $IAT,
  "exp": $EXP
}
EOF
)

# Generate SERVICE_ROLE_KEY  
SERVICE_PAYLOAD=$(cat <<EOF
{
  "role": "service_role", 
  "iss": "supabase",
  "iat": $IAT,
  "exp": $EXP
}
EOF
)

# Check if npm is available for npx
if ! command -v npm &> /dev/null; then
    echo "Error: npm not found. Please install Node.js and npm"
    exit 1
fi

# Generate JWT tokens using Node.js with npx jsonwebtoken package
echo "Installing jsonwebtoken temporarily and generating JWT tokens..."

# Create temporary directory and package.json
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
echo '{"dependencies": {"jsonwebtoken": "^9.0.2"}}' > package.json
npm install --silent

# Create JWT generation script
cat > generate_jwt.js << 'EOF'
const jwt = require('jsonwebtoken');
const [, , role, secret, iat, exp] = process.argv;
const payload = {
  role: role,
  iss: 'supabase',
  iat: parseInt(iat),
  exp: parseInt(exp)
};
console.log(jwt.sign(payload, secret));
EOF

# Generate tokens
ANON_KEY=$(node generate_jwt.js "anon" "$JWT_SECRET" "$IAT" "$EXP")
SERVICE_ROLE_KEY=$(node generate_jwt.js "service_role" "$JWT_SECRET" "$IAT" "$EXP")

# Return to original directory and cleanup
cd - > /dev/null
rm -rf "$TEMP_DIR"

# Update 1Password item with generated JWTs
echo "Updating 1Password with generated JWT tokens..."
op item edit "$ITEM_ID" anon_key="$ANON_KEY"
op item edit "$ITEM_ID" service_role_key="$SERVICE_ROLE_KEY"

# Export secrets to agenix
echo "Exporting secrets to agenix..."

# AGENIX_DIR specified as parameter
echo "Using agenix directory: $AGENIX_DIR"

# Check if agenix command is available
if ! command -v agenix &> /dev/null; then
    echo "Using nix shell for agenix..."
    AGENIX_CMD="nix --extra-experimental-features \"nix-command flakes\" shell github:ryantm/agenix -c agenix"
else
    AGENIX_CMD="agenix"
fi

# Export each secret to agenix using temporary files
echo "Exporting to $AGENIX_DIR/*.age files..."

# Create temporary directory for secret files
SECRET_TEMP_DIR=$(mktemp -d)
trap "rm -rf $SECRET_TEMP_DIR" EXIT

# Write secrets to temporary files
echo -n "$ADMIN_PASSWORD" > "$SECRET_TEMP_DIR/admin-password"
echo -n "$POSTGRES_PASSWORD" > "$SECRET_TEMP_DIR/postgres-password"
echo -n "$JWT_SECRET" > "$SECRET_TEMP_DIR/jwt-secret"
echo -n "$ANON_KEY" > "$SECRET_TEMP_DIR/anon-key"
echo -n "$SERVICE_ROLE_KEY" > "$SECRET_TEMP_DIR/service-role-key"
echo -n "$SECRET_KEY_BASE" > "$SECRET_TEMP_DIR/secret-key-base"
echo -n "$VAULT_ENC_KEY" > "$SECRET_TEMP_DIR/vault-enc-key"

# Encrypt using agenix (must run from project root where secrets.nix exists)
PROJECT_ROOT=$(pwd)
cd "$PROJECT_ROOT"


# Create a custom editor script that writes the secret content
cat > "$SECRET_TEMP_DIR/secret-editor.sh" << 'EOF'
#!/bin/bash
# Custom editor for agenix - writes secret content to the file
SECRET_FILE="$1"
if [ -n "$SECRET_CONTENT" ]; then
    printf "%s" "$SECRET_CONTENT" > "$SECRET_FILE"
fi
EOF
chmod +x "$SECRET_TEMP_DIR/secret-editor.sh"

echo "Encrypting admin-password..."
SECRET_CONTENT="$ADMIN_PASSWORD" EDITOR="$SECRET_TEMP_DIR/secret-editor.sh" nix --extra-experimental-features "nix-command flakes" shell github:ryantm/agenix -c agenix -e "$AGENIX_DIR/admin-password.age"

echo "Encrypting postgres-password..."
SECRET_CONTENT="$POSTGRES_PASSWORD" EDITOR="$SECRET_TEMP_DIR/secret-editor.sh" nix --extra-experimental-features "nix-command flakes" shell github:ryantm/agenix -c agenix -e "$AGENIX_DIR/postgres-password.age"

echo "Encrypting jwt-secret..."
SECRET_CONTENT="$JWT_SECRET" EDITOR="$SECRET_TEMP_DIR/secret-editor.sh" nix --extra-experimental-features "nix-command flakes" shell github:ryantm/agenix -c agenix -e "$AGENIX_DIR/jwt-secret.age"

echo "Encrypting anon-key..."
SECRET_CONTENT="$ANON_KEY" EDITOR="$SECRET_TEMP_DIR/secret-editor.sh" nix --extra-experimental-features "nix-command flakes" shell github:ryantm/agenix -c agenix -e "$AGENIX_DIR/anon-key.age"

echo "Encrypting service-role-key..."
SECRET_CONTENT="$SERVICE_ROLE_KEY" EDITOR="$SECRET_TEMP_DIR/secret-editor.sh" nix --extra-experimental-features "nix-command flakes" shell github:ryantm/agenix -c agenix -e "$AGENIX_DIR/service-role-key.age"

echo "Encrypting secret-key-base..."
SECRET_CONTENT="$SECRET_KEY_BASE" EDITOR="$SECRET_TEMP_DIR/secret-editor.sh" nix --extra-experimental-features "nix-command flakes" shell github:ryantm/agenix -c agenix -e "$AGENIX_DIR/secret-key-base.age"

echo "Encrypting vault-enc-key..."
SECRET_CONTENT="$VAULT_ENC_KEY" EDITOR="$SECRET_TEMP_DIR/secret-editor.sh" nix --extra-experimental-features "nix-command flakes" shell github:ryantm/agenix -c agenix -e "$AGENIX_DIR/vault-enc-key.age"


echo "✅ Supabase secrets created and exported!"
echo "1Password Item: $ITEM_TITLE (ID: $ITEM_ID)"
echo "Agenix Directory: $AGENIX_DIR/"
echo ""
echo "Generated and stored:"
echo "- ✅ Admin Password: 1Password + agenix"
echo "- ✅ PostgreSQL Password: 1Password + agenix"
echo "- ✅ JWT Secret: 1Password + agenix"
echo "- ✅ ANON Key: 1Password + agenix"
echo "- ✅ Service Role Key: 1Password + agenix"
echo "- ✅ Secret Key Base: 1Password + agenix"
echo "- ✅ Vault Encryption Key: 1Password + agenix"
echo ""
echo "Next steps:"
echo "1. Deploy with: colmena apply --on $HOSTNAME"
echo "2. Access Supabase dashboard with admin credentials from 1Password"