#!/usr/bin/env node
const jwt = require('jsonwebtoken');
const { execSync } = require('child_process');

/**
 * Generate Supabase JWT tokens and update 1Password item
 */
async function generateSupabaseJWTs(itemTitle = 'Supabase Instance') {
    try {
        console.log(`🔐 Processing 1Password item: ${itemTitle}`);
        
        // Get item ID
        const itemList = execSync(`op item list --format json`, { encoding: 'utf8' });
        const items = JSON.parse(itemList);
        const item = items.find(i => i.title === itemTitle);
        
        if (!item) {
            throw new Error(`Item "${itemTitle}" not found in 1Password`);
        }
        
        console.log(`📝 Found item ID: ${item.id}`);
        
        // Get JWT secret
        const jwtSecret = execSync(`op item get "${item.id}" --field jwt_secret`, { encoding: 'utf8' }).trim();
        
        if (!jwtSecret) {
            throw new Error('JWT secret not found in 1Password item');
        }
        
        // Generate timestamps
        const iat = Math.floor(Date.now() / 1000);
        const exp = iat + (5 * 365 * 24 * 60 * 60); // 5 years
        
        // Generate JWT tokens
        const anonPayload = {
            role: 'anon',
            iss: 'supabase',
            iat: iat,
            exp: exp
        };
        
        const servicePayload = {
            role: 'service_role',
            iss: 'supabase', 
            iat: iat,
            exp: exp
        };
        
        console.log('🔑 Generating JWT tokens...');
        const anonKey = jwt.sign(anonPayload, jwtSecret);
        const serviceRoleKey = jwt.sign(servicePayload, jwtSecret);
        
        // Update 1Password item
        console.log('💾 Updating 1Password item...');
        execSync(`op item edit "${item.id}" anon_key="${anonKey}"`);
        execSync(`op item edit "${item.id}" service_role_key="${serviceRoleKey}"`);
        
        console.log('✅ Successfully generated and saved JWT tokens!');
        
        return {
            itemId: item.id,
            anonKey,
            serviceRoleKey,
            expiresAt: new Date(exp * 1000).toISOString()
        };
        
    } catch (error) {
        console.error('❌ Error:', error.message);
        process.exit(1);
    }
}

// CLI usage
if (require.main === module) {
    const itemTitle = process.argv[2] || 'Supabase Instance';
    generateSupabaseJWTs(itemTitle);
}

module.exports = { generateSupabaseJWTs };