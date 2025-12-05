#!/bin/bash

# ============================================================
# AMIT3253 CLOUD COMPUTING FOR BUSINESS - AUTO GRADER
# ============================================================

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Score Variables
TOTAL_SCORE=0
MAX_SCORE=100

# Helper function to print results
print_result() {
    local task_name=$1
    local marks=$2
    local max_marks=$3
    local status=$4
    local message=$5

    if [ "$status" == "PASS" ]; then
        echo -e "${GREEN}[PASS] (+${marks}/${max_marks}) ${task_name}: ${message}${NC}"
        TOTAL_SCORE=$((TOTAL_SCORE + marks))
    elif [ "$status" == "PARTIAL" ]; then
        echo -e "${YELLOW}[PARTIAL] (+${marks}/${max_marks}) ${task_name}: ${message}${NC}"
        TOTAL_SCORE=$((TOTAL_SCORE + marks))
    else
        echo -e "${RED}[FAIL] (0/${max_marks}) ${task_name}: ${message}${NC}"
    fi
}

echo -e "${BLUE}============================================================"
echo -e " STARTING ASSESSMENT GRADING"
echo -e " Student AWS Region: $(aws configure get region)"
echo -e "============================================================${NC}"

# ============================================================
# TASK 1: EC2 Web Server Deployment (25 Marks)
# ============================================================
echo -e "\n${BLUE}--- TASK 1: EC2 Web Server Deployment ---${NC}"

# 1. Check if ANY instance exists and is running (ignoring naming for a moment to find ID)
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].InstanceId" --output text | awk '{print $1}')

if [ -z "$INSTANCE_ID" ]; then
    print_result "EC2 Instance" 0 10 "FAIL" "No running instances found."
else
    # Check Name Tag
    INST_NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Name" --query "Tags[0].Value" --output text)
    print_result "EC2 Instance" 10 10 "PASS" "Instance found ($INSTANCE_ID). Name: $INST_NAME"
    
    # 2. Check Instance Type (t3.large)
    INST_TYPE=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].InstanceType" --output text)
    if [ "$INST_TYPE" == "t3.large" ]; then
        print_result "Instance Type" 5 5 "PASS" "Correct type: t3.large"
    else
        print_result "Instance Type" 0 5 "FAIL" "Incorrect type: $INST_TYPE (Required: t3.large)"
    fi

    # 3. Check User Data (Presence only, difficult to parse content via API)
    USER_DATA=$(aws ec2 describe-instance-attribute --instance-id $INSTANCE_ID --attribute userData --query "UserData.Value" --output text)
    if [ "$USER_DATA" != "None" ]; then
        print_result "User Data" 10 10 "PASS" "User Data script detected."
    else
        print_result "User Data" 0 10 "FAIL" "No User Data found."
    fi
fi

# ============================================================
# TASK 2: Launch Template & Auto Scaling Group (25 Marks)
# ============================================================
echo -e "\n${BLUE}--- TASK 2: Launch Template & ASG ---${NC}"

# 1. Check Launch Template (Name must start with lt-)
LT_NAME=$(aws ec2 describe-launch-templates --query "LaunchTemplates[?starts_with(LaunchTemplateName, 'lt-')].LaunchTemplateName" --output text | awk '{print $1}')

if [ ! -z "$LT_NAME" ]; then
    print_result "Launch Template" 5 5 "PASS" "Found template: $LT_NAME"
    
    # Check User Data in LT
    LT_ID=$(aws ec2 describe-launch-templates --launch-template-names $LT_NAME --query "LaunchTemplates[0].LaunchTemplateId" --output text)
    LT_USERDATA=$(aws ec2 describe-launch-template-versions --launch-template-id $LT_ID --versions "\$Latest" --query "LaunchTemplateVersions[0].LaunchTemplateData.UserData" --output text)
    
    if [ "$LT_USERDATA" != "None" ] && [ ! -z "$LT_USERDATA" ]; then
        print_result "LT User Data" 5 5 "PASS" "Script included in Template."
    else
        print_result "LT User Data" 0 5 "FAIL" "User Data missing in Template."
    fi

else
    print_result "Launch Template" 0 5 "FAIL" "No Launch Template starting with 'lt-' found."
    print_result "LT User Data" 0 5 "FAIL" "Skipped (No LT)."
