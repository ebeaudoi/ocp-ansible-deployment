#!/bin/bash

NAMESPACE=$1
HOSTNAME=$2
INSTANCEPATH="./instance/"$HOSTNAME
# OpenShift automatically creates a RoleBinding named view in the namespace.
ROLEBINDING_NAME="view"

echo "🌐 Checking if namespace '$NAMESPACE' exists..."

# Check if the namespace already exists
if oc get namespace "$NAMESPACE" > /dev/null 2>&1; then
    echo "❌ Namespace '$NAMESPACE' already exists. Skipping creation."
else
    echo "Creating namespace '$NAMESPACE'..."
    oc create namespace "$NAMESPACE"
fi

echo " Creating output folder "$INSTANCEPATH
mkdir -p $INSTANCEPATH

echo "♻️ Labeling the namespace with purpose=Keycloak..."
oc label namespace "$NAMESPACE" purpose=Keycloak --overwrite
echo "♻️ Annotating the namespace..."
oc annotate namespace "$NAMESPACE" openshift.io/description="Namespace to host Keycloak services" --overwrite

echo "♻️ Assigning 'view' role to authenticated users on namespace '$NAMESPACE'..."
# Allow all authenticated users to view resources (safe for service discovery)
oc adm policy add-role-to-group view system:authenticated -n "$NAMESPACE" 2>/dev/null || true

oc adm policy add-scc-to-user anyuid -z default -n "$NAMESPACE"

echo "♻️ Labeling the 'view' rolebinding with purpose=Keycloak..."
# Apply label to the RoleBinding
oc label rolebinding "$ROLEBINDING_NAME" purpose=Keycloak -n "$NAMESPACE" --overwrite

echo "Displaying rolebindings in namespace '$NAMESPACE'..."
oc get rolebindings -n "$NAMESPACE"

echo "Displaying details of the 'view' rolebinding..."
oc describe rolebinding "$ROLEBINDING_NAME" -n "$NAMESPACE"

echo "Namespace '$NAMESPACE' setup complete!"

oc project "$NAMESPACE"

echo "♻️ Seeting files to $INSTANCEPATH for the server $HOSTNAME..."
cp -f ./postgres/keycloak-postgres.yaml $INSTANCEPATH/keycloak-postgres.yaml
cp -f ./keycloak-operator/rhbk-operator-subscription.yaml $INSTANCEPATH/rhbk-operator-subscription.yaml
cp -f ./keycloak-operator/keycloak.yaml $INSTANCEPATH/keycloak.yaml

sed -i "s|<NAMESPACE>|$NAMESPACE|g" $INSTANCEPATH/keycloak-postgres.yaml
sed -i "s|<NAMESPACE>|$NAMESPACE|g" $INSTANCEPATH/rhbk-operator-subscription.yaml
sed -i "s|<NAMESPACE>|$NAMESPACE|g" $INSTANCEPATH/keycloak.yaml
sed -i "s|<HOSTNAME>|$HOSTNAME|g" $INSTANCEPATH/keycloak.yaml

