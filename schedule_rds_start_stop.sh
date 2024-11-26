#!/bin/bash

################################################################################
# Script: schedule_rds_start_stop.sh
#
# Copyright (c) 2024 Alessandro Annini
# GPL-3.0 license - See LICENSE file for details
# GitHub: https://github.com/AlessandroAnnini/aws-ssm-resource-scheduler
#
# Description:
#   Automates the scheduling of an Amazon RDS instance to start and stop using
#   AWS Systems Manager State Manager. The instance will remain stopped except
#   from Monday to Friday during business hours.
#
#   When run with the -D or --delete parameter, the script removes all the
#   created associations and IAM resources.
#
# Prerequisites:
#   - AWS CLI installed and configured with appropriate permissions.
#   - jq installed for JSON processing.
#
# Usage:
#   ./schedule_rds_start_stop.sh -p <aws_profile> -r <aws_region> -i <instance_id>
#   ./schedule_rds_start_stop.sh -D -p <aws_profile> -r <aws_region> -i <instance_id>
#
# Parameters:
#   -p | --profile      AWS CLI profile to use
#   -r | --region       AWS region to operate in
#   -i | --instance-id  RDS instance identifier to manage
#   -D | --delete       Delete the created associations and IAM resources
#   -h | --help         Display this help message
#
################################################################################

# Exit on error, undefined vars, and pipe failures
set -euo pipefail

# Trap errors and print the line number where they occurred
trap 'echo "Error on line $LINENO"' ERR

#######################################
# Variables and Default Values
#######################################

# Default values (will be overridden by command-line arguments)
AWS_PROFILE=""
AWS_REGION=""
INSTANCE_ID=""
DELETE_MODE=false

# IAM Policy and Role names
POLICY_NAME="RDSStartStopPolicy"
ROLE_NAME="RDSStartStopRole"

# State Manager Association names (we'll append the instance ID and day to the name)
STOP_ASSOCIATION_NAME_PREFIX="StopRDSInstance"
START_ASSOCIATION_NAME_PREFIX="StartRDSInstance"

# Schedule times (hour in UTC)
START_HOUR=6    # 8 in Italy
STOP_HOUR=18    # 20 in Italy

# Days of the week (AWS uses SUN-SAT)
DAYS=("MON" "TUE" "WED" "THU" "FRI")

