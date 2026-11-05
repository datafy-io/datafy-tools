package browser

import "testing"

func TestOnlyAWSSignInPagesAreOpened(t *testing.T) {
	for _, ok := range []string{
		"https://d-906782a959.awsapps.com/start/#/device?user_code=ABCD-EFGH",
		"https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH",
		"https://signin.aws.amazon.com/x",
	} {
		if err := ValidateAWSURL(ok); err != nil {
			t.Errorf("%s should be allowed: %v", ok, err)
		}
	}
	for _, bad := range []string{
		"", "http://d-1.awsapps.com/start", "https://evil.example.com", "https://awsapps.com.evil.io/start",
		"https://evil.io/?x=.awsapps.com", "https://user@d-1.awsapps.com/start", "file:///etc/passwd",
		"javascript:alert(1)", "https://notamazonaws.com", "https://amazonaws.com.evil.io", "calc.exe", "-a Calculator",
	} {
		if err := ValidateAWSURL(bad); err == nil {
			t.Errorf("%q must be refused", bad)
		}
	}
}

func TestTheURLIsAlwaysOneArgumentNeverShellText(t *testing.T) {
	u := "https://d-1.awsapps.com/start/#/device?user_code=A&x=$(id);rm -rf"
	for _, goos := range []string{"darwin", "windows", "linux"} {
		name, args := command(goos, u)
		if name == "sh" || name == "cmd" || name == "bash" || name == "powershell" {
			t.Errorf("%s: must not go through a shell (%s)", goos, name)
		}
		if args[len(args)-1] != u {
			t.Errorf("%s: the URL must be passed whole and last, got %v", goos, args)
		}
	}
}
