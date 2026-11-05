package protocol

import (
	"net/url"
	"strings"
	"testing"
)

const origin = "https://app.example.com"
const nonce = "abcdefghijklmnop0123456789"

var allow = func(o string) bool { return o == origin }

func link(o, n string) string {
	return "datafy-discovery://open?origin=" + url.QueryEscape(o) + "&nonce=" + n
}

func TestParsesAValidLink(t *testing.T) {
	got, err := Parse(link(origin, nonce), allow)
	if err != nil || got != (Launch{Origin: origin, Nonce: nonce}) {
		t.Fatalf("got %+v, %v", got, err)
	}
	if _, err := Parse("DATAFY-DISCOVERY://open/?origin="+url.QueryEscape(origin)+"&nonce="+nonce, allow); err != nil {
		t.Fatalf("scheme case and a trailing slash are fine: %v", err)
	}
}

func TestRefusesAnythingHostile(t *testing.T) {
	cases := map[string]string{
		"other origin":             link("https://evil.example.com", nonce),
		"origin with a path":       link(origin+"/x", nonce),
		"origin with userinfo":     link("https://a@app.example.com", nonce),
		"origin that is a prefix":  link(origin+".evil.io", nonce),
		"wildcard origin":          link("*", nonce),
		"javascript origin":        link("javascript:alert(1)", nonce),
		"empty origin":             link("", nonce),
		"short nonce":              link(origin, "short"),
		"nonce with punctuation":   link(origin, "abcdefghijklmnop;rm -rf"),
		"overlong nonce":           link(origin, strings.Repeat("a", 129)),
		"wrong scheme":             "https://open?origin=" + url.QueryEscape(origin) + "&nonce=" + nonce,
		"wrong host":               "datafy-discovery://run?origin=" + url.QueryEscape(origin) + "&nonce=" + nonce,
		"extra path":               "datafy-discovery://open/evil?origin=" + url.QueryEscape(origin) + "&nonce=" + nonce,
		"extra parameter":          link(origin, nonce) + "&cmd=calc",
		"duplicate origin":         link(origin, nonce) + "&origin=" + url.QueryEscape("https://evil.example.com"),
		"missing nonce":            "datafy-discovery://open?origin=" + url.QueryEscape(origin),
		"fragment":                 link(origin, nonce) + "#x",
		"userinfo":                 "datafy-discovery://a@open?origin=" + url.QueryEscape(origin) + "&nonce=" + nonce,
		"garbage":                  "%%%",
		"empty":                    "",
		"origin with a query":      link(origin+"?x=1", nonce),
		"origin with a fragment":   link(origin+"#x", nonce),
		"origin with a trailing /": link(origin+"/", nonce),
	}
	for name, raw := range cases {
		if got, err := Parse(raw, allow); err == nil {
			t.Errorf("%s: should be refused, got %+v", name, got)
		}
	}
}

func TestEveryOriginMustPassTheAllowlistToo(t *testing.T) {
	if _, err := Parse(link(origin, nonce), func(string) bool { return false }); err == nil {
		t.Fatal("a well-formed link from a non-allowlisted origin must be refused")
	}
}

func TestValidOriginIsStrict(t *testing.T) {
	for _, ok := range []string{"https://app.datafy.io", "http://localhost:3000", "https://a.b.c:8443"} {
		if !ValidOrigin(ok) {
			t.Errorf("%s should be valid", ok)
		}
	}
	for _, bad := range []string{"", "app.datafy.io", "https://", "https://a/", "https://a/x", "ftp://a", "https://a?x", "https://a#x", "https://u:p@a", " https://a"} {
		if ValidOrigin(bad) {
			t.Errorf("%q should be invalid", bad)
		}
	}
}
