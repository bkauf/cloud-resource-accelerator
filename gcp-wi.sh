#!/bin/bash

set -euo pipefail
set -x

PROJECT_ID=$(gcloud config get-value project)
PROVIDER_GCP=provider-anthos-gcp
GCP_SERVICE_ACCOUNT=resource-accelerator-gcp-sa
ROLE=roles/editor
KUBERNETES_SERVICE_ACCOUNT=resource-accelerator-gcp-sa-ksa
CONTROLLER_CONFIG_NAME=cra-config

REVISION=$(kubectl get providers.pkg.crossplane.io ${PROVIDER_GCP} -o jsonpath="{.status.currentRevision}")

set +e
gcloud iam service-accounts describe ${GCP_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com
STATUS="$?"
set -e
if [[ $STATUS -ne 0 ]]; then
  gcloud iam service-accounts create ${GCP_SERVICE_ACCOUNT}
fi

# Temporarily disable policy controller such that we can make changes in the crossplane-system ns
kubectl delete --ignore-not-found=true K8sAllowedResources block-workloads forbidden-namespaces
sleep 5

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${KUBERNETES_SERVICE_ACCOUNT}
  namespace: crossplane-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: crossplane:provider:${PROVIDER_GCP}:system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: crossplane:provider:${REVISION}:system
subjects:
- kind: ServiceAccount
  name: ${KUBERNETES_SERVICE_ACCOUNT}
  namespace: crossplane-system
EOF

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member "serviceAccount:${GCP_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role=roles/iam.serviceAccountUser \
  --project ${PROJECT_ID}

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member "serviceAccount:${GCP_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role ${ROLE} \
  --project ${PROJECT_ID}

gcloud iam service-accounts add-iam-policy-binding \
  ${GCP_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[crossplane-system/${KUBERNETES_SERVICE_ACCOUNT}]" \
  --role roles/iam.workloadIdentityUser \
  --project ${PROJECT_ID}

kubectl annotate serviceaccount -n crossplane-system ${KUBERNETES_SERVICE_ACCOUNT} \
  iam.gke.io/gcp-service-account=${GCP_SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com \
  --overwrite

kubectl patch ControllerConfig ${CONTROLLER_CONFIG_NAME} --type merge -p "{\"spec\": {\"serviceAccountName\": \"${KUBERNETES_SERVICE_ACCOUNT}\"}}"

cat <<EOF | kubectl apply -f -
apiVersion: gcp.gke.cloud.google.com/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  projectID: ${PROJECT_ID}
  credentials:
    source: InjectedIdentity
EOF
