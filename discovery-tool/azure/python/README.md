# Datafy Discovery Tool — Azure, Python

See the [Azure README](../README.md) for what the tool collects, permissions,
`--setup-role`, and the output format.

## Requirements

- Python 3.9+
- `azure-identity` — preinstalled in Azure Cloud Shell, or `pip install azure-identity`

That single package is all this needs: it brings `azure-core`, which carries the
HTTP pipeline used here.

## Usage

```bash
pip install azure-identity
az login
python3 discovery.py
```

Sign-in also works via managed identity (Cloud Shell, a VM, an AKS pod),
workload identity, service principal environment variables, or a token in
`AZURE_ACCESS_TOKEN` — the tool uses `DefaultAzureCredential`.

See the [Azure README](../README.md#all-flags) for the full flag list.
