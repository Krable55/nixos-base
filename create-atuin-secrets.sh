#!/bin/bash
# Commands to create Atuin secrets - Run these in your nix-shell

# 1. Create JWT secret
cat > /tmp/create-jwt-secret.sh << 'EOF'
#!/bin/sh
echo "nOXV6MFjQHLHYyMN4B7qpMisJInKwI/XNMlkKRjmBT8=" > "$1"
EOF
chmod +x /tmp/create-jwt-secret.sh
EDITOR=/tmp/create-jwt-secret.sh agenix -e secrets/networking/atuin/jwt-secret.age

# 2. Create database encryption key
cat > /tmp/create-db-key.sh << 'EOF'
#!/bin/sh
echo "OqpbtGG9tXCwLftjo91UJwjrz/vEhCjgwSlpjRj6RTE=" > "$1"
EOF
chmod +x /tmp/create-db-key.sh
EDITOR=/tmp/create-db-key.sh agenix -e secrets/networking/atuin/database-key.age

# 3. Verify files were created
ls -la secrets/networking/atuin/

# 4. Deploy to networking host
colmena apply --on networking
