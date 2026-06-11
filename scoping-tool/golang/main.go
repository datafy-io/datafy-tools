// Datafy Discovery Tool (Go)
// Inventories EBS volumes, EC2 instances, and backup policies across AWS accounts.
// Read-only — safe to run in production.
//
// Usage:
//
//	discovery [flags]
//	  -profile    AWS named profile (~/.aws/config)
//	  -role       IAM role to assume in child accounts (default: OrganizationAccountAccessRole)
//	  -setup-role Deploy a read-only role via StackSet; auto-removed after scan
//	  -ou         Limit to this Organizational Unit (ou-xxxx-xxxxxxxx)
//	  -include    Comma-separated account IDs to scan
//	  -exclude    Comma-separated account IDs to skip
//	  -output     Output file (default: discovery_<timestamp>.json)
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	backupsvc "github.com/aws/aws-sdk-go-v2/service/backup"
	"github.com/aws/aws-sdk-go-v2/service/cloudformation"
	cfntypes "github.com/aws/aws-sdk-go-v2/service/cloudformation/types"
	"github.com/aws/aws-sdk-go-v2/service/dlm"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/organizations"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

// ── Constants ──────────────────────────────────────────────────────────────────

const (
	version           = "0.1.0"
	defaultRoleName   = "OrganizationAccountAccessRole"
	discoveryRoleName = "DatafyDiscoveryRole"
	stackSetName      = "DatafyDiscovery"
	sessionName       = "DatafyDiscovery"
	sessionDuration   = time.Hour
	maxAccountWorkers = 20
	maxRegionWorkers  = 10
)

// IAM role CloudFormation template deployed to each child account.
// Grants only the permissions this tool actually calls.
const discoveryRoleTemplate = `{
  "AWSTemplateFormatVersion": "2010-09-09",
  "Description": "Datafy Discovery Role — minimal read-only role for EBS/EC2 inventory. Auto-deleted after scan.",
  "Parameters": {
    "ManagementAccountId": { "Type": "String" }
  },
  "Resources": {
    "DatafyDiscoveryRole": {
      "Type": "AWS::IAM::Role",
      "Properties": {
        "RoleName": "DatafyDiscoveryRole",
        "AssumeRolePolicyDocument": {
          "Version": "2012-10-17",
          "Statement": [{ "Effect": "Allow",
            "Principal": { "AWS": { "Fn::Sub": "arn:aws:iam::${ManagementAccountId}:root" } },
            "Action": "sts:AssumeRole" }]
        },
        "Policies": [{ "PolicyName": "DatafyDiscovery", "PolicyDocument": {
          "Version": "2012-10-17",
          "Statement": [{ "Effect": "Allow", "Resource": "*", "Action": [
            "ec2:DescribeVolumes", "ec2:DescribeInstances", "ec2:DescribeRegions",
            "ec2:DescribeImages", "ec2:DescribeSnapshots",
            "dlm:GetLifecyclePolicies", "backup:ListBackupPlans"
          ]}]
        }}]
      }
    }
  }
}`

// ── Output types ───────────────────────────────────────────────────────────────

type Tag struct {
	Key   string `json:"Key"`
	Value string `json:"Value"`
}

type Volume struct {
	VolumeId         string  `json:"VolumeId"`
	Name             *string `json:"Name"`
	Size             int32   `json:"Size"`
	VolumeType       string  `json:"VolumeType"`
	State            string  `json:"State"`
	Iops             *int32  `json:"Iops"`
	Throughput       *int32  `json:"Throughput"`
	Encrypted        bool    `json:"Encrypted"`
	AvailabilityZone string  `json:"AvailabilityZone"`
	SnapshotId       *string `json:"SnapshotId"`
	InstanceId       *string `json:"InstanceId"`
	Device           *string `json:"Device"`
	Tags             []Tag   `json:"Tags"`
}

