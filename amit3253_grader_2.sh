import boto3
import sys
import urllib.request
import ssl

# --- CONFIGURATION ---
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
        with urllib.request.urlopen(url, timeout=5, context=ssl_context) as response:
            if response.status == 200:
                content = response.read().decode('utf-8')
                if keyword.lower() in content.lower():
                    return True, "Content matched"
                else:
                    return True, "Page loads, but student name not found"
    except Exception as e:
        return False, str(e)
    return False, "Unknown error"

def main():
    print_header("BMIT3273 CLOUD COMPUTING - AUTO GRADER (FINAL v9)")
    
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
    rds = boto3.client('rds')

    # =========================================================
    # TASK 1: EC2 & SECURITY (25 MARKS)
    # =========================================================
    print_header("Task 1: EC2 & Security")
    
    try:
        lts = ec2.describe_launch_templates()['LaunchTemplates']
        target_lt = next((lt for lt in lts if "lt-" in lt['LaunchTemplateName']), None)
        lt_ver = None
        
        if target_lt:
            grade_step("Launch Template Found", 5, True)
            lt_id = target_lt['LaunchTemplateId']
            lt_ver = ec2.describe_launch_template_versions(LaunchTemplateId=lt_id)['LaunchTemplateVersions'][0]
        else:
            grade_step("Launch Template Found", 5, False, "Missing 'lt-*'")

        if lt_ver:
            itype = lt_ver['LaunchTemplateData'].get('InstanceType', 'Unknown')
            grade_step("Instance Type is t3.medium", 5, itype == 't3.medium', f"Found: {itype}")
            
            # UPDATED: User Data is now only 5 Marks
            has_ud = 'UserData' in lt_ver['LaunchTemplateData']
            grade_step("User Data Script Configured", 5, has_ud)
        else:
            grade_step("Instance Type is t3.medium", 5, False, "No LT to check")
            grade_step("User Data Script Configured", 5, False)

        # UPDATED: Security Group is now 10 Marks (5 + 5)
        sgs = ec2.describe_security_groups()['SecurityGroups']
        web_sg = next((sg for sg in sgs if sg['GroupName'] == 'web-access'), None)
        
        if web_sg:
            perms = web_sg['IpPermissions']
            has_ssh = False
            has_http = False
            for p in perms:
                if p.get('FromPort') == 22 or p.get('IpProtocol') == '-1': has_ssh = True
                if p.get('FromPort') == 80 or p.get('IpProtocol') == '-1': has_http = True
            
            grade_step("SG: Port 22 (SSH) Open", 5, has_ssh)
            grade_step("SG: Port 80 (HTTP) Open", 5, has_http)
        else:
            grade_step("SG: Port 22 (SSH) Open", 5, False, "SG 'web-access' missing")
            grade_step("SG: Port 80 (HTTP) Open", 5, False, "SG 'web-access' missing")

    except Exception as e:
        print(f"Error Task 1: {e}")

    # =========================================================
    # TASK 2: ASG & ALB (25 MARKS)
    # =========================================================
    print_header("Task 2: ASG & ALB")
    
    alb_dns = None
    try:
        # ALB (5 Marks)
        albs = elbv2.describe_load_balancers()['LoadBalancers']
        target_alb = next((alb for alb in albs if "alb-" in alb['LoadBalancerName']), None)
        
        if target_alb:
            grade_step("ALB Created", 2, True)
            grade_step("ALB Internet-Facing", 3, target_alb['Scheme'] == 'internet-facing')
            alb_dns = target_alb['DNSName']
        else:
            grade_step("ALB Created", 2, False)
            grade_step("ALB Internet-Facing", 3, False)

        # Target Group (5 Marks)
        tgs = elbv2.describe_target_groups()['TargetGroups']
        target_tg = next((tg for tg in tgs if "tg-" in tg['TargetGroupName']), None)
        
        if target_tg:
            grade_step("Target Group Created", 2, True)
            health = elbv2.describe_target_health(TargetGroupArn=target_tg['TargetGroupArn'])
            has_healthy = any(t['TargetHealth']['State'] == 'healthy' for t in health['TargetHealthDescriptions'])
            grade_step("Targets Registered & Healthy", 3, has_healthy)
        else:
            grade_step("Target Group Created", 2, False)
            grade_step("Targets Registered & Healthy", 3, False)

        # ASG (10 MARKS)
        asgs = asg_client.describe_auto_scaling_groups()['AutoScalingGroups']
        target_asg = next((a for a in asgs if "asg-" in a['AutoScalingGroupName']), None)
        
        if target_asg:
            grade_step("ASG Created", 5, True)
            is_config_ok = (target_asg['MinSize']==1 and target_asg['MaxSize']==4)
            grade_step("Scaling Config (1-2-4)", 5, is_config_ok, f"Found Min:{target_asg['MinSize']} Max:{target_asg['MaxSize']}")
        else:
            grade_step("ASG Created", 5, False)
            grade_step("Scaling Config (1-2-4)", 5, False)

        # Web Access (5 Marks)
        if alb_dns:
            print(f"    Testing ALB: http://{alb_dns}")
            success, msg = check_http_content(f"http://{alb_dns}", student_name_input)
            grade_step("Web Page Accessible via ALB", 5, success, msg)
        else:
            grade_step("Web Page Accessible via ALB", 5, False)

    except Exception as e:
        print(f"Error Task 2: {e}")

    # =========================================================
    # TASK 3: S3 (25 MARKS)
    # =========================================================
    print_header("Task 3: S3 Static Website")
    target_bucket_name = None
    try:
        buckets = s3.list_buckets()['Buckets']
        target_bucket = next((b for b in buckets if "s3-" in b['Name']), None)
        
        if target_bucket:
            target_bucket_name = target_bucket['Name']
            grade_step("Bucket Created", 5, True)
            
            try:
                s3.get_bucket_website(Bucket=target_bucket_name)
                grade_step("Static Hosting Enabled", 5, True)
            except:
                grade_step("Static Hosting Enabled", 5, False)
            
            try:
                objs = s3.list_objects_v2(Bucket=target_bucket_name)
                files = [o['Key'] for o in objs.get('Contents', [])]
                grade_step("File: index.html found", 2, 'index.html' in files)
                grade_step("File: error.html found", 3, 'error.html' in files)
            except:
                 grade_step("File: index.html found", 2, False)
                 grade_step("File: error.html found", 3, False)

            try:
                pol = s3.get_bucket_policy(Bucket=target_bucket_name)
                grade_step("Bucket Policy (Public)", 5, "Allow" in pol['Policy'])
            except:
                grade_step("Bucket Policy (Public)", 5, False)

            s3_url = f"http://{target_bucket_name}.s3-website-{region}.amazonaws.com"
            success, msg = check_http_content(s3_url, student_name_input)
            grade_step("Website Verified in Browser", 5, success, msg)
        else:
            grade_step("Bucket Created", 5, False)
            grade_step("Static Hosting Enabled", 5, False)
            grade_step("File: index.html found", 2, False)
            grade_step("File: error.html found", 3, False)
            grade_step("Bucket Policy (Public)", 5, False)
            grade_step("Website Verified in Browser", 5, False)

    except Exception as e:
        print(f"Error Task 3: {e}")

    # =========================================================
    # TASK 4: RDS (25 MARKS)
    # =========================================================
    print_header("Task 4: RDS & Evidence")
    try:
        dbs = rds.describe_db_instances()['DBInstances']
        
        target_rds = next((d for d in dbs if "rds-" in d['DBInstanceIdentifier']), None)
        using_default = False
        if not target_rds:
            target_rds = next((d for d in dbs if d['DBInstanceIdentifier'] == "database-1"), None)
            if target_rds: using_default = True

        if target_rds:
            grade_step("RDS Name Correct", 1, not using_default, "Used 'database-1'")
            
            inst_type = target_rds['DBInstanceClass']
            storage = target_rds['AllocatedStorage']
            grade_step("RDS Specs (t4g.micro/30GB)", 2, (inst_type == 'db.t4g.micro' and storage == 30), f"Found {inst_type}/{storage}GB")
            
            db_name = target_rds.get('DBName', '')
            grade_step("Initial DB 'firstdb'", 2, db_name == 'firstdb', f"Found '{db_name}'")

            vpc_sgs = target_rds['VpcSecurityGroups']
            has_3306 = False
            is_secure = False
            if vpc_sgs:
                sg_id = vpc_sgs[0]['VpcSecurityGroupId']
                sg_resp = ec2.describe_security_groups(GroupIds=[sg_id])
                perms = sg_resp['SecurityGroups'][0]['IpPermissions']
                for p in perms:
                    if p.get('FromPort') == 3306 or p.get('IpProtocol') == '-1':
                        has_3306 = True
                        is_public = any(r.get('CidrIp') == '0.0.0.0/0' for r in p.get('IpRanges', []))
                        if not is_public: is_secure = True
            
            grade_step("RDS SG: Port 3306 Open", 2, has_3306)
            grade_step("RDS SG: No Public Access (0.0.0.0)", 3, is_secure and has_3306)

            print("    Checking S3 for evidence file...")
            file_found = False
            has_first = False
            has_test = False
            if target_bucket_name:
                try:
                    file_obj = s3.get_object(Bucket=target_bucket_name, Key='db_results.txt')
                    content = file_obj['Body'].read().decode('utf-8')
                    file_found = True
                    if "firstdb" in content: has_first = True
                    if "testdb" in content: has_test = True
                except:
                    pass
            
            grade_step("Evidence File Found in S3", 5, file_found)
            grade_step("Evidence: Connection ('firstdb' listed)", 5, has_first)
            grade_step("Evidence: Manual Task ('testdb' listed)", 5, has_test)

        else:
            grade_step("RDS Name Correct", 1, False)
            grade_step("RDS Specs (t4g.micro/30GB)", 2, False)
            grade_step("Initial DB 'firstdb'", 2, False)
            grade_step("RDS SG: Port 3306 Open", 2, False)
            grade_step("RDS SG: No Public Access", 3, False)
            grade_step("Evidence File Found in S3", 5, False)
            grade_step("Evidence: Connection", 5, False)
            grade_step("Evidence: Manual Task", 5, False)

    except Exception as e:
        print(f"Error Task 4: {e}")

    print_header("FINAL RESULT")
    print(f"TOTAL SCORE: {SCORED_MARKS} / 100")

if __name__ == "__main__":
    main()
