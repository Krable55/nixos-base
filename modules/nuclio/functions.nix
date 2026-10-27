{ config, pkgs, lib, ... }:

let
  cfg = config.custom.nuclio-functions;
  
  # Helper to convert function config to Nuclio JSON API format
  generateFunctionJSON = name: func: {
    metadata = {
      inherit name;
      namespace = func.namespace or "nuclio";
    };
    
    spec = {
      handler = func.handler;
      runtime = func.runtime;
    } // lib.optionalAttrs (func.description != null) {
      description = func.description;
    } // {
      
      build = {
        baseImage = func.build.baseImage;
      } // (
        if func.build.repository != null then {
          # Git repository source
          codeEntryType = func.build.codeEntryType;
          path = func.build.repository.url;  # Try setting path to the URL
          codeEntryAttributes = {
            # Repository configuration goes in codeEntryAttributes
            url = func.build.repository.url;
            branch = func.build.repository.branch or func.build.repository.ref or "main";
            workDir = func.build.repository.path;
          } // lib.optionalAttrs (func.build.repository.tag != null) {
            tag = func.build.repository.tag;
          } // lib.optionalAttrs (func.build.repository.reference != null) {
            reference = func.build.repository.reference;
          } // lib.optionalAttrs (func.build.repository.username != null) {
            username = func.build.repository.username;
          } // lib.optionalAttrs (func.build.repository.password != null) {
            password = func.build.repository.password;
          } // lib.optionalAttrs (func.build.repository.headers != null) {
            headers = func.build.repository.headers;
          };
        } else if func.build.sourceCode != null then {
          # Inline source code (base64 encoded)
          codeEntryType = "sourceCode";
          path = ".";
          functionSourceCode = builtins.readFile (pkgs.writeText "${name}-source-base64" 
            (lib.strings.fileContents (pkgs.runCommand "${name}-source-encoded" {} ''
              echo -n '${func.build.sourceCode}' | ${pkgs.coreutils}/bin/base64 -w 0 > $out
            '')));
        } else {
          # Default build
          path = ".";
          codeEntryType = func.build.codeEntryType;
        }
      );
      
      triggers = func.triggers;
      
    } // lib.optionalAttrs (func.env != []) {
      env = map (envVar: {
        name = envVar.name;
      } // (
        if envVar.value != null then {
          # Direct value
          value = envVar.value;
        } else if envVar.valueFrom.secretPath != null then {
          # Mark as secret - will be handled at deployment time
          _secretPath = envVar.valueFrom.secretPath;
        } else if envVar.valueFrom.secretName != null then {
          # Kubernetes secret reference (pass through)
          valueFrom.secretKeyRef = {
            name = envVar.valueFrom.secretName;
            key = envVar.valueFrom.key;
          };
        } else {
          # Fallback to empty value
          value = "";
        }
      )) func.env;
    } // lib.optionalAttrs (func.resources != null) {
      resources = func.resources;
    } // lib.optionalAttrs (func.minReplicas != null) {
      minReplicas = func.minReplicas;
    } // lib.optionalAttrs (func.maxReplicas != null) {
      maxReplicas = func.maxReplicas;
    } // lib.optionalAttrs (func.targetCPU != null) {
      targetCPU = func.targetCPU;
    };
  };
  
