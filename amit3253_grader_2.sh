import boto3
import sys
import urllib.request
import urllib.error
import ssl
import time

# --- CONFIGURATION ---
# Ignore SSL certificate errors (common in some lab environments)
ssl_context = ssl._create_unverified_context()

# Global Score Keepers
TOTAL_MARKS = 0
SCORED_MARKS = 0

def print_header(title):
    print(f"\n{'='*60}")
    print(f" {title}")
    print(f"{'='*60}")

def grade_step(description, points, condition, details=""):
    global TOTAL_MARKS, SCORED_MARKS
    TOTAL_MARKS += points
    if condition:
        SCORED_MARKS += points
        print(f"[\u2713] PASS (+{points}): {description}")
    else:
        print(f"[X] FAIL (0/{points}): {description}")
        if details:
            print(f"    -> Issue: {details}")

def check_http_content(url, keyword):
    try:
        # Set a User-Agent to avoid being blocked by some server configs
        headers = {'User-Agent': 'Mozilla/5.0'}
        req = urllib.request.Request(url, headers=headers)
        
        # Timeout set to 3 seconds to avoid hanging
        with urllib.request.urlopen(req, timeout=3, context=ssl_context) as response:
            if response.status == 200:
                content = response.read().decode('utf-8')
                # Check for keyword (student name) case-insensitive
                if keyword.lower() in content.lower():
                    return True, "Content matched (Student Name found)"
                else:
                    # FIX: Returns False if name is missing
                    return False, "Page loads, but Student Name NOT found in HTML"
            else:
                return False, f"HTTP Status: {response.status}"
    except urllib.error.HTTPError as e:
        return False, f"HTTP Error: {e.code}"
    except urllib.error.URLError as e:
        return False, f"Connection Error: {e.reason}"
    except Exception as e:
        return False, str(e)

