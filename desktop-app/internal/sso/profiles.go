package sso

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Profile is an AWS CLI profile that signs in with SSO.
type Profile struct {
	Name      string `json:"name"`
	StartURL  string `json:"startUrl"`
	Region    string `json:"region"`
	AccountID string `json:"accountId,omitempty"`
	RoleName  string `json:"roleName,omitempty"`
}

// ConfigPath is where the AWS CLI keeps its configuration.
func ConfigPath() string {
	if p := os.Getenv("AWS_CONFIG_FILE"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".aws", "config")
}

// LoadProfiles reads the SSO profiles from the AWS CLI config at path. A missing file is not an error: it just
// means there are none, and the person can type their start URL instead. Only the SSO settings are read; keys,
// tokens and everything else in the file are ignored.
func LoadProfiles(path string) ([]Profile, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	sections := map[string]map[string]string{}
	var cur map[string]string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || line[0] == '#' || line[0] == ';' {
			continue
		}
		if line[0] == '[' && line[len(line)-1] == ']' {
			name := strings.TrimSpace(line[1 : len(line)-1])
			cur = map[string]string{}
			sections[name] = cur
			continue
		}
		if cur == nil {
			continue
		}
		if k, v, ok := strings.Cut(line, "="); ok {
			switch k = strings.TrimSpace(k); k {
			case "sso_start_url", "sso_region", "sso_account_id", "sso_role_name", "sso_session":
				cur[k] = strings.TrimSpace(v)
			}
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}

	var out []Profile
	for section, kv := range sections {
		name := section
		switch {
		case section == "default":
		case strings.HasPrefix(section, "profile "):
			name = strings.TrimSpace(strings.TrimPrefix(section, "profile "))
		default:
			continue // [sso-session x] and anything else is not a profile
		}
		start, region := kv["sso_start_url"], kv["sso_region"]
		if s := kv["sso_session"]; s != "" { // newer configs keep the start URL in a shared [sso-session]
			if sess := sections["sso-session "+s]; sess != nil {
				start, region = sess["sso_start_url"], sess["sso_region"]
			}
		}
		if start == "" || region == "" {
			continue
		}
		out = append(out, Profile{Name: name, StartURL: start, Region: region, AccountID: kv["sso_account_id"], RoleName: kv["sso_role_name"]})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}
