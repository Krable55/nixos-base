# Example Nuclio function configuration
# This shows how to define a trading account health check function
# with secrets integration via agenix

{ config, ... }:

{
  # Example function deployment configuration
  # To use this, add to your host configuration:
  #
  # imports = [ ../modules/nuclio/functions.nix ];
  # custom.nuclio-functions = {
  #   enable = true;
  #   functions.account-health = {
  #     # Copy the configuration from below
  #   };
  # };

  # This is the function definition that would go in your host config:
  functions.account-health = {
    handler = "handler:handler";
    runtime = "nodejs";
    description = "Check trading account health and balances";
    
    build = {
      baseImage = "node:18-slim";
      
      # Option 1: Use git repository (recommended for GitOps)
      repository = {
        url = "http://192.168.50.243:3000/kyllswitch/trader.git";
        ref = "main";  # branch, tag, or commit hash
        path = "/functions/account-health";  # path within repo
        workDir = "/app";  # optional build working directory
        # headers = { Authorization = "token ghp_xxx"; };  # for private repos
      };
      
      # Option 2: Inline source code (for simple functions)
      # codeEntryType = "sourceCode";
      # sourceCode = ''
      #   exports.handler = async (context, event) => {
      #     return { statusCode: 200, body: "Hello from account-health!" };
      #   };
      # '';
    };
    
    triggers = {
      http = {
        kind = "http";
        maxWorkers = 5;
      };
    };
    
    # Environment variables with secret references
    env = [
      {
        name = "NODE_ENV";
        value = "production";
      }
      {
        name = "ALPACA_API_KEY";
        valueFrom = {
          secretName = "trading-secrets";
          key = "alpaca-api-key";
        };
      }
      {
        name = "ALPACA_API_SECRET";
        valueFrom = {
          secretName = "trading-secrets";
          key = "alpaca-api-secret";
        };
      }
      {
        name = "ALPACA_BASE_URL";
        valueFrom = {
          secretName = "trading-secrets";
          key = "alpaca-base-url";
        };
      }
      {
        name = "SUPABASE_URL";
        valueFrom = {
          secretName = "trading-secrets";
          key = "supabase-url";
        };
      }
      {
        name = "SUPABASE_SERVICE_KEY";
        valueFrom = {
          secretName = "trading-secrets";
          key = "supabase-service-key";
        };
      }
    ];
    
    # Resource limits for the function
    resources = {
      limits = {
        memory = "256Mi";
        cpu = "200m";
      };
      requests = {
        memory = "128Mi";
        cpu = "100m";
      };
    };
    
    # Auto-scaling configuration
    minReplicas = 1;
    maxReplicas = 5;
    targetCPU = 20;
  };
}