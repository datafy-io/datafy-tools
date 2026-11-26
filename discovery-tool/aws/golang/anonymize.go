package main

// Anonymization (--anonymize-tags, --anonymize-accounts). SAAS-252.
//
// Some customers do not want to share their tag values or account IDs with
// Datafy. Everything here runs on the customer's machine, before a record is
// written, so the file that leaves the building never contains the real values.
//
// The rules are identical in the bash and Python implementations, and the
// parity harness holds all three to the same output byte for byte — change one,
// change all three.

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

const (
	keyFileEnv     = "DATAFY_ANONYMIZE_KEY_FILE"
	keyMinChars    = 32
	mappingSuffix  = ".mapping.private"
	nameHashChars  = 16 // 64 bits: names are few, and a collision would merge two clusters
	acctHashChars  = 12
	kindAccount    = "account"
	kindCluster    = "cluster"
	kindNodeGroup  = "node_group"
	kindASG        = "asg"
	datafyManaged  = "Datafy.io"
	datafyTagKey   = "Managed-By"
	datafyTagPref  = "datafy:"
	k8sClusterPref = "kubernetes.io/cluster/"
)

// A twelve-digit run bounded by non-word characters. ASCII \b in RE2, and
// re.ASCII in the Python implementation, so both agree on what a boundary is.
var accountIdPattern = regexp.MustCompile(`\b[0-9]{12}\b`)

// Tag keys that map to an output field. Order matters where there is more than
// one: the first key present wins.
var (
	clusterKeys   = []string{"eks:cluster-name", "aws:eks:cluster-name", "eks:eks-cluster-name", "ClusterName", "KubernetesCluster"}
	nodeGroupKeys = []string{"eks:nodegroup-name", "karpenter.sh/nodepool"}
	asgKey        = "aws:autoscaling:groupName"
	csiClusterKey = "ebs.csi.aws.com/cluster-name"
	// Present on Kubernetes volumes, but carry nothing worth keeping.
	k8sMarkerKeys = []string{"ebs.csi.aws.com/cluster", "CSIVolumeName", "kubernetes.io/created-for/pv/name"}
)

// AnonFields are the only things that survive of a resource's tags. Embedded by
// pointer: nil leaves the fields out entirely, so a run without
// --anonymize-tags produces exactly the output it always did.
type AnonFields struct {
	Cluster   *string `json:"cluster"`
	NodeGroup *string `json:"node_group"`
	ASG       *string `json:"asg"`
	IsK8s     bool    `json:"is_k8s"`
	ManagedBy *string `json:"managed_by"`
}

// AnonymizationInfo goes on the summary record, so whoever receives the file
// knows what they are looking at.
type AnonymizationInfo struct {
	Tags     bool `json:"tags"`
	Accounts bool `json:"accounts"`
}

type tagFacts struct {
	cluster, nodeGroup, asg, managedBy string
	k8s                                bool
}

type anonymizer struct {
	tags, accounts bool
	key            string

	mu      sync.Mutex
	mapping map[string]map[string]string // kind -> alias -> real value
}

func (a *anonymizer) enabled() bool { return a != nil && (a.tags || a.accounts) }

func (a *anonymizer) info() *AnonymizationInfo {
	if !a.enabled() {
		return nil
	}
	return &AnonymizationInfo{Tags: a.tags, Accounts: a.accounts}
}

func keyFilePath() (string, error) {
	if p := os.Getenv(keyFileEnv); p != "" {
		return p, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot locate a home directory for the anonymization key — set %s: %w", keyFileEnv, err)
	}
	return filepath.Join(home, ".datafy-discovery", "anonymize.key"), nil
}