type Instance struct {
	InstanceId       string  `json:"InstanceId"`
	Name             *string `json:"Name"`
	InstanceType     string  `json:"InstanceType"`
	State            string  `json:"State"`
	Hypervisor       string  `json:"Hypervisor"`
	PlatformDetails  *string `json:"PlatformDetails"`
	ImageId          string  `json:"ImageId"`
	AvailabilityZone string  `json:"AvailabilityZone"`
	RootDeviceName   *string `json:"RootDeviceName"`
	Architecture     string  `json:"Architecture"`
	OwnerId          string  `json:"OwnerId"`
	Tags             []Tag   `json:"Tags"`
}

type AMI struct {
	ImageId      string  `json:"ImageId"`
	Name         *string `json:"Name"`
	Description  *string `json:"Description"`
	Platform     string  `json:"Platform"`
	Architecture string  `json:"Architecture"`
}

type Snapshot struct {
	SnapshotId string  `json:"SnapshotId"`
	VolumeId   *string `json:"VolumeId"`
	VolumeSize *int32  `json:"VolumeSize"`
	StartTime  string  `json:"StartTime"`
	State      string  `json:"State"`
	Encrypted  bool    `json:"Encrypted"`
	Tags       []Tag   `json:"Tags"`
}

type DLMPolicy struct {
	PolicyId    string `json:"PolicyId"`
	Description string `json:"Description"`
	State       string `json:"State"`
	PolicyType  string `json:"PolicyType"`
}

type BackupPlan struct {
	BackupPlanId   string `json:"BackupPlanId"`
	BackupPlanName string `json:"BackupPlanName"`
	CreationDate   string `json:"CreationDate"`
}

type RegionRecord struct {
	AccountId   string       `json:"account_id"`
	Region      string       `json:"region"`
	ScannedAt   string       `json:"scanned_at"`
	Volumes     []Volume     `json:"volumes"`
	Instances   []Instance   `json:"instances"`
	AMIs        []AMI        `json:"amis"`
	Snapshots   []Snapshot   `json:"snapshots"`
	DLMPolicies []DLMPolicy  `json:"dlm_policies"`
	BackupPlans []BackupPlan `json:"backup_plans"`
}

// ── Concurrency helpers ────────────────────────────────────────────────────────

type semaphore chan struct{}

func (s semaphore) acquire() { s <- struct{}{} }
func (s semaphore) release() { <-s }

// ── Tag conversion helpers ─────────────────────────────────────────────────────

func tagsFromEC2(src []ec2types.Tag) []Tag {
	out := make([]Tag, 0, len(src))
	for _, t := range src {
		out = append(out, Tag{Key: aws.ToString(t.Key), Value: aws.ToString(t.Value)})
	}
	return out
}

func nameFromEC2Tags(tags []ec2types.Tag) *string {
	for _, t := range tags {
		if aws.ToString(t.Key) == "Name" {
			v := aws.ToString(t.Value)
			return &v
		}
	}
	return nil
}

// ── AWS helpers ────────────────────────────────────────────────────────────────

func loadBaseConfig(ctx context.Context, profile string) (aws.Config, error) {
	var opts []func(*config.LoadOptions) error
	if profile != "" {
		opts = append(opts, config.WithSharedConfigProfile(profile))
	}
	return config.LoadDefaultConfig(ctx, opts...)
}

func configForAccount(ctx context.Context, base aws.Config, accountId, callerAccountId, roleName string) (aws.Config, error) {
	if accountId == callerAccountId {
		return base, nil
	}
	roleArn := fmt.Sprintf("arn:aws:iam::%s:role/%s", accountId, roleName)
	stsClient := sts.NewFromConfig(base)
	provider := stscreds.NewAssumeRoleProvider(stsClient, roleArn, func(o *stscreds.AssumeRoleOptions) {
		o.RoleSessionName = sessionName
		o.Duration = sessionDuration
	})
	assumed := base
	assumed.Credentials = aws.NewCredentialsCache(provider)
	// verify credentials are valid before returning
	if _, err := sts.NewFromConfig(assumed).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{}); err != nil {
		return aws.Config{}, err
	}
	return assumed, nil
}

