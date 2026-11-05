package sso

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

const config = `
# a comment
[default]
region = us-east-1
aws_access_key_id = AKIASHOULDNEVERBEREAD
aws_secret_access_key = neverreadthis

[profile management]
sso_session = corp
sso_account_id = 327744850861
sso_role_name = AdministratorAccess
region = us-east-1

[profile legacy]
sso_start_url = https://d-111.awsapps.com/start
sso_region = eu-west-1
sso_account_id = 111111111111
sso_role_name = ReadOnly

[profile plain-keys]
aws_access_key_id = AKIAXXXXXXXXXXXXXXXX
aws_secret_access_key = x

[profile broken-session]
sso_session = missing

[sso-session corp]
sso_start_url = https://d-906782a959.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
`

func TestLoadProfilesFindsOnlySSOProfiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := LoadProfiles(path)
	if err != nil {
		t.Fatal(err)
	}
	want := []Profile{
		{Name: "legacy", StartURL: "https://d-111.awsapps.com/start", Region: "eu-west-1", AccountID: "111111111111", RoleName: "ReadOnly"},
		{Name: "management", StartURL: "https://d-906782a959.awsapps.com/start", Region: "us-east-1", AccountID: "327744850861", RoleName: "AdministratorAccess"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
}

func TestLoadProfilesNeverCarriesKeys(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	_ = os.WriteFile(path, []byte(config), 0o600)
	got, _ := LoadProfiles(path)
	for _, p := range got {
		if p.Name == "default" || p.Name == "plain-keys" {
			t.Fatalf("a profile without SSO settings must not be listed: %+v", p)
		}
	}
}

func TestMissingConfigIsNotAnError(t *testing.T) {
	got, err := LoadProfiles(filepath.Join(t.TempDir(), "nope"))
	if err != nil || got != nil {
		t.Fatalf("got %v, %v", got, err)
	}
}

func TestConfigPathHonoursTheCLIsOverride(t *testing.T) {
	t.Setenv("AWS_CONFIG_FILE", "/tmp/custom-config")
	if ConfigPath() != "/tmp/custom-config" {
		t.Fatal("AWS_CONFIG_FILE should win")
	}
}