// loadOrCreateKey returns the secret that keys every hash. It is generated on
// first use and kept, so the same name hashes the same way on later runs.
func loadOrCreateKey() (key, path string, err error) {
	path, err = keyFilePath()
	if err != nil {
		return "", "", err
	}
	if raw, rerr := os.ReadFile(path); rerr == nil {
		key = strings.TrimSpace(string(raw))
		if len(key) < keyMinChars {
			return "", path, fmt.Errorf("the anonymization key in %s is too short — delete the file to generate a new one", path)
		}
		return key, path, nil
	} else if !os.IsNotExist(rerr) {
		return "", path, fmt.Errorf("cannot read the anonymization key %s: %w", path, rerr)
	}

	buf := make([]byte, 32)
	if _, err = rand.Read(buf); err != nil {
		return "", path, fmt.Errorf("cannot generate an anonymization key: %w", err)
	}
	key = hex.EncodeToString(buf)
	if err = os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", path, fmt.Errorf("cannot create the anonymization key directory (set %s to use another location): %w", keyFileEnv, err)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if os.IsExist(err) { // another run created it first — use theirs
			return loadOrCreateKey()
		}
		return "", path, fmt.Errorf("cannot write the anonymization key %s (set %s to use another location): %w", path, keyFileEnv, err)
	}
	defer f.Close()
	if _, err = f.WriteString(key + "\n"); err != nil {
		return "", path, fmt.Errorf("cannot write the anonymization key %s: %w", path, err)
	}
	return key, path, nil
}

func newAnonymizer(tags, accounts bool) (*anonymizer, string, error) {
	if !tags && !accounts {
		return nil, "", nil
	}
	key, path, err := loadOrCreateKey()
	if err != nil {
		return nil, path, err
	}
	return &anonymizer{
		tags: tags, accounts: accounts, key: key,
		mapping: map[string]map[string]string{},
	}, path, nil
}

// alias returns the stable stand-in for a real value and remembers the pairing
// for the mapping file. The digest is SHA-256 over "<key>\n<kind>\n<value>":
// the key is a 256-bit secret, so without it a name cannot be recovered by
// hashing guesses, and the kind keeps a cluster and an ASG of the same name
// from colliding. bash does the same with sha256sum/shasum.
func (a *anonymizer) alias(kind, real string) string {
	sum := sha256.Sum256([]byte(a.key + "\n" + kind + "\n" + real))
	digest := hex.EncodeToString(sum[:])
	out := digest[:nameHashChars]
	if kind == kindAccount {
		out = "acct-" + digest[:acctHashChars]
	}
	a.mu.Lock()
	if a.mapping[kind] == nil {
		a.mapping[kind] = map[string]string{}
	}
	a.mapping[kind][out] = real
	a.mu.Unlock()
	return out
}

func factsFromTags(tags []Tag) tagFacts {
	vals := make(map[string]string, len(tags))
	for _, t := range tags {
		vals[t.Key] = t.Value
	}
	has := func(k string) bool { _, ok := vals[k]; return ok }
	hasPrefix := func(p string) bool {
		for k := range vals {
			if strings.HasPrefix(k, p) {
				return true
			}
		}
		return false
	}

	var f tagFacts

	for _, k := range clusterKeys {
		if has(k) {
			f.k8s = true
			if f.cluster == "" {
				f.cluster = vals[k]
			}
		}
	}
	// kubernetes.io/cluster/<name>: the name is in the key. Smallest key first,
	// so a volume tagged for two clusters resolves the same way every run.
	var named []string
	for k := range vals {
		if strings.HasPrefix(k, k8sClusterPref) && len(k) > len(k8sClusterPref) {
			named = append(named, k)
		}
	}
	sort.Strings(named)
	if len(named) > 0 {
		f.k8s = true
		if f.cluster == "" {
			f.cluster = strings.TrimPrefix(named[0], k8sClusterPref)
		}
	}
	if has(csiClusterKey) {
		f.k8s = true
		if f.cluster == "" {
			f.cluster = vals[csiClusterKey]
		}
	}

	for _, k := range nodeGroupKeys {
		if has(k) {
			f.k8s = true
			if f.nodeGroup == "" {
				f.nodeGroup = vals[k]
			}
		}
	}
	for _, k := range k8sMarkerKeys {
		if has(k) {
			f.k8s = true
		}
	}

	f.asg = vals[asgKey]

	// First match in this order; the tag's value is never kept.
	switch {
	case has("eks:nodegroup-name"):
		f.managedBy = "eks-nodegroup"
	case has(asgKey):
		f.managedBy = "autoscaling-group"
	case hasPrefix("karpenter.sh/"):
		f.managedBy = "karpenter"
	case has("cast:managed-by") || hasPrefix("autoscaling.cast.ai/"):
		f.managedBy = "cast.ai"
	case has("kops.k8s.io/instancegroup"):
		f.managedBy = "kops"
	case hasPrefix("sigs.k8s.io/cluster-api-provider-aws/"):
		f.managedBy = "cluster-api"
	case has("aws:cloudformation:stack-name"):
		f.managedBy = "cloudformation"
	}
	return f
}

