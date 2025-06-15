#!/bin/bash

# Gain your token by heading to your NordVPN account and going to "Get Access Token"
# URL: https://my.nordaccount.com/dashboard/nordvpn/access-tokens/authorize/
username="token"
password="e9f2ab26de7109c7348c26055084e8a9003bd9b8942465cbdef9bbd60a0b9102"

# Encode the authentication credentials
auth="$username:$password"
encodedCredentials=$(echo -n "$auth" | base64)

# Set the URL for the API request
url="https://api.nordvpn.com/v1/users/services/credentials"

# Use curl to send the GET request with the headers needed
response=$(curl -s -H "Authorization: Basic $encodedCredentials" "$url")

# Print out the response
echo "Response:"
# echo $response

# Optionally, you can parse the JSON response with jq to extract specific fields
# Install jq if it's not available
# brew install jq

# Example to get specific fields using jq
# echo $response | jq '.id, .created_at, .updated_at, .username, .password, .nordlynx_private_key'

# If you specifically need to output these properties, you can do so:
echo "ID: $(echo $response | jq -r '.id')"
echo "Username: $(echo $response | jq -r '.username')"
echo "Password: $(echo $response | jq -r '.password')"
echo "NordLynx Private Key: $(echo $response | jq -r '.nordlynx_private_key')"
