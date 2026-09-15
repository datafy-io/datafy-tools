# Datafy Discovery Tool — Azure, Bash

See the [Azure README](../README.md) for what the tool collects, permissions,
`--setup-role`, and the output format.

## Requirements

- `curl` and `jq`
- bash 3.2+ — the version macOS ships, so no newer bash is needed
- The Azure CLI, **or** a token in `AZURE_ACCESS_TOKEN`

## Usage

```bash
az login
./discovery.sh
```

Without the Azure CLI:

```bash
export AZURE_ACCESS_TOKEN=$(az account get-access-token \
  --resource https://management.azure.com --query accessToken -o tsv)
./discovery.sh
```

## Notes

This talks to ARM with `curl` rather than shelling out to `az` for every
request. `az` pays Python interpreter startup on each invocation and a
tenant-wide scan makes thousands of calls, so a per-call `az` would be far
slower than the other two implementations rather than merely simpler. `az` is
used once, for a token — and not at all when `AZURE_ACCESS_TOKEN` is set, which
is what lets this run where the CLI is not installed.

Response shaping is done in `jq`, with the filters written to match the other
two implementations field for field; the parity harness checks that they do.

If your network terminates TLS with a private CA, name the bundle in
`CURL_CA_BUNDLE`.

See the [Azure README](../README.md#all-flags) for the full flag list.