in {
  options.custom.nuclio-functions = {
    enable = lib.mkEnableOption "Enable declarative Nuclio function deployment";
    
    nuclioHost = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = "Hostname where Nuclio dashboard is running";
    };
    
    nuclioPort = lib.mkOption {
      type = lib.types.port;
      default = 8070;
      description = "Port where Nuclio dashboard is running";
    };
    
    secretsConfigMap = lib.mkOption {
      type = lib.types.str;
      default = "nuclio-secrets";
      description = "Name of the config map containing function secrets";
    };
    
    functions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          handler = lib.mkOption {
            type = lib.types.str;
            description = "Function handler (e.g., 'handler:handler')";
          };
          
          runtime = lib.mkOption {
            type = lib.types.str;
            default = "nodejs";
            description = "Function runtime (nodejs, python, golang, etc.)";
          };
          
          description = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Function description";
          };
          
          namespace = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Kubernetes namespace";
          };
          
          build = {
            baseImage = lib.mkOption {
              type = lib.types.str;
              default = "node:18-alpine";
              description = "Base container image for the function";
            };
            
            path = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = ".";
              description = "Build context path";
            };
            
            codeEntryType = lib.mkOption {
              type = lib.types.str;
              default = "git";
              description = "Code entry type (git, github, sourceCode, archive, etc.)";
            };
            
            sourceCode = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Inline source code for the function";
            };
            
            repository = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  url = lib.mkOption {
                    type = lib.types.str;
                    description = "Git repository URL (e.g., https://github.com/user/repo)";
                  };
                  
                  branch = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = "main";
                    description = "Git branch name (e.g., main, master, develop)";
                  };
                  
                  tag = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Git tag name (alternative to branch)";
                  };
                  
                  reference = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Git reference (commit hash, alternative to branch/tag)";
                  };
                  
                  username = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Git authentication username";
                  };
                  
                  password = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "Git authentication password";
                  };
                  
                  path = lib.mkOption {
                    type = lib.types.str;
                    default = "/";
                    description = "Work directory path within the repository";
                  };
                  
                  headers = lib.mkOption {
                    type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
                    default = null;
                    description = "HTTP headers for repository access (e.g., authorization tokens)";
                  };
                  
                  # Legacy support
                  ref = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "DEPRECATED: Use branch, tag, or reference instead";
                  };
                  
                  workDir = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "DEPRECATED: Use path instead";
                  };
                };
              });
              default = null;
              description = "Git repository source configuration";
            };
          };
          
          triggers = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                kind = lib.mkOption {
                  type = lib.types.str;
                  description = "Trigger kind (http, cron, etc.)";
                };
                
                maxWorkers = lib.mkOption {
                  type = lib.types.nullOr lib.types.int;
                  default = null;
                  description = "Maximum number of workers";
                };
                
                port = lib.mkOption {
                  type = lib.types.nullOr lib.types.port;
                  default = null;
                  description = "Port for HTTP triggers";
                };
              };
            });
            default = {
              http = {
                kind = "http";
                maxWorkers = 1;
              };
            };
            description = "Function triggers configuration";
          };
          
          env = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.str;
                  description = "Environment variable name";
                };
                
                value = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Environment variable value";
                };
                
                valueFrom = lib.mkOption {
                  type = lib.types.nullOr (lib.types.submodule {
                    options = {
                      secretName = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Secret name (for Kubernetes secrets)";
                      };
                      
                      key = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Secret key (for Kubernetes secrets)";
                      };

                      secretPath = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Path to agenix secret file";
                      };
                    };
                  });
                  default = null;
                  description = "Reference to secret value (Kubernetes secrets or agenix file path)";
                };
              };
            });
            default = [];
            description = "Environment variables for the function";
          };
          
          resources = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                limits = lib.mkOption {
                  type = lib.types.nullOr (lib.types.submodule {
                    options = {
                      memory = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Memory limit";
                      };
                      cpu = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "CPU limit";
                      };
                    };
                  });
                  default = null;
                };
                
                requests = lib.mkOption {
                  type = lib.types.nullOr (lib.types.submodule {
                    options = {
                      memory = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Memory request";
                      };
                      cpu = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "CPU request";
                      };
                    };
                  });
                  default = null;
                };
              };
            });
            default = null;
            description = "Resource limits and requests";
          };
          
          minReplicas = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Minimum number of replicas";
          };
          
          maxReplicas = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Maximum number of replicas";
          };
          
          targetCPU = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Target CPU percentage for autoscaling";
          };
        };
      });
      default = {};
      description = "Nuclio functions to deploy";
    };
  };
  
  config = lib.mkIf cfg.enable {
    # No need for intermediate files - we'll deploy directly
    
    # Create a deployment script
    environment.systemPackages = [
      (pkgs.writeScriptBin "deploy-nuclio-functions" ''
        #!${pkgs.bash}/bin/bash
        set -e
        
        NUCLIO_URL="http://${cfg.nuclioHost}:${toString cfg.nuclioPort}"
        FUNCTIONS_DIR="/etc/nuclio/functions"
        
        echo "🚀 Deploying Nuclio functions from $FUNCTIONS_DIR"
        echo "📡 Nuclio API: $NUCLIO_URL"
        echo
        
        if [ ! -d "$FUNCTIONS_DIR" ]; then
          echo "❌ No functions directory found at $FUNCTIONS_DIR"
          exit 1
        fi
        
        # Check if Nuclio is running
        if ! ${pkgs.curl}/bin/curl -f "$NUCLIO_URL/api/functions" >/dev/null 2>&1; then
          echo "❌ Nuclio dashboard not accessible at $NUCLIO_URL"
          echo "   Make sure Nuclio is running: systemctl status nuclio-docker"
          exit 1
        fi
        
        echo "✅ Nuclio dashboard is accessible"
        echo
        
        # Deploy each function
        for yaml_file in "$FUNCTIONS_DIR"/*.yaml; do
          if [ -f "$yaml_file" ]; then
            function_name=$(${pkgs.coreutils}/bin/basename "$yaml_file" .yaml)
            echo "📦 Deploying function: $function_name"
            
            if ${pkgs.curl}/bin/curl -f -X POST "$NUCLIO_URL/api/functions" \
              -H "Content-Type: application/yaml" \
              --data-binary @"$yaml_file" >/dev/null 2>&1; then
              echo "   ✅ Success"
            else
              echo "   ⚠️  Failed or already exists"
            fi
          fi
        done
        
        echo
        echo "🎉 Function deployment complete!"
        echo "📊 View functions: $NUCLIO_URL"
      '')
    ];
    
    # Systemd service for automatic function deployment
    systemd.services.nuclio-deploy-functions = {
      description = "Deploy Nuclio functions automatically";
      after = [ "nuclio-docker.service" "network-online.target" ];
      wants = [ "nuclio-docker.service" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        Restart = "no";
      };
      
      environment = {
        PATH = lib.mkForce (lib.makeBinPath (with pkgs; [ curl coreutils bash gnugrep gnused ]));
      };
      
      script = ''
        set -e
        
        NUCLIO_URL="http://${cfg.nuclioHost}:${toString cfg.nuclioPort}"
        
        echo "🚀 Auto-deploying ${toString (lib.length (lib.attrNames cfg.functions))} Nuclio function(s)"
        echo "📡 Nuclio API: $NUCLIO_URL"
        
        # Wait for Nuclio to be ready (up to 3 minutes)
        echo "⏳ Waiting for Nuclio dashboard to be ready..."
        timeout=180
        elapsed=0
        while [ $elapsed -lt $timeout ]; do
          if curl -f -s --connect-timeout 5 "$NUCLIO_URL/api/functions" >/dev/null 2>&1; then
            echo "✅ Nuclio dashboard is ready"
            break
          fi
          echo "  Waiting for Nuclio at $NUCLIO_URL... ($elapsed/$timeout seconds)"
          sleep 10
          elapsed=$((elapsed + 10))
        done
        
        # Final check if Nuclio is accessible
        if ! curl -f -s --connect-timeout 5 "$NUCLIO_URL/api/functions" >/dev/null 2>&1; then
          echo "❌ Nuclio dashboard not accessible after $timeout seconds"
          echo "ℹ️  Functions can be deployed manually later with: systemctl restart nuclio-deploy-functions"
          exit 0
        fi
        
        # Deploy each function with embedded JSON
        deployed=0
        failed=0
        
        ${lib.concatStringsSep "\n        " (lib.mapAttrsToList (name: func: ''
          echo "📦 Deploying function: ${name}"
          
          # Generate base JSON and inject secrets at runtime
          json_payload='${builtins.toJSON (generateFunctionJSON name func)}'
          
          # Replace secret placeholders with actual values
          ${lib.concatStringsSep "\n          " (lib.flatten (map (envVar: 
            if envVar.valueFrom != null && envVar.valueFrom.secretPath != null then [
              ''echo "   🔍 Looking for secret: ${envVar.valueFrom.secretPath}"''
              ''if [ -f "${envVar.valueFrom.secretPath}" ]; then''
              ''  echo "   ✅ Secret file found"''
              ''  secret_value=$(cat "${envVar.valueFrom.secretPath}")''
              ''  json_payload=$(echo "$json_payload" | sed "s|\"_secretPath\":\"${envVar.valueFrom.secretPath}\"|\"value\":\"$secret_value\"|g")''
              ''else''
              ''  echo "   ⚠️  Warning: Secret file not found: ${envVar.valueFrom.secretPath}"''
              ''  echo "   📂 Available files in /run/agenix/:"''
              ''  ls -la /run/agenix/ || echo "   📂 /run/agenix/ directory does not exist"''
              ''  json_payload=$(echo "$json_payload" | sed "s|\"_secretPath\":\"${envVar.valueFrom.secretPath}\"|\"value\":\"\"|g")''
              ''fi''
            ] else []
          ) func.env))}
          
          response=$(curl -s -X POST "$NUCLIO_URL/api/functions" \
            -H "Content-Type: application/json" \
            -d "$json_payload" 2>&1)
          
          if echo "$response" | grep -q '"error"'; then
            echo "   ❌ Failed: $(echo "$response" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)"
            failed=$((failed + 1))
          else
            echo "   ✅ Success"
            deployed=$((deployed + 1))
          fi
        '') cfg.functions)}
        
        if [ $deployed -eq 0 ] && [ $failed -eq 0 ]; then
          echo "ℹ️  No functions configured"
        elif [ $failed -gt 0 ]; then
          echo "⚠️  Deployed $deployed function(s), failed $failed"
        else
          echo "🎉 Deployed $deployed function(s) successfully!"
        fi
        echo "📊 View functions: $NUCLIO_URL"
      '';
    };
  };
}