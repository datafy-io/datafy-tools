package config

// allowed is the set of web origins that may use the app. A page on any other origin is refused, whatever
// it sends, so a random website cannot read a customer's scan.
//
// TODO(confirm before release): this must be the exact production origin of the Datafy app.
var allowed = []string{
	"https://app.datafy.io",
}

// IsAllowedOrigin reports whether origin (scheme://host[:port], no path) may use the app.
func IsAllowedOrigin(origin string) bool {
	for _, o := range allowed {
		if o == origin {
			return true
		}
	}
	return false
}

// AllowedOrigins returns a copy of the allowed origins, for showing to the user.
func AllowedOrigins() []string { return append([]string(nil), allowed...) }