// ── Per-region scan ────────────────────────────────────────────────────────────

func scanRegion(ctx context.Context, cfg aws.Config, accountId, region string) (RegionRecord, error) {
	ec2Client := ec2.NewFromConfig(cfg, func(o *ec2.Options) { o.Region = region })

	// Volumes
	var volumes []Volume
	volPager := ec2.NewDescribeVolumesPaginator(ec2Client, &ec2.DescribeVolumesInput{})
	for volPager.HasMorePages() {
		page, err := volPager.NextPage(ctx)
		if err != nil {
			return RegionRecord{}, fmt.Errorf("describe-volumes: %w", err)
		}
		for _, v := range page.Volumes {
			vol := Volume{
				VolumeId:         aws.ToString(v.VolumeId),
				Name:             nameFromEC2Tags(v.Tags),
				Size:             aws.ToInt32(v.Size),
				VolumeType:       string(v.VolumeType),
				State:            string(v.State),
				Iops:             v.Iops,
				Throughput:       v.Throughput,
				Encrypted:        aws.ToBool(v.Encrypted),
				AvailabilityZone: aws.ToString(v.AvailabilityZone),
				SnapshotId:       v.SnapshotId,
				Tags:             tagsFromEC2(v.Tags),
			}
			if len(v.Attachments) > 0 {
				vol.InstanceId = v.Attachments[0].InstanceId
				vol.Device = v.Attachments[0].Device
			}
			volumes = append(volumes, vol)
		}
	}

	// Instances
	var instances []Instance
	amiIds := map[string]struct{}{}
	instPager := ec2.NewDescribeInstancesPaginator(ec2Client, &ec2.DescribeInstancesInput{})
	for instPager.HasMorePages() {
		page, err := instPager.NextPage(ctx)
		if err != nil {
			return RegionRecord{}, fmt.Errorf("describe-instances: %w", err)
		}
		for _, r := range page.Reservations {
			ownerId := aws.ToString(r.OwnerId)
			for _, i := range r.Instances {
				amiIds[aws.ToString(i.ImageId)] = struct{}{}
				inst := Instance{
					InstanceId:       aws.ToString(i.InstanceId),
					Name:             nameFromEC2Tags(i.Tags),
					InstanceType:     string(i.InstanceType),
					Hypervisor:       string(i.Hypervisor),
					PlatformDetails:  i.PlatformDetails,
					ImageId:          aws.ToString(i.ImageId),
					AvailabilityZone: aws.ToString(i.Placement.AvailabilityZone),
					RootDeviceName:   i.RootDeviceName,
					Architecture:     string(i.Architecture),
					OwnerId:          ownerId,
					Tags:             tagsFromEC2(i.Tags),
				}
				if i.State != nil {
					inst.State = string(i.State.Name)
				}
				instances = append(instances, inst)
			}
		}
	}

	// AMIs referenced by discovered instances
	var amis []AMI
	if len(amiIds) > 0 {
		ids := make([]string, 0, len(amiIds))
		for id := range amiIds {
			ids = append(ids, id)
		}
		resp, err := ec2Client.DescribeImages(ctx, &ec2.DescribeImagesInput{ImageIds: ids})
		if err == nil {
			for _, a := range resp.Images {
				amis = append(amis, AMI{
					ImageId:      aws.ToString(a.ImageId),
					Name:         a.Name,
					Description:  a.Description,
					Platform:     string(a.Platform),
					Architecture: string(a.Architecture),
				})
			}
		}
	}

	// Snapshots (owned by this account)
	var snapshots []Snapshot
	snapPager := ec2.NewDescribeSnapshotsPaginator(ec2Client, &ec2.DescribeSnapshotsInput{
		OwnerIds: []string{"self"},
	})
	for snapPager.HasMorePages() {
		page, err := snapPager.NextPage(ctx)
		if err != nil {
			break
		}
		for _, s := range page.Snapshots {
			snap := Snapshot{
				SnapshotId: aws.ToString(s.SnapshotId),
				VolumeId:   s.VolumeId,
				VolumeSize: s.VolumeSize,
				State:      string(s.State),
				Encrypted:  aws.ToBool(s.Encrypted),
				Tags:       tagsFromEC2(s.Tags),
			}
			if s.StartTime != nil {
				snap.StartTime = s.StartTime.UTC().Format(time.RFC3339)
			}
			snapshots = append(snapshots, snap)
		}
	}

	// DLM policies
	var dlmPolicies []DLMPolicy
	dlmClient := dlm.NewFromConfig(cfg, func(o *dlm.Options) { o.Region = region })
	if dlmResp, err := dlmClient.GetLifecyclePolicies(ctx, &dlm.GetLifecyclePoliciesInput{}); err == nil {
		for _, p := range dlmResp.Policies {
			dlmPolicies = append(dlmPolicies, DLMPolicy{
				PolicyId:    aws.ToString(p.PolicyId),
				Description: aws.ToString(p.Description),
				State:       string(p.State),
				PolicyType:  string(p.PolicyType),
			})
		}
	}

	// AWS Backup plans
	var backupPlans []BackupPlan
	backupClient := backupsvc.NewFromConfig(cfg, func(o *backupsvc.Options) { o.Region = region })
	bkPager := backupsvc.NewListBackupPlansPaginator(backupClient, &backupsvc.ListBackupPlansInput{})
	for bkPager.HasMorePages() {
		page, err := bkPager.NextPage(ctx)
		if err != nil {
			break
		}
		for _, b := range page.BackupPlansList {
			plan := BackupPlan{
				BackupPlanId:   aws.ToString(b.BackupPlanId),
				BackupPlanName: aws.ToString(b.BackupPlanName),
			}
			if b.CreationDate != nil {
				plan.CreationDate = b.CreationDate.UTC().Format(time.RFC3339)
			}
			backupPlans = append(backupPlans, plan)
		}
	}

	return RegionRecord{
		AccountId:   accountId,
		Region:      region,
		ScannedAt:   time.Now().UTC().Format(time.RFC3339),
		Volumes:     volumes,
		Instances:   instances,
		AMIs:        amis,
		Snapshots:   snapshots,
		DLMPolicies: dlmPolicies,
		BackupPlans: backupPlans,
	}, nil
}

