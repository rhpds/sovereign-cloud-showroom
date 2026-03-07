#!/bin/bash

# Script to install Red Hat Trusted Artifact Signer (RHTAS) with Red Hat SSO (Keycloak) as OIDC provider on OpenShift
# Assumes oc is installed and user is logged in as cluster-admin
# Assumes Red Hat SSO (Keycloak) is installed in the rhsso namespace
# Usage: ./08-install-trusted-artifact-signer.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Step 1: Get Red Hat SSO (Keycloak) OIDC Issuer URL
echo "Retrieving Red Hat SSO (Keycloak) OIDC Issuer URL..."

# Check if Keycloak namespace exists
if ! oc get namespace rhsso >/dev/null 2>&1; then
    echo "Error: Namespace 'rhsso' does not exist"
    echo "Please install Red Hat SSO (Keycloak) first by running: ./01-keycloak.sh"
    exit 1
fi

# Determine the correct CRD name (try both singular and plural)
KEYCLOAK_CRD="keycloaks"
if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloaks.keycloak.org >/dev/null 2>&1; then
    KEYCLOAK_CRD="keycloaks"
elif oc get crd keycloak.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloak.keycloak.org >/dev/null 2>&1; then
    KEYCLOAK_CRD="keycloak"
else
    # Try to determine by attempting to list resources
    if oc get keycloaks -n rhsso >/dev/null 2>&1; then
        KEYCLOAK_CRD="keycloaks"
    elif oc get keycloak -n rhsso >/dev/null 2>&1; then
        KEYCLOAK_CRD="keycloak"
    else
        KEYCLOAK_CRD="keycloak"
    fi
fi

KEYCLOAK_CR_NAME="rhsso-instance"

# Check if Keycloak CR exists, or if resources are running
KEYCLOAK_CR_EXISTS=false
if oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n rhsso >/dev/null 2>&1; then
    KEYCLOAK_CR_EXISTS=true
elif oc get $KEYCLOAK_CRD keycloak -n rhsso >/dev/null 2>&1; then
    KEYCLOAK_CR_NAME="keycloak"
    KEYCLOAK_CR_EXISTS=true
