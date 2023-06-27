#!/bin/bash

set -euo pipefail
set -x

# These params can be changed by the user
export KRM_CLUSTER_NAME=resource-accelerator
export KRM_CLUSTER_LOCATION=us-central1
export KRM_CLUSTER_PROJECT_ID=$(gcloud config get-value project)
export AWS_ROLE_NAME=cloud-resource-accelerator-role
export AWS_POLICY_NAME=cloud-resource-accelerator-policy
export AWS_CLI_PROFILE=default

# These params MUST NOT be changed by the user
export KRM_CLUSTER_FULL_NAME=krmapihost-${KRM_CLUSTER_NAME}
export KUBERNETES_SERVICE_ACCOUNT=cloud-resource-accelerator-provider-aws
export ISSUER_URL=https://container.googleapis.com/v1/projects/${KRM_CLUSTER_PROJECT_ID}/locations/${KRM_CLUSTER_LOCATION}/clusters/${KRM_CLUSTER_FULL_NAME}
export ISSUER_HOSTPATH=${ISSUER_URL#"https://"}

# Set the CA thumbprint of container.googleapis.com
CA_THUMBPRINT=7417784A15D3B764832ED29DB35FB6270756103A

# Register the OIDC provider with AWS.
aws iam create-open-id-connect-provider \
  --url ${ISSUER_URL} \
  --thumbprint-list ${CA_THUMBPRINT} \
  --client-id-list sts.amazonaws.com

export OIDC_PROVIDER_ARN=$(aws iam list-open-id-connect-providers  \
  | jq '.OpenIDConnectProviderList' \
  | jq ".[] | select(.Arn |  contains(\"${ISSUER_HOSTPATH}\"))"   \
  | jq  -r '.Arn')

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

aws iam create-policy --policy-name $AWS_POLICY_NAME \
  --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "eks:*",
        "iam:*",
        "kms:*"
        "autoscaling:*",
        "elasticloadbalancing:*",
      ],
      "Resource": "*"
    }
  ]
}'

export AWS_POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`'${AWS_POLICY_NAME}'`].Arn' --output text)

aws iam attach-role-policy --role-name ${AWS_ROLE_NAME} --policy-arn ${AWS_POLICY_ARN}

# Create the default AWS ProviderConfig, specifying the AWS role ARN
export AWS_ROLE_ARN=$(aws iam get-role --role-name ${AWS_ROLE_NAME} --query Role.Arn --output text)

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