// ── Per-account scan ───────────────────────────────────────────────────────────

func scanAccount(ctx context.Context, base aws.Config, accountId, callerAccountId, roleName string) ([]RegionRecord, error) {
	cfg, err := configForAccount(ctx, base, accountId, callerAccountId, roleName)
	if err != nil {
		return nil, fmt.Errorf("cannot assume role: %w", err)
	}

	ec2Client := ec2.NewFromConfig(cfg, func(o *ec2.Options) { o.Region = "us-east-1" })
	regResp, err := ec2Client.DescribeRegions(ctx, &ec2.DescribeRegionsInput{})
	if err != nil {
		return nil, fmt.Errorf("describe-regions: %w", err)
	}

	var (
		mu      sync.Mutex
		wg      sync.WaitGroup
		records []RegionRecord
		sem     = make(semaphore, maxRegionWorkers)
	)

	for _, r := range regResp.Regions {
		region := aws.ToString(r.RegionName)
		wg.Add(1)
		go func(region string) {
			defer wg.Done()
			sem.acquire()
			defer sem.release()
			rec, err := scanRegion(ctx, cfg, accountId, region)
			if err != nil {
				fmt.Fprintf(os.Stderr, "  [warn] %s/%s: %v\n", accountId, region, err)
				return
			}
			mu.Lock()
			records = append(records, rec)
			mu.Unlock()
		}(region)
	}
	wg.Wait()
	return records, nil
}

