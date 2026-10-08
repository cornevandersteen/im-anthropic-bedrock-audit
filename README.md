# Amazon Bedrock Audit Script (Anthropic / Claude)

A **read-only** diagnostic script that audits an AWS account for Anthropic
(Claude) model access and quota problems on **Amazon Bedrock**. It inventories
the Anthropic foundation models visible to the account and reports on model
access, quotas, inference profiles and the stored use-case form — so that a
missing-access or "quota is 0" situation can be understood quickly and
documented for a support request.

It is provided by Ingram Micro for partners and customers who consume Anthropic
models through Amazon Bedrock and need a clear, structured status report.

## Why this exists

Getting the newest Claude models running on Bedrock can fail for several
different reasons that look similar from the outside (no use-case form, missing
model agreement, model not authorized/entitled in the region, or access granted
but the token-per-minute quota is still `0`). This script makes those states
explicit and distinguishable, in a single report, without changing anything in
the account.

## What it checks

- Dynamic Anthropic foundation-model inventory (no hard-coded model versions)
- System inference profiles (EU / Global)
- Stored Anthropic use-case (FTU) read-out
- Agreement / authorization / entitlement / region availability per model
- Applied runtime quotas vs. AWS default quotas (TPM / RPM)
- Service Quotas request history
- Optional runtime test (opt-in via `--invoke`) when access is `READY` and a
  matching TPM quota is `> 0`

## Safety

- **No configuration changes.** The audit never writes to the account.
- **Read-only by default.** A tiny runtime invocation runs **only** if you pass
  `--invoke`; that call can create minimal Bedrock usage/cost.
- Produces **exactly one output file**: the full terminal transcript, saved as
  `IM_Bedrock_Audit_<Partner>_<Customer>_<account>_<timestamp>.txt`. All
  intermediate data is kept in a temporary directory and removed on exit.

> Review any script before running it in your account — including this one.

## Requirements

- Bash (the script re-execs under Bash if started with `sh`)
- AWS CLI v2, authenticated (a named profile or ambient CloudShell/session
  credentials)
- `python3` (recommended — used to decode the use-case `formData`)
- Read access to Amazon Bedrock and Service Quotas

## Usage

```bash
chmod +x im-anthropic-bedrock-audit.sh
./im-anthropic-bedrock-audit.sh [--profile NAME] [--region REGION] [--invoke] [--global]
```

Options:

- `--profile NAME` — AWS CLI profile. If omitted, the current session /
  CloudShell credentials are offered first, then any named profiles.
- `--region REGION` — default `eu-central-1`.
- `--invoke` — run the automatic runtime test. This invokes models and can
  create minimal Bedrock usage/cost. Off by default.
- `--global` — with `--invoke`, also test Global inference profiles. By default
  only EU inference profiles are tested.
- `-h`, `--help` — show help.

### Run in AWS CloudShell (no local setup)

1. Sign in to the AWS Console for the account you want to audit.
2. Set the Region (top-right) to the region you use (e.g. Europe (Frankfurt),
   `eu-central-1`).
3. Open **CloudShell**, upload `im-anthropic-bedrock-audit.sh`
   (**Actions → Upload file**), then:

   ```bash
   chmod +x im-anthropic-bedrock-audit.sh
   ./im-anthropic-bedrock-audit.sh
   ```

4. Download the generated `IM_Bedrock_Audit_...txt` (**Actions → Download file**).

## Output / result codes

The runtime-test section (`--invoke`) uses these result codes:

- `OK` — model invoked successfully.
- `SKIP/<STATE>` — access not `READY` (e.g. `SKIP/AGREEMENT`).
- `SKIP/QUOTA0` — a dedicated cross-region TPM quota exists but is `0`.
- `SKIP/NO-QUOTA` — no dedicated cross-region TPM quota item found for the model
  (often `LEGACY` models); not equivalent to "no model access".
- `SKIP/NO-EU` — no testable EU inference profile with TPM `> 0` in the default
  scope; the model may still be reachable via Global with `--global`.
- `RETENTION-REQ` — the model requires a data-retention setting that the account
  does not currently meet (the audit changes no configuration).

## License & disclaimer

Released under the [MIT License](LICENSE). The software is provided **"as is",
without warranty of any kind** and without any liability — see the LICENSE file
for the full disclaimer. Running the script (especially with `--invoke`) is at
your own responsibility and may create minimal Amazon Bedrock usage/cost.

## Contact

Tobias Tomandl — <tobias.tomandl@ingrammicro.com>

---

Copyright (c) 2026 Ingram Micro
