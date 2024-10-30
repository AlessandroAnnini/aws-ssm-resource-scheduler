# 📘 AWS Resource Scheduling Scripts

Welcome to the **AWS Resource Scheduling Scripts** repository! This collection of scripts automates the scheduling of AWS resources using AWS Systems Manager State Manager. By automating resource management, you can optimize costs while ensuring your resources are available when needed.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](/LICENSE)

## 🎯 Features

- **Cost Optimization**: Automatically stop resources outside business hours
- **Flexible Scheduling**: Customizable schedules per weekday
- **Multiple Resource Support**: EC2, RDS, and EKS node groups
- **Easy Configuration**: Simple script parameters and customization
- **Robust Error Handling**: Comprehensive validation and error checks
- **Clean Uninstall**: Easy removal of all created AWS resources
- **Idempotent Execution**: Safe to run multiple times without unwanted side effects

## 🚀 Table of Contents

- [📘 AWS Resource Scheduling Scripts](#-aws-resource-scheduling-scripts)
  - [🎯 Features](#-features)
  - [🚀 Table of Contents](#-table-of-contents)
    - [Understanding Idempotency](#understanding-idempotency)
  - [🏃 Quick Start](#-quick-start)
  - [📚 Scripts Overview](#-scripts-overview)
  - [🔧 Installation and Prerequisites](#-installation-and-prerequisites)
    - [Required Tools](#required-tools)
    - [AWS Permissions Required](#aws-permissions-required)
  - [📅 Schedule Customization](#-schedule-customization)
    - [Time Zone Information](#time-zone-information)
    - [Customizing Working Hours](#customizing-working-hours)
    - [Resource-Specific Timing Considerations](#resource-specific-timing-considerations)
  - [🔍 Monitoring and Management](#-monitoring-and-management)
    - [Viewing Schedules](#viewing-schedules)
    - [Association Naming Convention](#association-naming-convention)
  - [🔒 Security and IAM](#-security-and-iam)
    - [Created Resources](#created-resources)
    - [IAM Policy Scoping](#iam-policy-scoping)
  - [🛠 Troubleshooting](#-troubleshooting)
    - [Common Issues](#common-issues)
    - [Viewing Logs](#viewing-logs)
  - [🛠 Additional Tools](#-additional-tools)
    - [List Associations Script](#list-associations-script)

### Understanding Idempotency

The scripts are designed to be idempotent, meaning you can run them multiple times safely without creating duplicate resources or causing unintended effects. Here's how it works:

1. **IAM Resources**:

   - Before creating a new policy/role, the script checks if it already exists
   - If found, it verifies and updates the existing resources instead of creating duplicates

2. **SSM Associations**:

   - Each association has a unique name based on action, resource, and day
   - The script checks for existing associations before creating new ones
   - If found, it updates the existing association with any new parameters

3. **Practical Benefits**:

   - Safe to re-run during troubleshooting
   - Can be used to update existing schedules
   - No need to clean up before modifying configurations
   - Prevents resource duplication and clutter
   - Supports infrastructure as code practices

4. **Example Scenarios**:
   - Running script multiple times with same parameters: No changes made
   - Running with different schedule times: Updates existing associations
   - Running with --delete flag: Removes all related resources regardless of how many times created

## 🏃 Quick Start

1. Clone the repository
2. Ensure AWS CLI and jq are installed
3. Run one of the scripts:

```bash
./schedule_ec2_start_stop.sh -p myprofile -r eu-central-1 -i ec2-instance-id
./schedule_rds_start_stop.sh -p myprofile -r eu-central-1 -i db-instance-id
./schedule_eks_scale.sh -p myprofile -r eu-central-1 -i k8s-cluster-name
```

## 📚 Scripts Overview

| Script                       | Purpose                 | Default Schedule                                          |
| ---------------------------- | ----------------------- | --------------------------------------------------------- |
| `schedule_ec2_start_stop.sh` | EC2 instance management | Start: 06:00 UTC (08:00 IT)<br>Stop: 16:00 UTC (18:00 IT) |
| `schedule_rds_start_stop.sh` | RDS instance management | Start: 06:00 UTC (08:00 IT)<br>Stop: 18:00 UTC (20:00 IT) |
| `schedule_eks_scale.sh`      | EKS node group scaling  | Scale Up: 08:00 UTC<br>Scale Down: 18:00 UTC              |

## 🔧 Installation and Prerequisites

### Required Tools

- AWS CLI v2
- jq (JSON processor)
- Bash shell

### AWS Permissions Required

- IAM role and policy creation
- Systems Manager State Manager access
- Resource-specific permissions (EC2, RDS, or EKS)

## 📅 Schedule Customization

### Time Zone Information

All schedules use UTC time. Consider your local timezone when setting schedules.

Here's a guide for common time zones during standard time (offsets may change during daylight saving time):

| Location     | UTC Offset | Local Business Hours | UTC Configuration          | Example Result                    |
| ------------ | ---------- | -------------------- | -------------------------- | --------------------------------- |
| Italy (CET)  | UTC+1      | 08:00-18:00 CET      | START_HOUR=7 STOP_HOUR=17  | Starts 08:00 CET, Stops 18:00 CET |
| UK (GMT)     | UTC+0      | 08:00-18:00 GMT      | START_HOUR=8 STOP_HOUR=18  | Starts 08:00 GMT, Stops 18:00 GMT |
| US East (ET) | UTC-5      | 08:00-18:00 ET       | START_HOUR=13 STOP_HOUR=23 | Starts 08:00 ET, Stops 18:00 ET   |
| US West (PT) | UTC-8      | 08:00-18:00 PT       | START_HOUR=16 STOP_HOUR=2  | Starts 08:00 PT, Stops 18:00 PT   |

⚠️ **Important Notes**:

- Always account for Daylight Saving Time (DST) changes when setting schedules
- When your local time is in DST, adjust the UTC hours accordingly
- Some regions like Italy (CET→CEST) shift +1 hour during DST
- Use tools like `date -u` to verify UTC time conversions

### Customizing Working Hours

1. **Locate the Schedule Variables**:
   Each script contains these variables near the top:

   ```bash
   # Schedule times (hour in UTC)
   START_HOUR=6    # 8 in Italy
   STOP_HOUR=16    # 18 in Italy   # For RDS: STOP_HOUR=18 (20 in Italy)
   ```

2. **Calculate Your UTC Hours**:

   - Determine your local business hours
   - Convert to UTC by subtracting your timezone offset
   - Example for EST (UTC-5):

     ```bash
     # For 9 AM - 5 PM EST
     START_HOUR=14  # 9 AM EST = 14:00 UTC
     STOP_HOUR=22   # 5 PM EST = 22:00 UTC
     ```

3. **Extending to Weekends**:
   Modify the DAYS array:

   ```bash
   # Default (weekdays only)
   DAYS=("MON" "TUE" "WED" "THU" "FRI")

   # Including weekends
   DAYS=("MON" "TUE" "WED" "THU" "FRI" "SAT" "SUN")
   ```

### Resource-Specific Timing Considerations

- **EC2 Instances**: Startup time: 1-3 minutes
- **RDS Instances**: Startup time: 3-10 minutes depending on size
- **EKS Node Groups**: Scale-up time: 5-10 minutes

## 🔍 Monitoring and Management

### Viewing Schedules

Use the included utility to list all associations:

```bash
./list_ssm_associations.sh -p myprofile -r eu-central-1 [-j|--json] [-m|--markdown]
```

### Association Naming Convention

- EC2: StartEC2Instance_i-xxxx_DAY / StopEC2Instance_i-xxxx_DAY
- RDS: StartRDSInstance_dbname_DAY / StopRDSInstance_dbname_DAY
- EKS: ScaleUpEKS_cluster_nodegroup_DAY / ScaleDownEKS_cluster_nodegroup_DAY

## 🔒 Security and IAM

### Created Resources

- IAM Roles: `{EC2|RDS|EKS}StartStopRole`
- IAM Policies: `{EC2|RDS|EKS}StartStopPolicy`
- SSM Associations: Multiple, one pair per day per resource

### IAM Policy Scoping

Policies are scoped to specific resources:

```json
{
  "Resource": "arn:aws:ec2:region:account:instance/i-xxxxx"
}
```

## 🛠 Troubleshooting

### Common Issues

1. **Permissions Errors**

   ```bash
   Error: User is not authorized to perform: iam:CreateRole
   ```

   Solution: Ensure AWS profile has sufficient IAM permissions

2. **SSM Association Conflicts**

   ```bash
   Error: Association with name already exists
   ```

   Solution: Use -D flag to delete existing associations first

3. **Resource Validation**

   ```bash
   Error: EC2 instance 'i-xxxxx' not found
   ```

   Solution: Verify resource ID and region

### Viewing Logs

- Check Systems Manager State Manager for association execution history
- Monitor CloudWatch Logs for automation execution details

## 🛠 Additional Tools

### List Associations Script

Use `list_ssm_associations.sh` to:

- View all scheduled resources
- Verify scheduling configuration
- Export schedules in JSON or markdown format

Example:

```bash
# View as formatted table
./list_ssm_associations.sh -p myprofile -r eu-central-1

# Export as JSON
./list_ssm_associations.sh -p myprofile -r eu-central-1 --json

# Export as markdown table
./list_ssm_associations.sh -p myprofile -r eu-central-1 --markdown
```

---

Made with ⌨️ by Alessandro Annini ([github.com/AlessandroAnnini](https://github.com/AlessandroAnnini))

**Note:** The scripts are provided as-is without warranty. Always test scheduling changes in a non-production environment first. Consider resource startup times when setting schedules to ensure availability when needed. Remember to adjust schedules for daylight saving time changes.