// ── Account list ───────────────────────────────────────────────────────────────

func listAccounts(ctx context.Context, cfg aws.Config, ou string, include []string, exclude map[string]bool) ([]string, error) {
	if len(include) > 0 {
		out := make([]string, 0, len(include))
		for _, a := range include {
			if !exclude[a] {
				out = append(out, a)
			}
		}
		return out, nil
	}

	orgClient := organizations.NewFromConfig(cfg)
	var accounts []string

	if ou != "" {
		pager := organizations.NewListAccountsForParentPaginator(orgClient, &organizations.ListAccountsForParentInput{
			ParentId: aws.String(ou),
		})
		for pager.HasMorePages() {
			page, err := pager.NextPage(ctx)
			if err != nil {
				return nil, err
			}
			for _, a := range page.Accounts {
				if string(a.Status) == "ACTIVE" && !exclude[aws.ToString(a.Id)] {
					accounts = append(accounts, aws.ToString(a.Id))
				}
			}
		}
	} else {
		pager := organizations.NewListAccountsPaginator(orgClient, &organizations.ListAccountsInput{})
		for pager.HasMorePages() {
			page, err := pager.NextPage(ctx)
			if err != nil {
				return nil, err
			}
			for _, a := range page.Accounts {
				if string(a.Status) == "ACTIVE" && !exclude[aws.ToString(a.Id)] {
					accounts = append(accounts, aws.ToString(a.Id))
				}
			}
		}
	}
	return accounts, nil
}

// ── StackSet lifecycle ─────────────────────────────────────────────────────────

func rootOuId(ctx context.Context, cfg aws.Config) (string, error) {
	orgClient := organizations.NewFromConfig(cfg)
	resp, err := orgClient.ListRoots(ctx, &organizations.ListRootsInput{})
	if err != nil {
		return "", err
	}
	return aws.ToString(resp.Roots[0].Id), nil
}

func stackSetTargets(ctx context.Context, cfg aws.Config, ou string, include []string) (*cfntypes.DeploymentTargets, error) {
	if len(include) > 0 {
		return &cfntypes.DeploymentTargets{Accounts: include}, nil
	}
	ouId := ou
	if ouId == "" {
		var err error
		ouId, err = rootOuId(ctx, cfg)
		if err != nil {
			return nil, err
		}
	}
	return &cfntypes.DeploymentTargets{OrganizationalUnitIds: []string{ouId}}, nil
}

func waitForStackSetOp(ctx context.Context, cfClient *cloudformation.Client, opId string) error {
	for {
		resp, err := cfClient.DescribeStackSetOperation(ctx, &cloudformation.DescribeStackSetOperationInput{
			StackSetName: aws.String(stackSetName),
			OperationId:  aws.String(opId),
		})
		if err != nil {
			return err
		}
		switch resp.StackSetOperation.Status {
		case cfntypes.StackSetOperationStatusSucceeded:
			return nil
		case cfntypes.StackSetOperationStatusFailed, cfntypes.StackSetOperationStatusStopped:
			return fmt.Errorf("stackset operation ended with status: %s", resp.StackSetOperation.Status)
		}
		fmt.Println("  Waiting for StackSet operation to complete...")
		time.Sleep(15 * time.Second)
	}
}