#######################################
# Check Dependencies
#######################################
check_dependencies() {
    local missing_deps=()

    if ! command -v aws >/dev/null 2>&1; then
        missing_deps+=("aws cli")
    fi

    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

#######################################
# Validate AWS Profile
#######################################
validate_aws_profile() {
    local profile=$1
    if ! aws configure list-profiles 2>/dev/null | grep -q "^${profile}$"; then
        echo "Error: AWS profile '$profile' does not exist"
        exit 1
    fi
}

#######################################
# Validate AWS Region
#######################################
validate_aws_region() {
    local profile=$1
    local region=$2
    if ! aws ec2 describe-regions --profile "$profile" --query 'Regions[].RegionName' --output text 2>/dev/null | grep -q "\b${region}\b"; then
        echo "Error: Invalid AWS region '$region'"
        exit 1
    fi
}

#######################################
# Validate RDS Instance
#######################################
validate_rds_instance() {
    local profile=$1
    local region=$2
    local db_instance=$3

    if ! aws rds describe-db-instances \
        --profile "$profile" \
        --region "$region" \
        --db-instance-identifier "$db_instance" >/dev/null 2>&1; then
        echo "Error: RDS instance '$db_instance' not found"
        exit 1
    fi
}

#######################################
# Functions
#######################################

print_help() {
  echo "Usage: $0 -p <aws_profile> -r <aws_region> -i <instance_id>"
  echo "       $0 -D -p <aws_profile> -r <aws_region> -i <instance_id>"
  echo
  echo "Parameters:"
  echo "  -p | --profile      AWS CLI profile to use"
  echo "  -r | --region       AWS region to operate in"
  echo "  -i | --instance-id  RDS instance identifier to manage"
  echo "  -D | --delete       Delete the created associations and IAM resources"
  echo "  -h | --help         Display this help message"
  echo
  echo "Examples:"
  echo "  $0 -p myprofile -r us-east-1 -i my-rds-instance-id"
  echo "  $0 -D -p myprofile -r us-east-1 -i my-rds-instance-id"
  exit 1
}

# Function to create or delete an IAM policy
manage_iam_policy() {
  local action=$1  # create or delete
  local policy_name=$2
  local policy_document=$3

  if [ "$action" == "create" ]; then
    echo "Creating IAM policy: $policy_name" >&2
    aws iam create-policy \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --policy-name "$policy_name" \
      --policy-document "file://$policy_document" \
      --query 'Policy.Arn' --output text
  elif [ "$action" == "delete" ]; then
    echo "Deleting IAM policy: $policy_name"
    aws iam delete-policy \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --policy-arn "$POLICY_ARN"
  fi
}

# Function to create or delete an IAM role
manage_iam_role() {
  local action=$1  # create or delete
  local role_name=$2
  local assume_role_policy_document=$3
  local policy_arn=$4

  if [ "$action" == "create" ]; then
    echo "Creating IAM role: $role_name"
    aws iam create-role \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --role-name "$role_name" \
      --assume-role-policy-document "file://$assume_role_policy_document"

    echo "Attaching policy $POLICY_NAME to role $ROLE_NAME"
    aws iam attach-role-policy \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --role-name "$role_name" \
      --policy-arn "$policy_arn"
  elif [ "$action" == "delete" ]; then
    echo "Detaching policy $POLICY_NAME from role $ROLE_NAME"
    aws iam detach-role-policy \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --role-name "$role_name" \
      --policy-arn "$policy_arn"

    echo "Deleting IAM role: $role_name"
    aws iam delete-role \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --role-name "$role_name"
  fi
}

# Function to create, update, or delete a State Manager association
manage_association() {
  local action=$1  # create, update, delete
  local association_name=$2
  local document_name=$3
  local schedule_expression=$4
  local parameters=$5
  local association_id=$6  # Added association_id parameter

  if [ "$action" == "delete" ]; then
    echo "Deleting association $association_name..."
    if [ -n "$association_id" ] && [ "$association_id" != "None" ]; then
      aws ssm delete-association \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --association-id "$association_id" \
        || echo "Association $association_name not found or already deleted."
    else
      echo "Association ID for $association_name not found."
    fi
  else
    echo "Checking if association $association_name exists..."
    association_id=$(aws ssm list-associations \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --association-name "$association_name" \
      --query 'Associations[0].AssociationId' \
      --output text 2>/dev/null || true)

    if [ -n "$association_id" ] && [ "$association_id" != "None" ]; then
      if [ "$action" == "update" ]; then
        echo "Association $association_name exists. Updating association."
        aws ssm update-association \
          --profile "$AWS_PROFILE" \
          --region "$AWS_REGION" \
          --association-id "$association_id" \
          --name "$document_name" \
          --schedule-expression "$schedule_expression" \
          --parameters "$parameters" \
          --apply-only-at-cron-interval
      fi
    else
      if [ "$action" == "create" ]; then
        echo "Association $association_name does not exist. Creating new association."
        aws ssm create-association \
          --profile "$AWS_PROFILE" \
          --region "$AWS_REGION" \
          --name "$document_name" \
          --association-name "$association_name" \
          --schedule-expression "$schedule_expression" \
          --parameters "$parameters" \
          --apply-only-at-cron-interval
      fi
    fi
    echo "Association $association_name processed."
  fi
}

#######################################
# Parse Command-Line Arguments
#######################################

if [ $# -eq 0 ]; then
  print_help
fi

while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
    -p|--profile)
      AWS_PROFILE="$2"
      shift # past argument
      shift # past value
      ;;
    -r|--region)
      AWS_REGION="$2"
      shift
      shift
      ;;
    -i|--instance-id)
      INSTANCE_ID="$2"
      shift
      shift
      ;;
    -D|--delete)
      DELETE_MODE=true
      shift # past argument
      ;;
    -h|--help)
      print_help
      ;;
    *)
      echo "Unknown option: $1"
      print_help
      ;;
  esac
done

#######################################
# Validate Required Parameters
#######################################

