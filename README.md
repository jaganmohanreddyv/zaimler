# AWS GPU Capacity Block Reservation Pipeline
# Complete Execution Guide

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  WHAT THIS PIPELINE DOES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This pipeline automates the entire process of finding,
reserving, and launching AWS EC2 GPU Capacity Blocks.

It uses the official AWS capacity finder tool:
https://github.com/aws-samples/sample-capacity-finder-for-ec2-capacity-block-and-sagemaker-training-plan

You run one command. Close your laptop. The pipeline
searches AWS for available GPU capacity across all your
selected regions and AZs for up to 48 hours. When
capacity is found you receive an email. You approve from
your email. The pipeline does the rest.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PROJECT STRUCTURE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  my-project/
  ├── README.md                 ← This file
  ├── config.env                ← Your settings (edit this)
  ├── main.sh                   ← Entry point (run this)
  ├── aws_check_create.sh       ← Creates 8 AWS resources
  ├── reserve.sh                ← Purchases capacity block
  ├── launch.sh                 ← Launches GPU instances
  ├── monitor.sh                ← Post-launch monitoring
  ├── dashboard.py              ← Live tracking dashboard
  └── capacity-finder/          ← Official AWS repo (auto-cloned)
      ├── app.py                ← AWS capacity finder functions
      └── requirements.txt      ← boto3, pandas, streamlit

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 0 — INTRODUCTION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  What you need to know before starting:

  1. You only run one command — bash main.sh
  2. All decisions are made through email only
  3. The dashboard is read-only — no buttons
  4. The AWS capacity finder repo is used for all
     discovery — cloned automatically on first run
  5. AWS watcher services are temporary — deleted
     at the end of every outcome automatically
  6. Nothing from aws_check_create.sh is ever
     deleted by the pipeline

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 1 — PREREQUISITES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  1.1 Install required tools

      # AWS CLI v2
      # macOS
      brew install awscli

      # Linux
      curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
      -o "awscliv2.zip"
      unzip awscliv2.zip && sudo ./aws/install

      # Windows (PowerShell as Administrator)
      msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi

      # Python 3.13+
      python --version

      # Git
      git --version

  1.2 Install Python dependencies

      pip install -r capacity-finder/requirements.txt

      Dependencies:
      - streamlit==1.49.0
      - boto3==1.40.18
      - pandas==2.3.2

  1.3 Configure AWS credentials — choose one method

      Method 1 — Interactive (personal accounts)
      aws configure

      Method 2 — Environment variables (CI/CD)
      export AWS_ACCESS_KEY_ID=your_key
      export AWS_SECRET_ACCESS_KEY=your_secret
      export AWS_DEFAULT_REGION=us-east-1

      Method 3 — Named profile (multiple accounts)
      aws configure --profile capacity-finder
      export AWS_PROFILE=capacity-finder

      Method 4 — AWS SSO (company accounts)
      aws configure sso
      aws sso login --profile my-sso-profile

      Verify credentials:
      aws sts get-caller-identity

  1.4 Required IAM permissions

      Minimum permissions for discovery only:
      - ec2:DescribeCapacityBlockOfferings
      - sagemaker:SearchTrainingPlanOfferings

      Full permissions for entire pipeline:
      - ec2:PurchaseCapacityBlock
      - ec2:DescribeCapacityBlockOfferings
      - ec2:DescribeCapacityReservations
      - ec2:RunInstances
      - ec2:DescribeInstances
      - ec2:TerminateInstances
      - ec2:CreateTags
      - ec2:DescribePlacementGroups
      - ec2:CreatePlacementGroup
      - ec2:CreateLaunchTemplate
      - ec2:DescribeLaunchTemplates
      - ec2:DescribeSubnets
      - ec2:DescribeSecurityGroups
      - ec2:DescribeKeyPairs
      - iam:PassRole
      - sns:CreateTopic
      - sns:Subscribe
      - sns:Publish
      - ssm:PutParameter
      - ssm:GetParameter
      - cloudwatch:PutMetricAlarm
      - states:CreateStateMachine
      - states:StartExecution
      - lambda:CreateFunction
      - events:PutRule
      - dynamodb:CreateTable
      - apigateway:POST

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 2 — CONFIGURE config.env
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Open config.env and fill in your values.
  This is the only file you need to edit.

  # ── AWS ACCOUNT ──────────────────────────────
  AWS_ACCOUNT_ID="123456789012"
  AWS_REGION="us-east-1"
  AWS_PROFILE=""

  # ── INSTANCE CONFIGURATION ───────────────────
  # Single:   INSTANCE_TYPES="p5.48xlarge"
  # Multiple: INSTANCE_TYPES="p5.48xlarge,p4d.24xlarge"
  INSTANCE_TYPES="p5.48xlarge"
  INSTANCE_COUNT="8"

  # ── REGIONS ──────────────────────────────────
  # Single:   REGIONS="us-east-1"
  # Multiple: REGIONS="us-east-1,us-west-2,eu-west-2"
  REGIONS="us-east-1"

  # ── AVAILABILITY ZONES ────────────────────────
  # Single:   AVAILABILITY_ZONES="us-east-1a"
  # Multiple: AVAILABILITY_ZONES="us-east-1a,us-west-2b,eu-west-2a"
  # Note: Must match the regions above one-to-one
  AVAILABILITY_ZONES="us-east-1a"

  # ── RESERVATION WINDOW ───────────────────────
  DURATION_DAYS="14"
  START_DATE="2025-09-01"

  # ── WATCHER SETTINGS ─────────────────────────
  RETRY_INTERVAL_MINS="15"
  MAX_RETRY_HOURS="48"
  APPROVAL_TIMEOUT_HOURS="4"
  FINAL_CONFIRM_TIMEOUT_MINS="30"

  # ── NOTIFICATIONS ─────────────────────────────
  ALERT_EMAIL="you@company.com"
  SNS_TOPIC_NAME="gpu-capacity-alerts"

  # ── COST TAGGING ──────────────────────────────
  TAG_PROJECT="gpu-training-q3"
  TAG_TEAM="ml-platform"
  TAG_COST_CENTER="cc-4821"
  TAG_ENVIRONMENT="production"

  # ── RESOURCE NAMES ────────────────────────────
  KEY_PAIR_NAME=""
  SUBNET_ID=""
  SECURITY_GROUP_IDS=""
  PLACEMENT_GROUP_NAME=""
  IAM_INSTANCE_PROFILE=""
  LAUNCH_TEMPLATE_NAME=""
  CAPACITY_RESERVATION_ID=""

  Note: Leave resource name fields empty on first run.
  aws_check_create.sh fills them in automatically.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 3 — HOW TO RUN THE PIPELINE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  3.1 Standard run — full pipeline

      bash main.sh

      After this command you can close your laptop.
      All decisions are made through email.

  3.2 Dry run — audit without creating anything

      bash main.sh --dry-run

      Shows exactly what would be created and purchased
      without spending any money or creating any resource.

  3.3 Infrastructure only — run aws_check_create.sh alone

      bash aws_check_create.sh

      Use this if you only want to set up the 8
      prerequisite resources without starting the
      full pipeline.

  3.4 Open the live dashboard (optional)

      streamlit run dashboard.py

      Read-only tracking of the full pipeline.
      All decisions still made through email only.
      Auto-refreshes every 30 seconds.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 4 — INFRASTRUCTURE (aws_check_create.sh)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Runs automatically. Creates these 8 resources
  if they do not already exist:

  Resource             What it is
  ───────────────────────────────────────────────
  Key pair             SSH key for instance access
  Subnet               Network slot in your target AZ
  Security group       Firewall — SSH from your IP only
  Placement group      Low-latency GPU cluster networking
  IAM instance profile Identity attached to instances
  SNS topic            Email notification channel
  IAM permissions      Caller permissions for the pipeline
  Launch template      Complete instance blueprint

  All IDs written back to config.env automatically.
  Safe to re-run — never creates duplicates.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 5 — DISCOVERY (AWS capacity finder repo)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Source:
  https://github.com/aws-samples/
  sample-capacity-finder-for-ec2-capacity-block-and-sagemaker-training-plan

  The official AWS-published capacity finder is cloned
  automatically into capacity-finder/ on first run.
  Updated automatically on every subsequent run via
  git pull — new instance types and regions from AWS
  appear in your scans automatically.

  Functions used from app.py:
  - scan_region()            EC2 capacity search
  - scan_sagemaker_region()  SageMaker plan search
  - run_parallel()           8 workers, all regions at once
  - process_results()        Separate results from errors

  The Streamlit UI in app.py is bypassed entirely.
  Only the four core functions are called.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 6 — 48-HOUR WATCHER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  If capacity is not found on the first attempt
  the watcher loop starts automatically.

  AWS services used:
  - Step Functions    Manages state and flow
  - EventBridge       Fires every 15 minutes
  - Lambda            Runs discovery on each trigger
  - DynamoDB          Tracks retry count and state
  - API Gateway       Handles your email link clicks

  These services are TEMPORARY.
  They are deleted at the end of every outcome.
  They never touch anything from aws_check_create.sh.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 7 — EMAIL APPROVAL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  When capacity is found you receive one email
  per AZ that has availability.

  Each email contains:
  - Instance type, count, region, AZ
  - Start date and time, end date and time
  - Duration and upfront fee
  - Three action links — YES, WAIT, NO

  YES     →  Final confirmation email sent
  WAIT    →  This AZ skipped, watcher continues
  NO      →  This AZ declined, watcher continues

  Multiple AZ emails:
  - One separate email per AZ simultaneously
  - Each email has its own independent token
  - First YES across all emails wins
  - Other emails auto-invalidated after CONFIRM

  Final confirmation email:
  - Sent after YES clicked
  - Shows all details one last time
  - CONFIRM or CANCEL
  - Expires in 30 minutes
  - CONFIRM is the only step that spends money

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 8 — EXIT SCENARIOS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Scenario A — All AZs declined or waited away
  All watcher services deleted. Pipeline stops.
  aws_check_create.sh resources untouched.

  Scenario B — CANCEL clicked on final confirmation
  No purchase made. All watcher services deleted.
  aws_check_create.sh resources untouched.

  Scenario C — 48 hours expired
  You receive email with Retry or Quit options.
  Retry  →  Fresh 48-hour window. Watcher resets.
  Quit   →  All watcher services deleted.
  aws_check_create.sh resources untouched in both.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 9 — RESERVATION (reserve.sh)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Runs automatically after CONFIRM clicked.

  - Purchases the Capacity Block via AWS API
  - Tags reservation with your cost labels
  - Writes Reservation ID to config.env
  - Updates launch template to target this
    specific reservation ID
  - If purchase fails — alert email sent,
    watcher services deleted, pipeline stops

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 10 — LAUNCH (launch.sh)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Runs automatically after reservation confirmed.

  - Waits for reservation window to open
  - Launches all GPU instances using launch template
  - Polls health checks every 15 seconds
  - Waits until all instances pass 2/2 checks
  - Saves instance IDs, private IPs, timestamps
    to config.env and S3 audit bucket

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 11 — MONITOR (monitor.sh)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Runs automatically after all instances healthy.

  - Installs CloudWatch GPU monitoring agent
    on all instances via SSM
  - Applies cost allocation tags to all resources
  - Writes full audit record to S3
  - Verifies CloudTrail captured all API calls
  - Sends pipeline completed email to your team
  - Deletes all temporary watcher services

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STAGE 12 — WATCHER CLEANUP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Deleted in this order in every outcome:

  1.  EventBridge Scheduler rule
  2.  API Gateway endpoint
  3.  DynamoDB table
  4.  Step Functions state machine
  5.  Lambda — first discovery
  6.  Lambda — retry discovery
  7.  Lambda — notify and email
  8.  Lambda — approve and token handler
  9.  Lambda IAM execution role
  10. CloudWatch log groups for watcher
  11. Lambda — cleanup (deletes itself last)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  LIVE DASHBOARD
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  streamlit run dashboard.py

  Pages available:
  - Pipeline overview   Current step and status
  - Infrastructure      All 8 resource statuses
  - Watcher             Retry count, time remaining
  - Capacity search     AWS finder — manual search
  - Reservation         Reservation details
  - Instances           IDs, IPs, health checks
  - Audit log           Last 10 pipeline runs

  Dashboard is READ ONLY.
  No buttons. No approvals. No actions.
  All decisions through email only.
  Auto-refreshes every 30 seconds.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  TROUBLESHOOTING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Problem           Solution
  ────────────────────────────────────────────────────
  Credentials       Run aws sts get-caller-identity
  expired           Refresh token and re-run main.sh

  SKIPPED items     Fix the manual item shown in
  in Stage 2        the summary, then re-run
                    bash aws_check_create.sh

  No email          Check SNS subscription is
  received          confirmed in AWS console.
                    Check spam folder.

  Approval link     Pipeline sends fresh link
  expired           automatically. Check inbox.

  Pipeline stopped  Check CloudWatch logs for the
  unexpectedly      watcher Lambda functions.
                    Check Step Functions console
                    for the current execution state.

  AWS repo not      Delete capacity-finder/ folder
  up to date        and re-run main.sh — it will
                    clone a fresh copy.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  IMPORTANT REMINDERS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  • Never commit config.env, *.pem, or credentials
    to source control. All three are in .gitignore.

  • CONFIRM in the final email is the only action
    that spends money. Everything before it is free.

  • Capacity Blocks cannot be cancelled or refunded
    once purchased. Verify all details carefully
    before clicking CONFIRM.

  • The watcher AWS services cost less than $0.05
    for a full 48-hour search window.

  • aws_check_create.sh resources are never deleted
    by the pipeline under any circumstance.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  LICENSE

  This project is licensed under the MIT License.

  The AWS capacity finder used in this pipeline:
  https://github.com/aws-samples/
  sample-capacity-finder-for-ec2-capacity-block-and-sagemaker-training-plan
  is also licensed under the MIT License.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━