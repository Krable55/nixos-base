# Hello World Nuclio function example
# Simple function demonstrating basic Nuclio configuration

{ config, ... }:

{
  # Example function deployment configuration
  # To use this, add to your host configuration:
  #
  # imports = [ ../modules/nuclio/functions.nix ];
  # custom.nuclio-functions = {
  #   enable = true;
  #   functions.hello-world = {
  #     # Copy the configuration from below
  #   };
  # };

  # Simple hello world function definition
  functions.hello-world = {
    handler = "handler:handler";
    runtime = "nodejs";
    description = "Simple hello world function";
    
    build = {
      baseImage = "node:18-alpine";
      
      # Inline source code for simplicity
      codeEntryType = "sourceCode";
      sourceCode = ''
        exports.handler = async (context, event) => {
          const name = event.body && event.body.name ? event.body.name : "World";
          
          context.logger.info("Hello function called with name: " + name);
          
          return {
            statusCode: 200,
            headers: {
              'Content-Type': 'application/json'
            },
            body: JSON.stringify({
              message: "Hello, " + name + "!",
              timestamp: new Date().toISOString(),
              event: event
            })
          };
        };
      '';
    };
    
    triggers = {
      http = {
        kind = "http";
        maxWorkers = 2;
      };
    };
    
    # Simple environment variables
    env = [
      {
        name = "NODE_ENV";
        value = "production";
      }
      {
        name = "FUNCTION_NAME";
        value = "hello-world";
      }
    ];
    
    # Resource limits for the function
    resources = {
      limits = {
        memory = "128Mi";
        cpu = "100m";
      };
      requests = {
        memory = "64Mi";
        cpu = "50m";
      };
    };
    
    # Auto-scaling configuration
    minReplicas = 1;
    maxReplicas = 3;
    targetCPU = 50;
  };
}

# This generates YAML like:
# apiVersion: "nuclio.io/v1"
# kind: NuclioFunction
# metadata:
#   name: hello-world
# spec:
#   handler: "handler:handler"
#   runtime: "nodejs"
#   description: "Simple hello world function"
#   build:
#     baseImage: "node:18-alpine"
#     codeEntryType: "sourceCode"
#     sourceCode: |
#       exports.handler = async (context, event) => {
#         // ... function code
#       };
#   triggers:
#     http:
#       kind: http
#       maxWorkers: 2
#   env:
#     - name: NODE_ENV
#       value: production
#     - name: FUNCTION_NAME
#       value: hello-world
#   resources:
#     limits:
#       memory: "128Mi"
#       cpu: "100m"
#     requests:
#       memory: "64Mi" 
#       cpu: "50m"
#   minReplicas: 1
#   maxReplicas: 3
#   targetCPU: 50