if [ -z "$AWS_PROFILE" ]; then
  echo "Error: AWS CLI profile not specified. Use -p or --profile to set it."
  exit 1
fi

if [ -z "$AWS_REGION" ]; then
  echo "Error: AWS region not specified. Use -r or --region to set it."
  exit 1
fi

if [ -z "$INSTANCE_ID" ]; then
  echo "Error: RDS instance identifier not specified. Use -i or --instance-id to set it."
  exit 1
fi

# update POLICY_NAME adding the instance ID
POLICY_NAME="${POLICY_NAME}_${INSTANCE_ID}"
# update ROLE_NAME adding the instance ID
ROLE_NAME="${ROLE_NAME}_${INSTANCE_ID}"

#######################################
# Main Script Execution
#######################################

check_dependencies

validate_aws_profile "$AWS_PROFILE"
validate_aws_region "$AWS_PROFILE" "$AWS_REGION"
validate_rds_instance "$AWS_PROFILE" "$AWS_REGION" "$INSTANCE_ID"

echo "Starting RDS start/stop scheduling script..."


# Build the IAM policy ARN
POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text):policy/$POLICY_NAME"

if [ "$DELETE_MODE" = true ]; then
  #######################################INSTANCE_ID

    # Association names including INSTANCE_ID
    START_ASSOCIATION_NAME="${START_ASSOCIATION_NAME_PREFIX}_${INSTANCE_ID}_${DAY}"
    STOP_ASSOCIATION_NAME="${STOP_ASSOCIATION_NAME_PREFIX}_${INSTANCE_ID}_${DAY}"

    # Delete Start Association
    echo "Deleting automatic start association on $DAY..."
    # Get the association ID
    association_id=$(aws ssm list-associations \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --association-name "$START_ASSOCIATION_NAME" \
      --query 'Associations[0].AssociationId' \
      --output text 2>/dev/null || true)

    if [ -n "$association_id" ] && [ "$association_id" != "None" ]; then
      manage_association "delete" "$START_ASSOCIATION_NAME" "" "" "" "$association_id"
    else
      echo "Association $START_ASSOCIATION_NAME not found."
    fi

    # Delete Stop Association
    echo "Deleting automatic stop association on $DAY..."
    # Get the association ID
    association_id=$(aws ssm list-associations \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --association-name "$STOP_ASSOCIATION_NAME" \
      --query 'Associations[0].AssociationId' \
      --output text 2>/dev/null || true)

    if [ -n "$association_id" ] && [ "$association_id" != "None" ]; then
      manage_association "delete" "$STOP_ASSOCIATION_NAME" "" "" "" "$association_id"
    else
      echo "Association $STOP_ASSOCIATION_NAME not found."
    fi

  # Delete IAM role
  echo "Deleting IAM role and policy..."
  ROLE_EXISTS=$(aws iam get-role \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --role-name "$ROLE_NAME" \
    --query 'Role.RoleName' \
    --output text 2>/dev/null || true)

  if [ -n "$ROLE_EXISTS" ] && [ "$ROLE_EXISTS" != "None" ]; then
    manage_iam_role "delete" "$ROLE_NAME" "" "$POLICY_ARN"
  else
    echo "Role $ROLE_NAME does not exist."
  fi

  # Delete IAM policy
  POLICY_EXISTS=$(aws iam list-policies \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query "Policies[?PolicyName=='$POLICY_NAME'].PolicyName" \
    --output text)

  if [ -n "$POLICY_EXISTS" ] && [ "$POLICY_EXISTS" != "None" ]; then
    manage_iam_policy "delete" "$POLICY_NAME" ""
  else
    echo "Policy $POLICY_NAME does not exist."
  fi

  echo "Deletion of RDS start/stop scheduling resources complete."
  exit 0
fi

#######################################
# Regular Mode (Create/Update)
#######################################

#######################################
# Step 1: Configure an AWS Identity and Access Management (IAM) policy for State Manager.
#######################################

