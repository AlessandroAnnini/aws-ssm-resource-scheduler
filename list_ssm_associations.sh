#!/bin/bash

################################################################################
# Script: list_ssm_associations.sh
#
# Copyright (c) 2024 Alessandro Annini
# MIT License - See LICENSE file for details
# GitHub: https://github.com/AlessandroAnnini/aws-ssm-resource-scheduler
#
# Description:
#   Lists all AWS Systems Manager State Manager associations in the specified
#   AWS profile and region, outputting a table or JSON with association details.
#
# Prerequisites:
#   - AWS CLI installed and configured with appropriate permissions
#   - jq installed for JSON processing
#
# Usage:
#   ./list_ssm_associations.sh -p <aws_profile> -r <aws_region> [-j|--json]
#
# Parameters:
#   -p | --profile    AWS CLI profile to use
#   -r | --region     AWS region to operate in
#   -j | --json       Output in JSON format (optional, defaults to table format)
#   -m | --markdown   Output in Markdown table format (optional, defaults to table format)
#   -h | --help       Display this help message
################################################################################

# Exit on error, undefined vars, and pipe failures
set -euo pipefail

# Trap errors and print the line number where they occurred
trap 'echo "Error on line $LINENO"' ERR

#######################################
# Variables and Default Values
#######################################
AWS_PROFILE=""
AWS_REGION=""
OUTPUT_JSON=false
OUTPUT_MARKDOWN=false

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
# Print Help
#######################################
print_help() {
    echo "Usage: $0 -p <aws_profile> -r <aws_region> [-j|--json] [-m|--markdown]"
    echo
    echo "Parameters:"
    echo "  -p | --profile    AWS CLI profile to use"
    echo "  -r | --region     AWS region to operate in"
    echo "  -j | --json       Output in JSON format (optional)"
    echo "  -m | --markdown   Output in Markdown table format (optional)"
    echo "  -h | --help       Display this help message"
    echo
    echo "Example:"
    echo "  $0 -p myprofile -r eu-central-1"
    echo "  $0 -p myprofile -r eu-central-1 --json"
    echo "  $0 -p myprofile -r eu-central-1 --markdown"
    exit 1
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
# Parse Command-Line Arguments
#######################################
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
        -j|--json)
            OUTPUT_JSON=true
            shift # past argument
            ;;
        -m|--markdown)
            OUTPUT_MARKDOWN=true
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

#######################################
# Main Script Execution
#######################################
check_dependencies
validate_aws_profile "$AWS_PROFILE"
validate_aws_region "$AWS_PROFILE" "$AWS_REGION"

# Get all associations and format them
associations=$(aws ssm list-associations \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'Associations[].{
        "AssociationId": AssociationId,
        "AssociationName": AssociationName || Name,
        "DocumentName": Name,
        "ScheduleExpression": ScheduleExpression
    }' \
    --output json)

# Sort associations by AssociationName
sorted_associations=$(echo "$associations" | jq 'sort_by(.AssociationName)')

if [ "$OUTPUT_JSON" = true ]; then
    # Output JSON format
    echo "$sorted_associations" | jq '.'
elif [ "$OUTPUT_MARKDOWN" = true ]; then
    # Output markdown table format
    echo "# AWS SSM Associations"
    echo
    echo "| Association ID | Association Name | Document Name | Schedule Expression |"
    echo "|----------------|------------------|---------------|-------------------|"
    echo "$sorted_associations" | jq -r '.[] | "| \(.AssociationId) | \(.AssociationName) | \(.DocumentName) | \(.ScheduleExpression) |"'
else
    # Output table format
    echo "Association Details (sorted by Association Name):"
    echo "==============================================================================================================="
    printf "%-37s| %-45s| %-22s| %-22s\n" \
        "Association ID" "Association Name" "Document Name" "Schedule Expression"
    echo "==============================================================================================================="

    echo "$sorted_associations" | jq -r '.[] | "\(.AssociationId) | \(.AssociationName) | \(.DocumentName) | \(.ScheduleExpression)"' | \
    while IFS='|' read -r id name doc schedule; do
        # Trim whitespace from each field
        id=$(echo "$id" | xargs)
        name=$(echo "$name" | xargs)
        doc=$(echo "$doc" | xargs)
        schedule=$(echo "$schedule" | xargs)
        printf "%-37s| %-45s| %-22s| %-22s\n" \
            "$id" "$name" "$doc" "$schedule"
    done
    echo "==============================================================================================================="
fi