def main():
    print_header("AMIT3253 CLOUD COMPUTING - AUTO GRADER (V4)")
    
    session = boto3.session.Session()
    region = session.region_name
    print(f"Scanning Region: {region}")
    
    student_name_input = input("Enter Student Full Name (as used in resource naming): ").strip().lower()
    student_name_nospace = student_name_input.replace(" ", "")
    print(f"Looking for resources containing: '{student_name_nospace}' or parts of it...")

    ec2 = boto3.client('ec2')
    asg_client = boto3.client('autoscaling')
    elbv2 = boto3.client('elbv2')
    s3 = boto3.client('s3')

    # =========================================================
    # TASK 1: EC2 WEB SERVER DEPLOYMENT (25 MARKS)
    # =========================================================
    print_header("Task 1: EC2 Web Server Deployment (25%)")
    
    found_instance_id = None
    target_inst = None
    
    try:
        # 1. Check EC2 Instance Launched (10 Marks)
        instances = ec2.describe_instances(Filters=[{'Name': 'instance-state-name', 'Values': ['running']}])
        all_instances = [i for r in instances['Reservations'] for i in r['Instances']]
        
        if all_instances:
            # Pick primary candidate
            target_inst = all_instances[0] 
            # Refine: Look for specific Name Tag if possible
            for inst in all_instances:
                for tag in inst.get('Tags', []):
                    if tag['Key'] == 'Name' and student_name_nospace in tag['Value'].lower().replace(" ", ""):
                        target_inst = inst
                        break
        
        if target_inst:
            found_instance_id = target_inst['InstanceId']
            inst_name = "Unknown"
            for tag in target_inst.get('Tags', []):
                if tag['Key'] == 'Name': inst_name = tag['Value']
            
            grade_step("EC2 Instance Launched & Running", 10, True, f"ID: {found_instance_id} ({inst_name})")
            
            # 2. Check Instance Type (5 Marks)
            itype = target_inst['InstanceType']
            grade_step("Instance Type is t3.large", 5, itype == 't3.large', f"Found: {itype}")
            
            # 3. Check Security Group - Port 80 & 22 (5 Marks)
            sg_ids = [sg['GroupId'] for sg in target_inst.get('SecurityGroups', [])]
            has_ssh = False
            has_http = False
            
            if sg_ids:
                sgs = ec2.describe_security_groups(GroupIds=sg_ids)['SecurityGroups']
                for sg in sgs:
                    for perm in sg.get('IpPermissions', []):
                        from_port = perm.get('FromPort')
                        to_port = perm.get('ToPort')
                        ip_proto = perm.get('IpProtocol')
                        
                        # Check for "All Traffic" (-1)
                        if ip_proto == '-1':
                            has_ssh = True
                            has_http = True
                        # Check specific TCP ports
                        elif ip_proto == 'tcp' and from_port is not None and to_port is not None:
                            if from_port <= 22 and to_port >= 22: has_ssh = True
                            if from_port <= 80 and to_port >= 80: has_http = True
            
            grade_step("Security Group: Ports 22 & 80 Open", 5, (has_ssh and has_http), f"SSH:{has_ssh} HTTP:{has_http}")

            # 4. Check User Data via HTTP (5 Marks)
            public_ip = target_inst.get('PublicIpAddress')
            if public_ip:
                print(f"    Testing EC2 Public IP: http://{public_ip}")
                success, msg = check_http_content(f"http://{public_ip}", student_name_input)
                grade_step("Web Page Loads & Shows Name", 5, success, msg)
            else:
                grade_step("Web Page Loads & Shows Name", 5, False, "No Public IP assigned to instance")
            
        else:
            grade_step("EC2 Instance Launched & Running", 10, False, "No running instances found.")
            grade_step("Instance Type is t3.large", 5, False)
            grade_step("Security Group: Ports 22 & 80 Open", 5, False)
            grade_step("Web Page Loads & Shows Name", 5, False)

    except Exception as e:
        print(f"Error Task 1: {e}")

    # =========================================================
    # TASK 2: LAUNCH TEMPLATE & ASG (25 MARKS)
    # =========================================================
    print_header("Task 2: Launch Template & ASG (25%)")
    
    try:
        # 1. Launch Template Exists (5 Marks)
        lts = ec2.describe_launch_templates()['LaunchTemplates']
        target_lt = next((lt for lt in lts if "lt-" in lt['LaunchTemplateName']), None)
        lt_data = None
        
        if target_lt:
            grade_step("Launch Template Found (lt-*)", 5, True, f"Found: {target_lt['LaunchTemplateName']}")
            # Get Version Data
            lt_vers = ec2.describe_launch_template_versions(LaunchTemplateId=target_lt['LaunchTemplateId'], Versions=['$Latest'])
            lt_data = lt_vers['LaunchTemplateVersions'][0]['LaunchTemplateData']
        else:
            grade_step("Launch Template Found (lt-*)", 5, False)

        # 2. LT User Data (5 Marks)
        if lt_data and 'UserData' in lt_data:
             grade_step("LT includes User Data", 5, True)
        else:
             grade_step("LT includes User Data", 5, False)

        # 3. ASG Exists & Linked (5 Marks)
        asgs = asg_client.describe_auto_scaling_groups()['AutoScalingGroups']
        target_asg = next((a for a in asgs if "asg-" in a['AutoScalingGroupName']), None)
        
        if target_asg:
            lt_linked = False
            if 'LaunchTemplate' in target_asg and target_lt:
                if target_asg['LaunchTemplate']['LaunchTemplateName'] == target_lt['LaunchTemplateName']:
                    lt_linked = True
            
            grade_step("ASG Created & Linked", 5, lt_linked, f"ASG: {target_asg['AutoScalingGroupName']}")
            
            # 4. ASG Scaling Config (5 Marks)
            curr_min = target_asg['MinSize']
            curr_max = target_asg['MaxSize']
            curr_des = target_asg['DesiredCapacity']
            is_config_ok = (curr_min == 1 and curr_max == 3 and curr_des == 1)
            grade_step("Scaling Config (Min=1, Max=3, Des=1)", 5, is_config_ok, f"Found Min:{curr_min} Max:{curr_max} Des:{curr_des}")
            
            # 5. Instances Running in ASG (5 Marks)
            instance_count = len(target_asg['Instances'])
            grade_step("Instances Running via ASG", 5, instance_count >= 1, f"Count: {instance_count}")
            
        else:
            grade_step("ASG Created & Linked", 5, False)
            grade_step("Scaling Config (Min=1, Max=3, Des=1)", 5, False)
            grade_step("Instances Running via ASG", 5, False)

    except Exception as e:
        print(f"Error Task 2: {e}")

    # =========================================================
    # TASK 3: LOAD BALANCER INTEGRATION (25 MARKS)
    # =========================================================
    print_header("Task 3: Load Balancer (25%)")
    
    alb_dns = None
    target_tg_arn = None
    
    try:
        # 1. ALB Exists (5 Marks)
        albs = elbv2.describe_load_balancers()['LoadBalancers']
        target_alb = next((alb for alb in albs if "alb-" in alb['LoadBalancerName']), None)
        
        if target_alb:
            grade_step("ALB Created & Internet-Facing", 5, target_alb['Scheme'] == 'internet-facing')
            alb_dns = target_alb['DNSName']
            alb_arn = target_alb['LoadBalancerArn']
            
            # 2. ALB Listener (5 Marks)
            listeners = elbv2.describe_listeners(LoadBalancerArn=alb_arn)['Listeners']
            has_http_80 = any(l['Port'] == 80 and l['Protocol'] == 'HTTP' for l in listeners)
            grade_step("Listener Configured (HTTP:80)", 5, has_http_80)
            
        else:
            grade_step("ALB Created & Internet-Facing", 5, False)
            grade_step("Listener Configured (HTTP:80)", 5, False)

        # 3. Target Group Exists & Healthy (5 Marks)
        tgs = elbv2.describe_target_groups()['TargetGroups']
        target_tg = next((tg for tg in tgs if "tg-" in tg['TargetGroupName']), None)
        
        if target_tg:
            target_tg_arn = target_tg['TargetGroupArn']
            health = elbv2.describe_target_health(TargetGroupArn=target_tg_arn)
            healthy_count = sum(1 for t in health['TargetHealthDescriptions'] if t['TargetHealth']['State'] == 'healthy')
            
            grade_step("Target Group Exists", 5, True)
            
            # 4. Health Checks / Healthy Instances (5 Marks)
            grade_step("Targets Registered & Healthy", 5, healthy_count >= 1, f"Healthy Hosts: {healthy_count}")
        else:
            grade_step("Target Group Exists", 5, False)
            grade_step("Targets Registered & Healthy", 5, False)

        # 5. DNS Access (5 Marks)
        if alb_dns:
            print(f"    Testing ALB: http://{alb_dns}")
            success, msg = check_http_content(f"http://{alb_dns}", student_name_input)
            grade_step("ALB DNS Access & Name Verify", 5, success, msg)
        else:
            grade_step("ALB DNS Access & Name Verify", 5, False, "No ALB DNS found")

    except Exception as e:
        print(f"Error Task 3: {e}")

    # =========================================================
    # TASK 4: S3 STATIC WEBSITE HOSTING (25 MARKS)
    # =========================================================
    print_header("Task 4: S3 Static Website (25%)")
    
    target_bucket_name = None
    try:
        # 1. Bucket Exists (5 Marks)
        buckets = s3.list_buckets()['Buckets']
        target_bucket = next((b for b in buckets if "s3-" in b['Name']), None)
        
        if target_bucket:
            target_bucket_name = target_bucket['Name']
            grade_step("Bucket Created (s3-*)", 5, True, f"Bucket: {target_bucket_name}")
            
            # 2. Static Hosting Enabled (5 Marks)
            hosting_enabled = False
            try:
                s3.get_bucket_website(Bucket=target_bucket_name)
                hosting_enabled = True
            except:
                pass
            grade_step("Static Hosting Enabled", 5, hosting_enabled)
            
            # 3. index.html Uploaded (5 Marks)
            has_index = False
            try:
                s3.head_object(Bucket=target_bucket_name, Key='index.html')
                has_index = True
            except:
                pass
            grade_step("index.html Uploaded", 5, has_index)

            # 4. Public Access / Policy (5 Marks)
            has_policy = False
            try:
                pol = s3.get_bucket_policy(Bucket=target_bucket_name)
                if "Allow" in pol['Policy']: has_policy = True
            except:
                pass
            grade_step("Bucket Policy Configured", 5, has_policy)

            # 5. Website Verification (5 Marks)
            s3_url = f"http://{target_bucket_name}.s3-website-{region}.amazonaws.com"
            print(f"    Testing S3: {s3_url}")
            success, msg = check_http_content(s3_url, student_name_input)
            grade_step("Website Verified in Browser", 5, success, msg)
            
        else:
            grade_step("Bucket Created (s3-*)", 5, False)
            grade_step("Static Hosting Enabled", 5, False)
            grade_step("index.html Uploaded", 5, False)
            grade_step("Bucket Policy Configured", 5, False)
            grade_step("Website Verified in Browser", 5, False)

    except Exception as e:
        print(f"Error Task 4: {e}")

    # =========================================================
    # SUMMARY
    # =========================================================
    print_header("FINAL RESULT")
    print(f"TOTAL SCORE: {SCORED_MARKS} / 100")
    if SCORED_MARKS == 100:
        print("PERFECT SCORE! \u2B50")

if __name__ == "__main__":
    main()
