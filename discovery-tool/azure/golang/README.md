# Datafy Discovery Tool — Azure, Go

See the [Azure README](../README.md) for what the tool collects, permissions,
`--setup-role`, and the output format.

## Requirements

- A pre-built binary from [Releases](https://github.com/datafy-io/datafy-tools/releases), or Go 1.21+ to build

## Build and run

```bash
go build -o discovery .
az login
./discovery
```

## Notes

Records are built as `map[string]any` rather than as structs. A struct with
`omitempty` would drop the nulls the other two implementations emit, and one
without it would need a pointer for every optional field; maps make "absent
means null" the default, which is what keeps the three byte-identical.

If your network terminates TLS with a private CA, name the bundle in
`AZURE_CA_BUNDLE` (or `SSL_CERT_FILE`). Go reads it explicitly because on macOS
it uses the platform verifier and would otherwise ignore it. The bundle is added
to the system roots rather than replacing them.

See the [Azure README](../README.md#all-flags) for the full flag list.