// datafyTags keeps Datafy's own tags and nothing else.
func datafyTags(tags []Tag) []Tag {
	out := []Tag{}
	for _, t := range tags {
		if (t.Key == datafyTagKey && t.Value == datafyManaged) || strings.HasPrefix(t.Key, datafyTagPref) {
			out = append(out, t)
		}
	}
	return out
}

func (a *anonymizer) fields(f tagFacts) *AnonFields {
	opt := func(kind, v string) *string {
		if v == "" {
			return nil
		}
		s := a.alias(kind, v)
		return &s
	}
	out := &AnonFields{
		Cluster:   opt(kindCluster, f.cluster),
		NodeGroup: opt(kindNodeGroup, f.nodeGroup),
		ASG:       opt(kindASG, f.asg),
		IsK8s:     f.k8s || f.cluster != "" || f.nodeGroup != "",
	}
	if f.managedBy != "" {
		m := f.managedBy
		out.ManagedBy = &m
	}
	return out
}

// anonymizeTags replaces every tag on volumes, instances and snapshots with the
// handful of derived fields, and clears Name. A volume inherits cluster, node
// group and ASG from the instance it is attached to, and its own tags override.
func (a *anonymizer) anonymizeTags(volumes []Volume, instances []Instance, snapshots []Snapshot) {
	byInstance := make(map[string]tagFacts, len(instances))
	for i := range instances {
		f := factsFromTags(instances[i].Tags)
		byInstance[instances[i].InstanceId] = f
		instances[i].AnonFields = a.fields(f)
		instances[i].Tags = datafyTags(instances[i].Tags)
		instances[i].Name = nil
	}
	for i := range volumes {
		f := factsFromTags(volumes[i].Tags)
		if volumes[i].InstanceId != nil {
			if inst, ok := byInstance[*volumes[i].InstanceId]; ok {
				if f.cluster == "" {
					f.cluster = inst.cluster
				}
				if f.nodeGroup == "" {
					f.nodeGroup = inst.nodeGroup
				}
				if f.asg == "" {
					f.asg = inst.asg
				}
			}
		}
		volumes[i].AnonFields = a.fields(f)
		volumes[i].Tags = datafyTags(volumes[i].Tags)
		volumes[i].Name = nil
	}
	for i := range snapshots {
		snapshots[i].AnonFields = a.fields(factsFromTags(snapshots[i].Tags))
		snapshots[i].Tags = datafyTags(snapshots[i].Tags)
	}
}

// scrubAccounts replaces every account ID in an encoded record with its alias.
// It works on the encoded text so that nothing is missed: account_id fields,
// an instance's OwnerId, and the account IDs AWS embeds in error messages and
// ARNs are all just twelve digits. A twelve-digit run that is not an account is
// aliased too — over-masking is the safe direction, and the mapping file has it.
func (a *anonymizer) scrubAccounts(line []byte) []byte {
	return accountIdPattern.ReplaceAllFunc(line, func(m []byte) []byte {
		return []byte(a.alias(kindAccount, string(m)))
	})
}

// mappingJSON renders the mapping file: every alias and hash with the real value
// behind it. Only the sections for the options that were used are present.
func (a *anonymizer) mappingJSON(toolVersion, createdAt string) []byte {
	a.mu.Lock()
	defer a.mu.Unlock()

	doc := map[string]any{
		"note":         "PRIVATE: maps the anonymized values in the discovery output back to the real ones. Keep this file; do not send it to Datafy.",
		"tool_version": toolVersion,
		"created_at":   createdAt,
	}
	section := func(name, kind string) {
		m := map[string]string{}
		for alias, real := range a.mapping[kind] {
			m[alias] = real
		}
		doc[name] = m
	}
	if a.accounts {
		section("accounts", kindAccount)
	}
	if a.tags {
		section("clusters", kindCluster)
		section("node_groups", kindNodeGroup)
		section("asgs", kindASG)
	}
	out, _ := json.MarshalIndent(doc, "", "  ") // encoding/json sorts map keys
	return append(out, '\n')
}