fi

# 2. Check Auto Scaling Group (Name must start with asg-)
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, 'asg-')].AutoScalingGroupName" --output text | awk '{print $1}')

if [ ! -z "$ASG_NAME" ]; then
    print_result "ASG Exists" 5 5 "PASS" "Found ASG: $ASG_NAME"

    # 3. Check Scaling Config (Min=1, Max=3, Desired=1)
    # Using jq for parsing JSON output from AWS CLI
    ASG_CONFIG=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME)
    MIN_SIZE=$(echo $ASG_CONFIG | jq -r '.AutoScalingGroups[0].MinSize')
    MAX_SIZE=$(echo $ASG_CONFIG | jq -r '.AutoScalingGroups[0].MaxSize')
    DES_CAP=$(echo $ASG_CONFIG | jq -r '.AutoScalingGroups[0].DesiredCapacity')

    if [ "$MIN_SIZE" == "1" ] && [ "$MAX_SIZE" == "3" ] && [ "$DES_CAP" == "1" ]; then
        print_result "ASG Scaling" 5 5 "PASS" "Min:1, Max:3, Desired:1"
    else
        print_result "ASG Scaling" 0 5 "FAIL" "Incorrect Config (Found Min:$MIN_SIZE, Max:$MAX_SIZE, Desired:$DES_CAP)"
    fi

    # 4. Check Instances Launched via ASG
    ASG_INSTANCES=$(echo $ASG_CONFIG | jq -r '.AutoScalingGroups[0].Instances | length')
    if [ "$ASG_INSTANCES" -ge 1 ]; then
        print_result "ASG Instances" 5 5 "PASS" "ASG has $ASG_INSTANCES running instance(s)."
    else
        print_result "ASG Instances" 0 5 "FAIL" "ASG has 0 instances."
    fi

else
    print_result "ASG Exists" 0 5 "FAIL" "No ASG starting with 'asg-' found."
    print_result "ASG Scaling" 0 5 "FAIL" "Skipped."
    print_result "ASG Instances" 0 5 "FAIL" "Skipped."
fi

# ============================================================
# TASK 3: Load Balancer Integration (25 Marks)
# ============================================================
echo -e "\n${BLUE}--- TASK 3: Load Balancer ---${NC}"

# 1. Check ALB (Name starts with alb-)
ALB_ARN=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'alb-')].LoadBalancerArn" --output text | awk '{print $1}')
ALB_DNS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'alb-')].DNSName" --output text | awk '{print $1}')

if [ ! -z "$ALB_ARN" ]; then
    print_result "ALB Exists" 5 5 "PASS" "ALB Found."

    # 2. Check Listener (Port 80)
    LISTENER_CHECK=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query "Listeners[?Port==\`80\` && Protocol==\`HTTP\`].ListenerArn" --output text)
    if [ ! -z "$LISTENER_CHECK" ]; then
        print_result "ALB Listener" 5 5 "PASS" "HTTP Port 80 Listener configured."
    else
        print_result "ALB Listener" 0 5 "FAIL" "Missing HTTP Port 80 listener."
    fi

    # 3. Check Target Group
    TG_ARN=$(aws elbv2 describe-target-groups --query "TargetGroups[?starts_with(TargetGroupName, 'tg-')].TargetGroupArn" --output text | awk '{print $1}')
    
    if [ ! -z "$TG_ARN" ]; then
        # Check Health
        HEALTHY_COUNT=$(aws elbv2 describe-target-health --target-group-arn $TG_ARN --query "TargetHealthDescriptions[?TargetHealth.State=='healthy'] | length" --output text)
        
        if [ "$HEALTHY_COUNT" -ge 1 ]; then
            print_result "Target Group" 5 5 "PASS" "TG Found and $HEALTHY_COUNT instance(s) healthy."
            print_result "Health Checks" 5 5 "PASS" "Health checks passing."
        else
            print_result "Target Group" 3 5 "PARTIAL" "TG exists but NO healthy instances."
            print_result "Health Checks" 0 5 "FAIL" "Instances are unhealthy or not registered."
        fi
    else
        print_result "Target Group" 0 5 "FAIL" "No Target Group starting with 'tg-' found."
        print_result "Health Checks" 0 5 "FAIL" "Skipped."
    fi

    # 4. Check DNS Access (Curl)
    if [ ! -z "$ALB_DNS" ]; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://$ALB_DNS)
        if [ "$HTTP_CODE" == "200" ]; then
            print_result "ALB DNS Access" 5 5 "PASS" "Website accessible via ALB (HTTP 200)."
        else
            print_result "ALB DNS Access" 0 5 "FAIL" "Website not accessible (HTTP $HTTP_CODE)."
        fi
    else
        print_result "ALB DNS Access" 0 5 "FAIL" "Skipped (No DNS)."
    fi