func deployStackSet(ctx context.Context, cfg aws.Config, mgmtAccountId, ou string, include []string) error {
	cfClient := cloudformation.NewFromConfig(cfg)

	fmt.Printf("Creating StackSet '%s'...\n", stackSetName)
	_, err := cfClient.CreateStackSet(ctx, &cloudformation.CreateStackSetInput{
		StackSetName: aws.String(stackSetName),
		Description:  aws.String("Datafy Discovery — read-only role. Created by discovery tool, auto-deleted after scan."),
		TemplateBody: aws.String(discoveryRoleTemplate),
		Parameters: []cfntypes.Parameter{{
			ParameterKey:   aws.String("ManagementAccountId"),
			ParameterValue: aws.String(mgmtAccountId),
		}},
		Capabilities:    []cfntypes.Capability{cfntypes.CapabilityCapabilityNamedIam},
		PermissionModel: cfntypes.PermissionModelsServiceManaged,
		AutoDeployment:  &cfntypes.AutoDeployment{Enabled: aws.Bool(false)},
	})
	if err != nil && !strings.Contains(err.Error(), "NameAlreadyExistsException") {
		return fmt.Errorf("create stack set: %w", err)
	}
	if err != nil {
		fmt.Printf("  StackSet '%s' already exists — reusing it.\n", stackSetName)
	}

	targets, err := stackSetTargets(ctx, cfg, ou, include)
	if err != nil {
		return err
	}

	fmt.Println("Deploying role to accounts (this may take a few minutes)...")
	opResp, err := cfClient.CreateStackInstances(ctx, &cloudformation.CreateStackInstancesInput{
		StackSetName:      aws.String(stackSetName),
		DeploymentTargets: targets,
		Regions:           []string{"us-east-1"},
		OperationPreferences: &cfntypes.StackSetOperationPreferences{
			MaxConcurrentPercentage:    aws.Int32(100),
			FailureTolerancePercentage: aws.Int32(50),
		},
	})
	if err != nil {
		return fmt.Errorf("create stack instances: %w", err)
	}

	if err := waitForStackSetOp(ctx, cfClient, aws.ToString(opResp.OperationId)); err != nil {
		return err
	}
	fmt.Println("Role deployed.")
	return nil
}

func teardownStackSet(ctx context.Context, cfg aws.Config, ou string, include []string) {
	cfClient := cloudformation.NewFromConfig(cfg)
	fmt.Printf("Removing StackSet '%s'...\n", stackSetName)

	targets, err := stackSetTargets(ctx, cfg, ou, include)
	if err != nil {
		fmt.Fprintf(os.Stderr, "  [warn] Could not determine StackSet targets: %v\n", err)
		fmt.Fprintf(os.Stderr, "  Please delete StackSet '%s' manually in CloudFormation.\n", stackSetName)
		return
	}

	opResp, err := cfClient.DeleteStackInstances(ctx, &cloudformation.DeleteStackInstancesInput{
		StackSetName:      aws.String(stackSetName),
		DeploymentTargets: targets,
		Regions:           []string{"us-east-1"},
		RetainStacks:      aws.Bool(false),
		OperationPreferences: &cfntypes.StackSetOperationPreferences{
			MaxConcurrentPercentage:    aws.Int32(100),
			FailureTolerancePercentage: aws.Int32(100),
		},
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "  [warn] Could not delete stack instances: %v\n", err)
		fmt.Fprintf(os.Stderr, "  Please delete StackSet '%s' manually in CloudFormation.\n", stackSetName)
		return
	}

	if err := waitForStackSetOp(ctx, cfClient, aws.ToString(opResp.OperationId)); err != nil {
		fmt.Fprintf(os.Stderr, "  [warn] StackSet teardown operation: %v\n", err)
		return
	}

	if _, err := cfClient.DeleteStackSet(ctx, &cloudformation.DeleteStackSetInput{
		StackSetName: aws.String(stackSetName),
	}); err != nil {
		fmt.Fprintf(os.Stderr, "  [warn] Could not delete StackSet: %v\n", err)
		fmt.Fprintf(os.Stderr, "  Please delete StackSet '%s' manually in CloudFormation.\n", stackSetName)
		return
	}
	fmt.Println("StackSet removed.")
}

// ── Entry point ────────────────────────────────────────────────────────────────