# Create IAM policy document
POLICY_DOCUMENT_FILE="policy-document.json"
cat > "$POLICY_DOCUMENT_FILE" << EoF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBInstances",
        "rds:StartDBInstance",
        "rds:StopDBInstance",
        "rds:RebootDBInstance"
      ],
      "Resource": "arn:aws:rds:$AWS_REGION:*:db:$INSTANCE_ID"
    }
  ]
}
EoF

# Check if policy already exists
POLICY_ARN=$(aws iam list-policies \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" \
  --output text)

if [ -z "$POLICY_ARN" ] || [ "$POLICY_ARN" == "None" ]; then
  POLICY_ARN=$(manage_iam_policy "create" "$POLICY_NAME" "$POLICY_DOCUMENT_FILE")
  echo "Policy created with ARN: $POLICY_ARN"
else
  echo "Policy $POLICY_NAME already exists with ARN: $POLICY_ARN"
fi

# Clean up policy document file
rm "$POLICY_DOCUMENT_FILE"

#######################################
# Step 2: Create an IAM role for the new policy.
#######################################

# Create IAM role trust policy document
TRUST_POLICY_DOCUMENT_FILE="trust-policy.json"
cat > "$TRUST_POLICY_DOCUMENT_FILE" << EoF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ssm.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EoF

# Check if role already exists
ROLE_EXISTS=$(aws iam get-role \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --role-name "$ROLE_NAME" \
  --query 'Role.RoleName' \
  --output text 2>/dev/null || true)

if [ -z "$ROLE_EXISTS" ] || [ "$ROLE_EXISTS" == "None" ]; then
  manage_iam_role "create" "$ROLE_NAME" "$TRUST_POLICY_DOCUMENT_FILE" "$POLICY_ARN"
else
  echo "Role $ROLE_NAME already exists."

  #######################################
  # Step 3: Update the trust relationship of the role so Systems Manager can use it.
  #######################################

  # Ensure the policy is attached
  ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --role-name "$ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyName" \
    --output text)

  if [ -z "$ATTACHED_POLICIES" ] || [ "$ATTACHED_POLICIES" == "None" ]; then
    echo "Attaching policy $POLICY_NAME to role $ROLE_NAME"
    aws iam attach-role-policy \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --role-name "$ROLE_NAME" \
      --policy-arn "$POLICY_ARN"
  else
    echo "Policy $POLICY_NAME is already attached to role $ROLE_NAME"
  fi
fi

# Clean up trust policy document file
rm "$TRUST_POLICY_DOCUMENT_FILE"

# Get the ARN of the IAM role
ASSUME_ROLE_ARN=$(aws iam get-role \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --role-name "$ROLE_NAME" \
  --query 'Role.Arn' \
  --output text)

echo "Using IAM Role ARN: $ASSUME_ROLE_ARN"

#######################################
# Steps 4 & 5: Set up the automatic stop and start with State Manager.
#######################################

# Parameters for the associations
PARAMETERS="{\"InstanceId\":[\"$INSTANCE_ID\"],\"AutomationAssumeRole\":[\"$ASSUME_ROLE_ARN\"]}"

# Loop over each day to create start and stop associations
for DAY in "${DAYS[@]}"; do
  echo "Processing associations for $DAY..."

  # Association names including INSTANCE_ID
  START_ASSOCIATION_NAME="${START_ASSOCIATION_NAME_PREFIX}_${INSTANCE_ID}_${DAY}"
  STOP_ASSOCIATION_NAME="${STOP_ASSOCIATION_NAME_PREFIX}_${INSTANCE_ID}_${DAY}"

  # Schedule expressions
  START_SCHEDULE="cron(0 $START_HOUR ? * $DAY *)"
  STOP_SCHEDULE="cron(0 $STOP_HOUR ? * $DAY *)"

  # Create or Update Start Association
  echo "Setting up automatic start on $DAY with State Manager..."
  manage_association "create" "$START_ASSOCIATION_NAME" "AWS-StartRdsInstance" "$START_SCHEDULE" "$PARAMETERS" ""

  # Create or Update Stop Association
  echo "Setting up automatic stop on $DAY with State Manager..."
  manage_association "create" "$STOP_ASSOCIATION_NAME" "AWS-StopRdsInstance" "$STOP_SCHEDULE" "$PARAMETERS" ""

done

echo "RDS start/stop scheduling setup complete."
