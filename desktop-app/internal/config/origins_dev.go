//go:build dev

package config

// Development builds also accept the local Vite dev server. Production builds never do: otherwise any
// program serving a web page on localhost:3000 could read a customer's scan.
func init() {
	allowed = append(allowed, "http://localhost:3000")
}