else
    # Check if resources are running even without CR
    KEYCLOAK_STS_READY=$(oc get statefulset keycloak -n rhsso -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
    KEYCLOAK_POD_RUNNING=$(oc get pod -n rhsso -l app=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    
    if [ "$KEYCLOAK_STS_READY" = "1/1" ] && [ "$KEYCLOAK_POD_RUNNING" = "Running" ]; then
        echo "✓ Keycloak resources are running (CR not found, but installation appears successful)"
        KEYCLOAK_CR_EXISTS=false
    else
        echo "Error: Keycloak custom resource not found in rhsso namespace and resources are not running"
        echo "Please install Red Hat SSO (Keycloak) first by running: ./01-keycloak.sh"
        exit 1
    fi
fi

KEYCLOAK_ROUTE=$(oc get route keycloak -n rhsso -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$KEYCLOAK_ROUTE" ]; then
    echo "Error: Could not retrieve Keycloak route from rhsso namespace"
    echo "Keycloak may still be installing. Please wait for it to be ready, or run: ./01-keycloak.sh"
    exit 1
fi

KEYCLOAK_URL="https://${KEYCLOAK_ROUTE}"
OIDC_ISSUER_URL="${KEYCLOAK_URL}/auth/realms/openshift"
echo "✓ Red Hat SSO (Keycloak) URL: $KEYCLOAK_URL"
echo "✓ OIDC Issuer URL: $OIDC_ISSUER_URL"

# Step 2: Wait for Keycloak instance to be ready before creating realms/clients
echo "Waiting for Keycloak instance to be ready..."
KEYCLOAK_CR_NAME="rhsso-instance"
KEYCLOAK_CRD="keycloaks"
if ! oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n rhsso >/dev/null 2>&1; then
    KEYCLOAK_CRD="keycloak"
fi

MAX_WAIT_KEYCLOAK=300
WAIT_COUNT=0
KEYCLOAK_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT_KEYCLOAK ]; do
    # First check CR status if CR exists
    KEYCLOAK_READY_STATUS=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    KEYCLOAK_PHASE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    # Check if CR status indicates ready
    if [ "$KEYCLOAK_READY_STATUS" = "true" ] || [ "$KEYCLOAK_PHASE" = "reconciled" ]; then
        KEYCLOAK_READY=true
        echo "✓ Keycloak instance is ready (CR status)"
        break
    fi
    
    # Fallback: Check if Keycloak pods are running
    KEYCLOAK_PODS_READY=$(oc get pods -n rhsso -l app=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [ "$KEYCLOAK_PODS_READY" = "Running" ]; then
        # Check if route exists and pods are running - consider it ready
        if [ -n "$KEYCLOAK_ROUTE" ]; then
            KEYCLOAK_READY=true
            echo "✓ Keycloak instance is ready (pods running and route available)"
            break
        else
            # If pods are running but no route check, consider it ready
            KEYCLOAK_READY=true
            echo "✓ Keycloak instance is ready (pods running)"
            break
        fi
    fi
    
    # Alternative: Check StatefulSet ready replicas
    KEYCLOAK_STS_READY=$(oc get statefulset keycloak -n rhsso -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
    if [ -n "$KEYCLOAK_STS_READY" ] && [ "$KEYCLOAK_STS_READY" != "0/0" ] && [ "$KEYCLOAK_STS_READY" != "/" ]; then
        READY_REPLICAS=$(echo "$KEYCLOAK_STS_READY" | cut -d'/' -f1)
        TOTAL_REPLICAS=$(echo "$KEYCLOAK_STS_READY" | cut -d'/' -f2)
        if [ "$READY_REPLICAS" -ge 1 ] && [ "$READY_REPLICAS" = "$TOTAL_REPLICAS" ] 2>/dev/null; then
            KEYCLOAK_READY=true
            echo "✓ Keycloak instance is ready (StatefulSet ready)"
            break
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for Keycloak instance... (${WAIT_COUNT}s/${MAX_WAIT_KEYCLOAK}s) - Phase: ${KEYCLOAK_PHASE:-unknown}, Ready: ${KEYCLOAK_READY_STATUS:-false}, Pods: ${KEYCLOAK_PODS_READY:-none}"
    fi
done

if [ "$KEYCLOAK_READY" = false ]; then
    echo "Warning: Keycloak instance did not become ready within ${MAX_WAIT_KEYCLOAK} seconds, but continuing..."
    echo "  Checking current status..."
    oc get pods -n rhsso -l app=keycloak 2>/dev/null || echo "  No Keycloak pods found"
    oc get route keycloak -n rhsso 2>/dev/null || echo "  No Keycloak route found"
fi

# Step 3: Ensure OpenShift realm exists (using KeycloakRealm CR)
echo ""
echo "Ensuring OpenShift realm exists..."
REALM="openshift"
REALM_CR_NAME="openshift"

# Check if KeycloakRealm CR exists
if oc get keycloakrealm $REALM_CR_NAME -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakRealm CR '${REALM_CR_NAME}' already exists"
    
    # Wait for realm to be ready/reconciled
    echo "Waiting for realm to be reconciled..."
    MAX_WAIT_REALM=300
    WAIT_COUNT=0
    REALM_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_REALM ]; do
        REALM_STATUS=$(oc get keycloakrealm $REALM_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        REALM_PHASE=$(oc get keycloakrealm $REALM_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$REALM_STATUS" = "true" ] || [ "$REALM_PHASE" = "reconciled" ]; then
            REALM_READY=true
            echo "✓ Realm is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for realm... (${WAIT_COUNT}s/${MAX_WAIT_REALM}s) - Phase: ${REALM_PHASE:-unknown}, Ready: ${REALM_STATUS:-false}"
        fi
    done
    
    if [ "$REALM_READY" = false ]; then
        echo "Warning: Realm did not become reconciled within ${MAX_WAIT_REALM} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakRealm CR '${REALM_CR_NAME}'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakRealm
metadata:
  name: ${REALM_CR_NAME}
  namespace: rhsso
  labels:
    app: openshift
spec:
  instanceSelector:
    matchLabels:
      app: sso
  realm:
    displayName: Openshift Authentication Realm
    enabled: true
    id: ${REALM}
    realm: ${REALM}
EOF
    then
        echo "Error: Failed to create KeycloakRealm CR"
        exit 1
    fi
    
    echo "✓ KeycloakRealm CR created successfully"
    
    # Wait for realm to be ready/reconciled
    echo "Waiting for realm to be reconciled..."
    MAX_WAIT_REALM=300
    WAIT_COUNT=0
    REALM_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_REALM ]; do
        REALM_STATUS=$(oc get keycloakrealm $REALM_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        REALM_PHASE=$(oc get keycloakrealm $REALM_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$REALM_STATUS" = "true" ] || [ "$REALM_PHASE" = "reconciled" ]; then
            REALM_READY=true
            echo "✓ Realm is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for realm... (${WAIT_COUNT}s/${MAX_WAIT_REALM}s) - Phase: ${REALM_PHASE:-unknown}, Ready: ${REALM_STATUS:-false}"
        fi
    done
    
    if [ "$REALM_READY" = false ]; then
        echo "Warning: Realm did not become reconciled within ${MAX_WAIT_REALM} seconds, but continuing..."
    fi
fi

# Step 3a: Create OpenShift OAuth Client
echo ""
echo "Creating OpenShift OAuth Client..."
CLIENT_CR_NAME_OCP="openshift"
CLIENT_YAML_FILE="${SCRIPT_DIR}/keycloak-client-openshift.yaml"

if oc get keycloakclient $CLIENT_CR_NAME_OCP -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakClient CR '${CLIENT_CR_NAME_OCP}' already exists"
    
    # Wait for client to be ready/reconciled
    echo "Waiting for client to be reconciled..."
    MAX_WAIT_CLIENT=300
    WAIT_COUNT=0
    CLIENT_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_CLIENT ]; do
        CLIENT_STATUS=$(oc get keycloakclient $CLIENT_CR_NAME_OCP -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        CLIENT_PHASE=$(oc get keycloakclient $CLIENT_CR_NAME_OCP -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$CLIENT_STATUS" = "true" ] || [ "$CLIENT_PHASE" = "reconciled" ]; then
            CLIENT_READY=true
            echo "✓ Client is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for client... (${WAIT_COUNT}s/${MAX_WAIT_CLIENT}s) - Phase: ${CLIENT_PHASE:-unknown}, Ready: ${CLIENT_STATUS:-false}"
        fi
    done
    
    if [ "$CLIENT_READY" = false ]; then
        echo "Warning: Client did not become reconciled within ${MAX_WAIT_CLIENT} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakClient CR '${CLIENT_CR_NAME_OCP}' from ${CLIENT_YAML_FILE}..."
    
    if [ ! -f "$CLIENT_YAML_FILE" ]; then
        echo "Error: YAML file not found: ${CLIENT_YAML_FILE}"
        exit 1
    fi
    
    if ! oc apply -f "$CLIENT_YAML_FILE"; then
        echo "Error: Failed to create KeycloakClient CR"
        exit 1
    fi
    
    echo "✓ KeycloakClient CR created successfully"
    
    # Wait for client to be ready/reconciled
    echo "Waiting for client to be reconciled..."
    MAX_WAIT_CLIENT=300
    WAIT_COUNT=0
    CLIENT_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_CLIENT ]; do
        CLIENT_STATUS=$(oc get keycloakclient $CLIENT_CR_NAME_OCP -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        CLIENT_PHASE=$(oc get keycloakclient $CLIENT_CR_NAME_OCP -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$CLIENT_STATUS" = "true" ] || [ "$CLIENT_PHASE" = "reconciled" ]; then
            CLIENT_READY=true
            echo "✓ Client is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for client... (${WAIT_COUNT}s/${MAX_WAIT_CLIENT}s) - Phase: ${CLIENT_PHASE:-unknown}, Ready: ${CLIENT_STATUS:-false}"
        fi
    done
    
    if [ "$CLIENT_READY" = false ]; then
        echo "Warning: Client did not become reconciled within ${MAX_WAIT_CLIENT} seconds, but continuing..."
    fi
fi

# Step 4: Create Keycloak User for authentication
echo ""
echo "Creating Keycloak User for authentication..."
KEYCLOAK_USER_NAME="admin"
KEYCLOAK_USER_USERNAME="admin"
KEYCLOAK_USER_EMAIL="admin@demo.redhat.com"
KEYCLOAK_USER_PASSWORD="116608"  # Default password, can be changed

# Check if KeycloakUser CR already exists
if oc get keycloakuser $KEYCLOAK_USER_NAME -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakUser CR '${KEYCLOAK_USER_NAME}' already exists"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakUser CR '${KEYCLOAK_USER_NAME}'..."
    
    # Encode password to base64
    KEYCLOAK_USER_PASSWORD_B64=$(echo -n "$KEYCLOAK_USER_PASSWORD" | base64)
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakUser
metadata:
  name: ${KEYCLOAK_USER_NAME}
  namespace: rhsso
  labels:
    app: openshift
spec:
  realmSelector:
    matchLabels:
      app: openshift
  user:
    username: ${KEYCLOAK_USER_USERNAME}
    email: ${KEYCLOAK_USER_EMAIL}
    emailVerified: true
    enabled: true
    credentials:
      - type: password
        value: ${KEYCLOAK_USER_PASSWORD_B64}
EOF
    then
        echo "Error: Failed to create KeycloakUser CR"
        exit 1
    fi
    
    echo "✓ KeycloakUser CR created successfully"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
fi

# Step 3b: Create jdoe Keycloak User for signing
echo ""
echo "Creating jdoe Keycloak User for signing..."
KEYCLOAK_USER_NAME_JDOE="jdoe"
KEYCLOAK_USER_USERNAME_JDOE="jdoe"
KEYCLOAK_USER_EMAIL_JDOE="jdoe@redhat.com"
KEYCLOAK_USER_PASSWORD_JDOE="secure"

# Check if KeycloakUser CR already exists
if oc get keycloakuser $KEYCLOAK_USER_NAME_JDOE -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakUser CR '${KEYCLOAK_USER_NAME_JDOE}' already exists"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME_JDOE -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakUser CR '${KEYCLOAK_USER_NAME_JDOE}'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakUser
metadata:
  name: ${KEYCLOAK_USER_NAME_JDOE}
  namespace: rhsso
  labels:
    app: trusted-artifact-signer
spec:
  realmSelector:
    matchLabels:
      app: openshift
  user:
    username: ${KEYCLOAK_USER_USERNAME_JDOE}
    email: ${KEYCLOAK_USER_EMAIL_JDOE}
    emailVerified: true
    enabled: true
    firstName: Jane
    lastName: Doe
    credentials:
      - type: password
        value: ${KEYCLOAK_USER_PASSWORD_JDOE}
EOF
    then
        echo "Error: Failed to create KeycloakUser CR for jdoe"
        exit 1
    fi
    
    echo "✓ KeycloakUser CR created successfully"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME_JDOE -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
fi

# Step 3c: Create user1 Keycloak User
echo ""
echo "Creating user1 Keycloak User..."
KEYCLOAK_USER_NAME_USER1="user1"
USER_YAML_FILE="${SCRIPT_DIR}/keycloak-user-user1.yaml"

# Check if KeycloakUser CR already exists
if oc get keycloakuser $KEYCLOAK_USER_NAME_USER1 -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakUser CR '${KEYCLOAK_USER_NAME_USER1}' already exists"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME_USER1 -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakUser CR '${KEYCLOAK_USER_NAME_USER1}' from ${USER_YAML_FILE}..."
    
    if [ ! -f "$USER_YAML_FILE" ]; then
        echo "Error: YAML file not found: ${USER_YAML_FILE}"
        exit 1
    fi
    
    if ! oc apply -f "$USER_YAML_FILE"; then
        echo "Error: Failed to create KeycloakUser CR"
        exit 1
    fi
    
    echo "✓ KeycloakUser CR created successfully"
    
    # Wait for user to be ready
    echo "Waiting for user to be ready..."
    MAX_WAIT_USER=120
    WAIT_COUNT=0
    USER_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_USER ]; do
        USER_PHASE=$(oc get keycloakuser $KEYCLOAK_USER_NAME_USER1 -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$USER_PHASE" = "reconciled" ]; then
            USER_READY=true
            echo "✓ User is ready"
            break
        fi
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 2))
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for user to be ready... (${WAIT_COUNT}s/${MAX_WAIT_USER}s) - Phase: ${USER_PHASE:-unknown}"
        fi
    done
    
    if [ "$USER_READY" = false ]; then
        echo "Warning: User did not become ready within ${MAX_WAIT_USER} seconds, but continuing..."
    fi
fi

# Step 4: Create OAuth Client in Red Hat SSO (Keycloak) for Trusted Artifact Signer
echo ""
echo "Creating OAuth Client in Red Hat SSO (Keycloak) for Trusted Artifact Signer..."
OIDC_CLIENT_ID="trusted-artifact-signer"
CLIENT_CR_NAME="trusted-artifact-signer"

# Check if KeycloakClient CR already exists
if oc get keycloakclient $CLIENT_CR_NAME -n rhsso >/dev/null 2>&1; then
    echo "✓ KeycloakClient CR '${CLIENT_CR_NAME}' already exists"
    
    # Wait for client to be ready/reconciled
    echo "Waiting for client to be reconciled..."
    MAX_WAIT_CLIENT=300
    WAIT_COUNT=0
    CLIENT_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_CLIENT ]; do
        CLIENT_STATUS=$(oc get keycloakclient $CLIENT_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        CLIENT_PHASE=$(oc get keycloakclient $CLIENT_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$CLIENT_STATUS" = "true" ] || [ "$CLIENT_PHASE" = "reconciled" ]; then
            CLIENT_READY=true
            echo "✓ Client is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for client... (${WAIT_COUNT}s/${MAX_WAIT_CLIENT}s) - Phase: ${CLIENT_PHASE:-unknown}, Ready: ${CLIENT_STATUS:-false}"
        fi
    done
    
    if [ "$CLIENT_READY" = false ]; then
        echo "Warning: Client did not become reconciled within ${MAX_WAIT_CLIENT} seconds, but continuing..."
    fi
else
    echo "Creating KeycloakClient CR '${CLIENT_CR_NAME}'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakClient
metadata:
  name: ${CLIENT_CR_NAME}
  namespace: rhsso
  labels:
    app: keycloak
spec:
  realmSelector:
    matchLabels:
      app: openshift
  client:
    clientId: ${OIDC_CLIENT_ID}
    enabled: true
    protocol: openid-connect
    publicClient: true
    standardFlowEnabled: true
    directAccessGrantsEnabled: true
    redirectUris:
      - "http://localhost/auth/callback"
      - "urn:ietf:wg:oauth:2.0:oob"
    webOrigins:
      - "+"
    defaultClientScopes:
      - profile
      - email
    defaultScopes:
      - "openid"
      - "email"
    protocolMappers:
      - name: audience-mapper
        protocol: openid-connect
        protocolMapper: oidc-audience-mapper
        config:
          included.client.audience: "${OIDC_CLIENT_ID}"
          id.token.claim: "true"
          access.token.claim: "true"
    attributes:
      access.token.lifespan: "300"
EOF
    # Note: The protocol mapper sets the audience (aud) claim to the client ID (${OIDC_CLIENT_ID})
    # which is "trusted-artifact-signer". This matches what Fulcio expects for OIDC token verification.
    then
        echo "Error: Failed to create KeycloakClient CR"
        exit 1
    fi
    
    echo "✓ KeycloakClient CR created successfully"
    
    echo ""
    echo "NOTE: If the protocol mapper is not supported by the KeycloakClient CRD, you may need to"
    echo "manually configure the Audience protocol mapper in Keycloak admin console:"
    echo "  1. Log into Keycloak admin console"
    echo "  2. Navigate to Clients -> ${OIDC_CLIENT_ID}"
    echo "  3. Go to Client scopes tab -> ${OIDC_CLIENT_ID}-dedicated -> Mappers"
    echo "  4. Add mapper -> By configuration -> Audience"
    echo "  5. Set 'Included Client Audience' to '${OIDC_CLIENT_ID}'"
    echo "  6. Enable 'Add to ID token' and 'Add to access token'"
    echo ""
    
    # Wait for client to be ready/reconciled
    echo "Waiting for client to be reconciled..."
    MAX_WAIT_CLIENT=300
    WAIT_COUNT=0
    CLIENT_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT_CLIENT ]; do
        CLIENT_STATUS=$(oc get keycloakclient $CLIENT_CR_NAME -n rhsso -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        CLIENT_PHASE=$(oc get keycloakclient $CLIENT_CR_NAME -n rhsso -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        if [ "$CLIENT_STATUS" = "true" ] || [ "$CLIENT_PHASE" = "reconciled" ]; then
            CLIENT_READY=true
            echo "✓ Client is reconciled"
            break
        fi
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            echo "  Still waiting for client... (${WAIT_COUNT}s/${MAX_WAIT_CLIENT}s) - Phase: ${CLIENT_PHASE:-unknown}, Ready: ${CLIENT_STATUS:-false}"
        fi
    done
    
    if [ "$CLIENT_READY" = false ]; then
        echo "Warning: Client did not become reconciled within ${MAX_WAIT_CLIENT} seconds, but continuing..."
    fi
fi

# Check if client secret was created
CLIENT_SECRET_NAME="keycloak-client-secret-${CLIENT_CR_NAME}"
if oc get secret $CLIENT_SECRET_NAME -n rhsso >/dev/null 2>&1; then
    echo "✓ Client secret '${CLIENT_SECRET_NAME}' exists"
    CLIENT_ID_FROM_SECRET=$(oc get secret $CLIENT_SECRET_NAME -n rhsso -o jsonpath='{.data.CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$CLIENT_ID_FROM_SECRET" ]; then
        echo "  Client ID from secret: ${CLIENT_ID_FROM_SECRET}"
    fi
else
    echo "Note: Client secret '${CLIENT_SECRET_NAME}' not yet created (may be created after Trusted Artifact Signer installation)"
fi

# Step 5: Install RHTAS Operator
echo "Installing RHTAS Operator..."

# Ensure we're targeting the correct namespace
OPERATOR_NAMESPACE="openshift-operators"

# Check if subscription already exists in the correct namespace
if oc get subscription trusted-artifact-signer -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    echo "RHTAS Operator subscription 'trusted-artifact-signer' already exists in $OPERATOR_NAMESPACE, skipping creation"
else
    # Clean up any subscriptions in wrong namespaces (optional, but helpful)
    echo "Checking for subscriptions in incorrect namespaces..."
    WRONG_SUBS=$(oc get subscription -A -o jsonpath='{range .items[?(@.metadata.name=="trusted-artifact-signer" && @.metadata.namespace!="openshift-operators")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
    if [ -n "$WRONG_SUBS" ]; then
        echo "Warning: Found subscriptions in incorrect namespaces:"
        echo "$WRONG_SUBS" | while read -r ns name; do
            echo "  - $ns/$name"
        done
        echo "  These should only exist in $OPERATOR_NAMESPACE namespace"
        echo "  To clean them up, run: oc delete subscription trusted-artifact-signer -n <namespace>"
    fi
    
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: trusted-artifact-signer
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhtas-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: rhtas-operator.v1.3.1
EOF
    echo "✓ RHTAS Operator subscription created in $OPERATOR_NAMESPACE namespace"
fi

# Wait for RHTAS Operator to be ready
echo "Waiting for RHTAS Operator to be ready..."

# First, wait for CSV to appear
echo "Waiting for CSV to be created..."
CSV_NAME=""
MAX_WAIT_CSV=120
WAIT_COUNT=0

while [ $WAIT_COUNT -lt $MAX_WAIT_CSV ]; do
    # Try multiple methods to find the CSV
    CSV_NAME=$(oc get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName=="Trusted Artifact Signer Operator")].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep -i "trusted-artifact-signer\|rhtas" | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    fi
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n openshift-operators -l operators.coreos.com/trusted-artifact-signer.openshift-operators -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$CSV_NAME" ]; then
        echo "✓ Found CSV: $CSV_NAME"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for CSV to appear... (${WAIT_COUNT}s/${MAX_WAIT_CSV}s)"
        echo "    Checking available CSVs..."
        oc get csv -n openshift-operators -o name 2>/dev/null | head -3 || echo "    No CSVs found yet"
    fi
done

if [ -z "$CSV_NAME" ]; then
    echo "Error: Could not find RHTAS Operator CSV after ${MAX_WAIT_CSV} seconds"
    echo "Please check the subscription status:"
    oc get subscription trusted-artifact-signer -n openshift-operators -o yaml
    exit 1
fi

# Wait for CSV to be in Succeeded phase AND deployment to be ready
echo "Waiting for CSV to be installed (Succeeded phase) and deployment to be ready..."
MAX_WAIT_CSV_INSTALL=600
WAIT_COUNT=0
CSV_SUCCEEDED=false
DEPLOYMENT_READY=false

# Find the deployment name
DEPLOYMENT_NAME=""
while [ $WAIT_COUNT -lt $MAX_WAIT_CSV_INSTALL ]; do
    CSV_PHASE=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    CSV_CONDITIONS=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
    
    # Try to find the deployment name from CSV
    if [ -z "$DEPLOYMENT_NAME" ]; then
        DEPLOYMENT_NAME=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.spec.install.spec.deployments[*].name}' 2>/dev/null | awk '{print $1}' || echo "")
        if [ -z "$DEPLOYMENT_NAME" ]; then
            # Try alternative method - look for deployments with operator name
            DEPLOYMENT_NAME=$(oc get deployment -n openshift-operators -o name 2>/dev/null | grep -i "rhtas\|trusted-artifact-signer" | head -1 | sed 's|deployment.apps/||' || echo "")
        fi
    fi
    
    # Check CSV phase
    if [ "$CSV_PHASE" = "Succeeded" ]; then
        CSV_SUCCEEDED=true
        
        # Also check if deployment is actually ready
        if [ -n "$DEPLOYMENT_NAME" ]; then
            DEPLOYMENT_READY_REPLICAS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            DEPLOYMENT_REPLICAS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
            
            if [ "$DEPLOYMENT_READY_REPLICAS" = "$DEPLOYMENT_REPLICAS" ] && [ "$DEPLOYMENT_READY_REPLICAS" != "0" ]; then
                DEPLOYMENT_READY=true
                echo "✓ CSV is in Succeeded phase"
                echo "✓ Deployment $DEPLOYMENT_NAME is ready ($DEPLOYMENT_READY_REPLICAS/$DEPLOYMENT_REPLICAS replicas)"
                break
            else
                # CSV says succeeded but deployment isn't ready yet
                if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
                    echo "  CSV is Succeeded but deployment not ready yet... (${WAIT_COUNT}s/${MAX_WAIT_CSV_INSTALL}s)"
                    echo "    Deployment $DEPLOYMENT_NAME: $DEPLOYMENT_READY_REPLICAS/$DEPLOYMENT_REPLICAS replicas ready"
                    # Check deployment conditions
                    DEPLOYMENT_CONDITIONS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
                    if [ -n "$DEPLOYMENT_CONDITIONS" ]; then
                        echo "    Deployment conditions: ${DEPLOYMENT_CONDITIONS}"
                    fi
                fi
            fi
        else
            # Can't find deployment, but CSV is succeeded - might be OK
            echo "✓ CSV is in Succeeded phase (deployment name not found, will check pods)"
            break
        fi
    elif [ "$CSV_PHASE" = "Failed" ]; then
        echo "Error: CSV installation failed. Phase: $CSV_PHASE"
        echo "CSV conditions:"
        oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.conditions[*]}' 2>/dev/null || echo "  No conditions found"
        exit 1
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for CSV installation... (${WAIT_COUNT}s/${MAX_WAIT_CSV_INSTALL}s) - Phase: ${CSV_PHASE:-Unknown}"
        if [ -n "$CSV_CONDITIONS" ]; then
            echo "    Conditions: ${CSV_CONDITIONS}"
        fi
        if [ -n "$DEPLOYMENT_NAME" ]; then
            DEPLOYMENT_STATUS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
            echo "    Deployment $DEPLOYMENT_NAME Available status: ${DEPLOYMENT_STATUS:-Unknown}"
        fi
    fi
done

if [ "$CSV_SUCCEEDED" = false ]; then
    echo "Warning: CSV did not reach Succeeded phase within ${MAX_WAIT_CSV_INSTALL} seconds"
    echo "Current CSV status:"
    oc get csv $CSV_NAME -n openshift-operators -o yaml | grep -A 10 "status:" || echo "  Could not retrieve CSV status"
    echo ""
    echo "Continuing, but operator may not be fully ready..."
elif [ "$DEPLOYMENT_READY" = false ] && [ -n "$DEPLOYMENT_NAME" ]; then
    echo "Warning: CSV is Succeeded but deployment $DEPLOYMENT_NAME is not ready"
    echo "Deployment status:"
    oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o yaml | grep -A 15 "status:" || echo "  Could not retrieve deployment status"
    echo ""
    echo "Checking deployment events:"
    oc get events -n openshift-operators --field-selector involvedObject.name=$DEPLOYMENT_NAME --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5 || echo "  No recent events"
    echo ""
    echo "Continuing, but operator pods may not be running..."
fi

# Wait for CRDs to be installed
echo ""
echo "Waiting for RHTAS CRDs to be installed..."
MAX_WAIT_CRD=300
WAIT_COUNT=0
CRDS_INSTALLED=false

REQUIRED_CRDS=(
    "securesigns.rhtas.redhat.com"
    "tufs.rhtas.redhat.com"
    "fulcios.rhtas.redhat.com"
    "rekors.rhtas.redhat.com"
)

while [ $WAIT_COUNT -lt $MAX_WAIT_CRD ]; do
    ALL_CRDS_EXIST=true
    MISSING_CRDS=""
    
    for crd in "${REQUIRED_CRDS[@]}"; do
        if ! oc get crd "$crd" >/dev/null 2>&1; then
            ALL_CRDS_EXIST=false
            MISSING_CRDS="${MISSING_CRDS} ${crd}"
        fi
    done
    
    if [ "$ALL_CRDS_EXIST" = true ]; then
        CRDS_INSTALLED=true
        echo "✓ All required CRDs are installed"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for CRDs... (${WAIT_COUNT}s/${MAX_WAIT_CRD}s)"
        echo "    Missing CRDs:${MISSING_CRDS}"
    fi
done

if [ "$CRDS_INSTALLED" = false ]; then
    echo "Error: Required CRDs were not installed within ${MAX_WAIT_CRD} seconds"
    echo "Missing CRDs:${MISSING_CRDS}"
    echo ""
    echo "Please check operator logs:"
    echo "  oc logs -n openshift-operators -l name=trusted-artifact-signer-operator --tail=50"
    exit 1
fi

# Wait for operator pods to be running
echo ""
echo "Waiting for RHTAS operator pods to be running..."

# Find deployment name if not already found
if [ -z "$DEPLOYMENT_NAME" ]; then
    DEPLOYMENT_NAME=$(oc get deployment -n openshift-operators -o name 2>/dev/null | grep -i "rhtas\|trusted-artifact-signer\|controller-manager" | head -1 | sed 's|deployment.apps/||' || echo "")
    if [ -z "$DEPLOYMENT_NAME" ]; then
        # Try to get from CSV
        DEPLOYMENT_NAME=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.spec.install.spec.deployments[*].name}' 2>/dev/null | awk '{print $1}' || echo "")
    fi
fi

MAX_WAIT_PODS=300
WAIT_COUNT=0
OPERATOR_PODS_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT_PODS ]; do
    # First check deployment status if we found it
    if [ -n "$DEPLOYMENT_NAME" ]; then
        DEPLOYMENT_READY_REPLICAS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        DEPLOYMENT_REPLICAS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        DEPLOYMENT_AVAILABLE=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        
        if [ "$DEPLOYMENT_READY_REPLICAS" = "$DEPLOYMENT_REPLICAS" ] && [ "$DEPLOYMENT_READY_REPLICAS" != "0" ] && [ "$DEPLOYMENT_AVAILABLE" = "True" ]; then
            OPERATOR_PODS_READY=true
            echo "✓ Deployment $DEPLOYMENT_NAME is ready ($DEPLOYMENT_READY_REPLICAS/$DEPLOYMENT_REPLICAS replicas)"
            break
        fi
    fi
    
    # Also check pods directly
    OPERATOR_PODS=$(oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "$OPERATOR_PODS" -gt 0 ]; then
        # Check if pods are actually ready
        READY_PODS=$(oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator --field-selector=status.phase=Running -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null | wc -w || echo "0")
        if [ "$READY_PODS" -gt 0 ]; then
            OPERATOR_PODS_READY=true
            echo "✓ Operator pods are running and ready"
            break
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for operator pods... (${WAIT_COUNT}s/${MAX_WAIT_PODS}s)"
        echo "    Operator pods status:"
        oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator 2>/dev/null || echo "    No operator pods found"
        
        # Check for deployments
        echo "    Checking for operator deployment:"
        if [ -n "$DEPLOYMENT_NAME" ]; then
            oc get deployment $DEPLOYMENT_NAME -n openshift-operators 2>/dev/null || echo "    Deployment $DEPLOYMENT_NAME not found"
            if [ -n "$DEPLOYMENT_NAME" ]; then
                DEPLOYMENT_STATUS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
                DEPLOYMENT_MSG=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null || echo "")
                echo "    Deployment $DEPLOYMENT_NAME Available: ${DEPLOYMENT_STATUS:-Unknown}"
                if [ -n "$DEPLOYMENT_MSG" ]; then
                    echo "    Message: $DEPLOYMENT_MSG"
                fi
            fi
        else
            oc get deployment -n openshift-operators -l name=trusted-artifact-signer-operator 2>/dev/null || echo "    No deployment found"
        fi
        
        # Check for any pods with errors
        echo "    Checking for pods in error states:"
        oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator --field-selector=status.phase!=Running 2>/dev/null || echo "    No non-running pods found"
        
        # Check ReplicaSet status if deployment exists
        if [ -n "$DEPLOYMENT_NAME" ]; then
            RS_NAME=$(oc get replicaset -n openshift-operators -l app=$DEPLOYMENT_NAME --sort-by='.metadata.creationTimestamp' -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$RS_NAME" ]; then
                RS_READY=$(oc get replicaset $RS_NAME -n openshift-operators -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                RS_REPLICAS=$(oc get replicaset $RS_NAME -n openshift-operators -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
                echo "    ReplicaSet $RS_NAME: $RS_READY/$RS_REPLICAS ready"
            fi
        fi
        
        # Check CSV conditions for clues
        echo "    CSV conditions:"
        oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.conditions[*].type}{"\n"}' 2>/dev/null | while read -r cond; do
            if [ -n "$cond" ]; then
                cond_status=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath="{.status.conditions[?(@.type==\"$cond\")].status}" 2>/dev/null || echo "")
                cond_msg=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath="{.status.conditions[?(@.type==\"$cond\")].message}" 2>/dev/null || echo "")
                if [ "$cond_status" != "True" ] && [ -n "$cond_msg" ]; then
                    echo "      $cond: $cond_status - $cond_msg"
                fi
            fi
        done
        
        # Check recent events
        echo "    Recent events in openshift-operators namespace:"
        oc get events -n openshift-operators --field-selector involvedObject.name=$CSV_NAME --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -3 || echo "    No recent events found"
    fi
done

if [ "$OPERATOR_PODS_READY" = false ]; then
    echo ""
    echo "Warning: Operator pods are not ready after ${MAX_WAIT_PODS} seconds"
    echo ""
    echo "=== Diagnostic Information ==="
    echo ""
    echo "1. Operator pods status:"
    oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator 2>/dev/null || echo "  No operator pods found"
    echo ""
    
    echo "2. Operator deployment status:"
    oc get deployment -n openshift-operators -l name=trusted-artifact-signer-operator -o yaml 2>/dev/null | grep -A 10 "status:" || echo "  No deployment found"
    echo ""
    
    echo "3. ReplicaSet status:"
    oc get replicaset -n openshift-operators -l name=trusted-artifact-signer-operator 2>/dev/null || echo "  No replicasets found"
    echo ""
    
    echo "4. CSV status and conditions:"
    oc get csv $CSV_NAME -n openshift-operators -o yaml 2>/dev/null | grep -A 20 "status:" | head -30 || echo "  Could not retrieve CSV status"
    echo ""
    
    echo "5. Recent events related to operator:"
    oc get events -n openshift-operators --field-selector involvedObject.name=$CSV_NAME --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -10 || echo "  No recent events found"
    echo ""
    
    echo "6. All pods in openshift-operators namespace (for context):"
    oc get pods -n openshift-operators --no-headers 2>/dev/null | grep -i "trusted\|rhtas" || echo "  No RHTAS-related pods found"
    echo ""
    
    echo "=== Troubleshooting Commands ==="
    echo ""
    echo "To investigate further, run:"
    echo "  oc describe csv $CSV_NAME -n openshift-operators"
    echo "  oc get deployment -n openshift-operators -l name=trusted-artifact-signer-operator -o yaml"
    echo "  oc get events -n openshift-operators --sort-by='.lastTimestamp' | grep -i 'trusted\|rhtas' | tail -20"
    echo "  oc logs -n openshift-operators -l name=trusted-artifact-signer-operator --tail=50"
    echo ""
    echo "This may cause issues when deploying RHTAS components. Continuing anyway..."
fi

echo ""
echo "✓ RHTAS Operator installation completed"
echo "  CSV: $CSV_NAME"
echo "  Phase: $(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Unknown')"
echo "  CRDs: Installed"
echo "  Operator Pods: $(oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator --no-headers 2>/dev/null | wc -l || echo '0') running"