func main() {
	versionFlag   := flag.Bool("version",     false,           "Show version")
	profileFlag   := flag.String("profile",    "",              "AWS named profile (~/.aws/config)")
	roleFlag      := flag.String("role",       defaultRoleName, "IAM role to assume in child accounts")
	setupRoleFlag := flag.Bool("setup-role",   false,           "Deploy read-only role via StackSet; auto-removed after scan")
	ouFlag        := flag.String("ou",         "",              "Limit to this Organizational Unit")
	includeFlag   := flag.String("include",    "",              "Comma-separated account IDs to scan")
	excludeFlag   := flag.String("exclude",    "",              "Comma-separated account IDs to skip")
	outputFlag    := flag.String("output",     "",              "Output file (default: discovery_<timestamp>.json)")
	flag.Parse()

	if *versionFlag {
		fmt.Printf("Datafy Discovery Tool v%s\n", version)
		os.Exit(0)
	}

	var include []string
	if *includeFlag != "" {
		for _, a := range strings.Split(*includeFlag, ",") {
			include = append(include, strings.TrimSpace(a))
		}
	}
	exclude := map[string]bool{}
	if *excludeFlag != "" {
		for _, a := range strings.Split(*excludeFlag, ",") {
			exclude[strings.TrimSpace(a)] = true
		}
	}

	ctx := context.Background()

	baseCfg, err := loadBaseConfig(ctx, *profileFlag)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error loading AWS config: %v\n", err)
		os.Exit(1)
	}

	identity, err := sts.NewFromConfig(baseCfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: cannot authenticate — %v\n\nEnsure credentials are configured (--profile, AWS_PROFILE, or aws configure).\n", err)
		os.Exit(1)
	}

	callerAccountId := aws.ToString(identity.Account)
	fmt.Printf("Datafy Discovery Tool v%s\n", version)
	fmt.Printf("Running as:         %s\n", aws.ToString(identity.Arn))
	fmt.Printf("Management account: %s\n", callerAccountId)

	roleName := *roleFlag
	if *setupRoleFlag {
		roleName = discoveryRoleName
		if err := deployStackSet(ctx, baseCfg, callerAccountId, *ouFlag, include); err != nil {
			fmt.Fprintf(os.Stderr, "StackSet deployment failed: %v\n", err)
			os.Exit(1)
		}
		defer teardownStackSet(ctx, baseCfg, *ouFlag, include)
	}

	accounts, err := listAccounts(ctx, baseCfg, *ouFlag, include, exclude)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to list accounts: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("\nAccounts to scan: %d\n", len(accounts))

	outputFile := *outputFlag
	if outputFile == "" {
		outputFile = "discovery_" + time.Now().Format("20060102_150405") + ".json"
	}

	f, err := os.Create(outputFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Cannot create output file: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	enc := json.NewEncoder(f)
	var (
		mu        sync.Mutex
		wg        sync.WaitGroup
		sem       = make(semaphore, maxAccountWorkers)
		completed int
		skipped   int
		failed    int
	)

	for _, acct := range accounts {
		wg.Add(1)
		go func(acct string) {
			defer wg.Done()
			sem.acquire()
			defer sem.release()

			records, err := scanAccount(ctx, baseCfg, acct, callerAccountId, roleName)

			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				failed++
				fmt.Fprintf(os.Stderr, "  [fail] %s: %v\n", acct, err)
				return
			}
			if len(records) == 0 {
				skipped++
				return
			}
			for _, r := range records {
				_ = enc.Encode(r)
			}
			completed++
			fmt.Printf("  [%d/%d] %s — %d regions\n", completed+skipped+failed, len(accounts), acct, len(records))
		}(acct)
	}
	wg.Wait()

	fmt.Printf("\nScanned: %d  Skipped: %d  Failed: %d\n", completed, skipped, failed)
	fmt.Printf("Output:  %s\n", outputFile)
}
