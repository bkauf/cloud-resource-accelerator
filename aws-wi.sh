#!/bin/bash

set -euo pipefail
set -x

# These params can be changed by the user
KRM_CLUSTER_NAME=krmapihost-resource-accelerator
KRM_CLUSTER_LOCATION=us-central1
KRM_CLUSTER_PROJECT_ID=$(gcloud config get-value project)
AWS_ROLE_NAME=cloud-resource-accelerator-role
AWS_POLICY_NAME=cloud-resource-accelerator-policy
AWS_CLI_PROFILE=default

# These params MUST NOT be changed by the user
KRM_CLUSTER_FULL_NAME=krmapihost-${KRM_CLUSTER_NAME}
KUBERNETES_SERVICE_ACCOUNT=cloud-resource-accelerator-provider-aws
ISSUER_URL=https://container.googleapis.com/v1/projects/${KRM_CLUSTER_PROJECT_ID}/locations/${KRM_CLUSTER_LOCATION}/clusters/${KRM_CLUSTER_FULL_NAME}
ISSUER_HOSTPATH=${ISSUER_URL#"https://"}


# TODO: move this first part into the ACP repo
# Temporarily disable policy controller such that we can make changes in the crossplane-system ns
PROVIDER_AWS=provider-anthos-aws
REVISION=$(kubectl get providers.pkg.crossplane.io ${PROVIDER_AWS} -o jsonpath="{.status.currentRevision}")
CONTROLLER_CONFIG_NAME=cra-config
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
  name: crossplane:provider:${PROVIDER_AWS}:system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: crossplane:provider:${REVISION}:system
subjects:
- kind: ServiceAccount
  name: ${KUBERNETES_SERVICE_ACCOUNT}
  namespace: crossplane-system
EOF
kubectl patch ControllerConfig ${CONTROLLER_CONFIG_NAME} --type merge -p "{\"spec\": {\"serviceAccountName\": \"${KUBERNETES_SERVICE_ACCOUNT}\", \"env\": [{\"name\": \"AWS_WEB_IDENTITY_TOKEN_FILE\", \"value\": \"/var/run/secrets/kubernetes.io/serviceaccount/token\"}, {\"name\": \"AWS_ROLE_ARN\", \"value\": \"PLACEHOLDER\"}]}}"


# Create the AWS OIDC provider for the KRM cluster
#
# Unfortunately, creating the AWS OIDC provider has to be done by calling the
# AWS API directly; if we use the aws CLI it insists upon fetching the client ID
# URL and complains when it gets a 401 response. This is what we'd ideally do:
#
#    aws iam create-open-id-connect-provider \
#      --url "https://container.googleapis.com/v1/projects/${KRM_CLUSTER_PROJECT_ID}/locations/${KRM_CLUSTER_LOCATION}/clusters/${KRM_CLUSTER_FULL_NAME}" \
#      --thumbprint-list 08745487e891c19e3078c1f2a07e452950ef36f6 \
#      --client-id-list "https://container.googleapis.com/v1/projects/${KRM_CLUSTER_PROJECT_ID}/locations/${KRM_CLUSTER_LOCATION}/clusters/${KRM_CLUSTER_FULL_NAME}"
#
# But instead we use curl:
set +x
echo "Creating OIDC provider"
KEY=$(aws --profile ${AWS_CLI_PROFILE} configure get aws_access_key_id)
SECRET=$(aws --profile ${AWS_CLI_PROFILE} configure get aws_secret_access_key)
curl https://iam.amazonaws.com/ \
  --aws-sigv4 "aws:amz:us-east-1:iam" \
  --user "${KEY}:${SECRET}" \
  --data-urlencode "Action=CreateOpenIDConnectProvider" \
  --data-urlencode "Version=2010-05-08" \
  --data-urlencode "Url=${ISSUER_URL}" \
  --data-urlencode "ClientIDList.member.1=${ISSUER_URL}" \
  --data-urlencode "ThumbprintList.member.1=08745487e891c19e3078c1f2a07e452950ef36f6"
set -x
OIDC_PROVIDER_ARN=$(aws iam list-open-id-connect-providers  \
  | jq '.OpenIDConnectProviderList' \
  | jq ".[] | select(.Arn |  contains(\"${ISSUER_HOSTPATH}\"))"   \
  | jq  -r '.Arn')


# Create the AWS role and allow the KSA to assume it via OIDC federation
AWS_ROLE_ARN=$(aws iam list-roles --query 'Roles[?RoleName==`'${AWS_ROLE_NAME}'`].Arn' --output text)
if [[ -z "${AWS_ROLE_ARN}" ]]; then
  aws iam create-role --role-name ${AWS_ROLE_NAME} --assume-role-policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Effect\": \"Allow\",
      \"Principal\": {
        \"Federated\": \"${OIDC_PROVIDER_ARN}\"
      },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {
        \"StringEquals\": {
          \"${ISSUER_HOSTPATH}:sub\": \"system:serviceaccount:crossplane-system:${KUBERNETES_SERVICE_ACCOUNT}\"
        }
      }
    } ]
  }"
  AWS_ROLE_ARN=$(aws iam get-role --role-name ${AWS_ROLE_NAME} --query Role.Arn --output text)
fi


# Create the AWS policy and attach it to the role
AWS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`'${AWS_POLICY_NAME}'`].Arn' --output text)
if [[ -z "${AWS_POLICY_ARN}" ]]; then
  aws iam create-policy --policy-name $AWS_POLICY_NAME \
    --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "",
        "Effect": "Allow",
        "Action": [
          "ec2:CreateVpc",
          "ec2:DescribeVpcs",
          "ec2:CreateTags",
          "eks:CreateCluster"
        ],
        "Resource": "*"
      }
    ]
  }'
  AWS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`'${AWS_POLICY_NAME}'`].Arn' --output text)
fi
aws iam attach-role-policy --role-name ${AWS_ROLE_NAME} --policy-arn ${AWS_POLICY_ARN}
# TODO: remove this! Just for testing until we figure out the actual set of
# needed permissions above!
aws iam attach-role-policy --role-name ${AWS_ROLE_NAME} --policy-arn arn:aws:iam::aws:policy/AdministratorAccess


# Create the default ProviderConfig, specifying the AWS role ARN
cat <<EOF | kubectl apply -f -
apiVersion: aws.gke.cloud.google.com/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: WebIdentity
    webIdentity:
      roleARN: ${AWS_ROLE_ARN}
EOF