else
    print_result "ALB Exists" 0 5 "FAIL" "No ALB starting with 'alb-' found."
    print_result "ALB Listener" 0 5 "FAIL" "Skipped."
    print_result "Target Group" 0 5 "FAIL" "Skipped."
    print_result "Health Checks" 0 5 "FAIL" "Skipped."
    print_result "ALB DNS Access" 0 5 "FAIL" "Skipped."
fi

# ============================================================
# TASK 4: S3 Static Website Hosting (25 Marks)
# ============================================================
echo -e "\n${BLUE}--- TASK 4: S3 Static Website ---${NC}"

# 1. Find Bucket (Name starts with s3-)
BUCKET_NAME=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 's3-')].Name" --output text | awk '{print $1}')

if [ ! -z "$BUCKET_NAME" ]; then
    print_result "S3 Bucket" 5 5 "PASS" "Bucket found: $BUCKET_NAME"

    # 2. Check Static Website Config
    WEBSITE_CONFIG=$(aws s3api get-bucket-website --bucket $BUCKET_NAME 2>/dev/null)
    if [ $? -eq 0 ]; then
        print_result "Static Hosting" 5 5 "PASS" "Static website hosting enabled."
    else
        print_result "Static Hosting" 0 5 "FAIL" "Static hosting NOT enabled."
    fi

    # 3. Check index.html existence
    INDEX_EXISTS=$(aws s3api head-object --bucket $BUCKET_NAME --key index.html 2>/dev/null)
    if [ $? -eq 0 ]; then
        print_result "index.html" 5 5 "PASS" "index.html uploaded."
    else
        print_result "index.html" 0 5 "FAIL" "index.html missing."
    fi

    # 4. Check Public Access (via Curl)
    # Construct endpoint (Simplified for us-east-1, learner lab default usually)
    REGION=$(aws configure get region)
    if [ "$REGION" == "us-east-1" ]; then
        S3_URL="http://${BUCKET_NAME}.s3-website-us-east-1.amazonaws.com"
    else
        S3_URL="http://${BUCKET_NAME}.s3-website-${REGION}.amazonaws.com"
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" $S3_URL)
    
    if [ "$HTTP_CODE" == "200" ]; then
        print_result "Public Access" 5 5 "PASS" "File accessible publicly."
        print_result "Website Verify" 5 5 "PASS" "Browser Verification Successful (HTTP 200)."
    elif [ "$HTTP_CODE" == "403" ]; then
        print_result "Public Access" 0 5 "FAIL" "Access Denied (HTTP 403). Check Bucket Policy/Block Public Access."
        print_result "Website Verify" 0 5 "FAIL" "Page not accessible."
    else
        print_result "Public Access" 0 5 "FAIL" "Error accessing site (HTTP $HTTP_CODE)."
        print_result "Website Verify" 0 5 "FAIL" "Page not accessible."
    fi

else
    print_result "S3 Bucket" 0 5 "FAIL" "No bucket starting with 's3-' found."
    print_result "Static Hosting" 0 5 "FAIL" "Skipped."
    print_result "index.html" 0 5 "FAIL" "Skipped."
    print_result "Public Access" 0 5 "FAIL" "Skipped."
    print_result "Website Verify" 0 5 "FAIL" "Skipped."
fi

echo -e "${BLUE}============================================================"
echo -e " FINAL CALCULATED SCORE: ${TOTAL_SCORE} / ${MAX_SCORE}"
echo -e " NOTE: Please verify screenshots for 'Student Name' validation."
echo -e "============================================================${NC}"
