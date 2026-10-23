# QuickBooks Online connector for Houston

A [Houston](https://ok-houston.com) connector bundle for the QuickBooks Online Accounting API,
written to the [houston-hub](https://github.com/aibakery/houston-hub) manifest v1 contract.

- `connectors/quickbooks/houston.json`: settings, Intuit OAuth and allowed API routes
- `connectors/quickbooks/connector.luau`: operations and agent help
- `connectors/quickbooks/tests/`: behavior fixtures run by Hub at registration
- `connectors/quickbooks/README.md` and `SETUP.md`: what people see in Hub

## Publish

In Houston Hub, open **My connectors → Publish**, enter this repository as `owner/repository`,
and use `connectors/quickbooks/houston.json` as the manifest path. Hub validates the manifest,
type-checks the Luau and runs the fixtures before creating a release. Then add a connection
and follow `SETUP.md`.
