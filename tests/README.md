# Testing

## Terraform module tests

`modules/team-resources/tests/module.tftest.hcl` - runs against `mock_provider "aws" {}`
(Terraform 1.7+), so no real AWS account or network access is needed. Covers:

- naming convention (bucket + IAM role names)
- private buckets stay fully locked down (public access block, versioning, SSE, TLS-deny policy)
- public buckets relax only the two required settings and get an explicit public-read policy
- IAM policy resource list contains only that team's own bucket ARNs, never a wildcard
- a bucket missing `visibility`, an invalid `visibility` value, an invalid `team_name`, and
  duplicate bucket names all fail `terraform plan`

Run it:

```bash
cd modules/team-resources
terraform init -backend=false
terraform test
```

## Schema contract test

`validate_team_configs.py` validates every `teams/*/team.yaml` against
`teams/schema/team.schema.json`, and checks the `team` field matches its directory name. This is
meant to run before any Terraform command touches a team's config - see the CI workflow.

```bash
pip install -r tests/requirements.txt
python3 tests/validate_team_configs.py
```

## Schema property-based tests

`test_team_schema_properties.py` uses [Hypothesis](https://hypothesis.readthedocs.io/) to fuzz
each regex-constrained field (`team`, `owner`, `cost_center`, bucket `name`) against a plain-Python
reference implementation of the same rule, generation biased toward each rule's length boundary
(off-by-one lengths included) - the region a hand-written example test is most likely to miss.
Also covers structural rules: empty bucket list, unknown top-level keys, and each required field
actually being required.

```bash
pip install -r tests/requirements.txt
pytest tests/test_team_schema_properties.py
```

To get a single self-contained HTML report (useful as a CI artifact):

```bash
pytest tests/test_team_schema_properties.py --html=report.html --self-contained-html
```

## Static analysis

- `.tflint.hcl` (repo root) - naming convention, unused declarations, documented
  variables/outputs, AWS ruleset. Run with `tflint --recursive` from the repo root.
- `.checkov.yaml` (repo root) - scans `modules/`, `live/`, `bootstrap/`. A handful of checks are
  suppressed with a documented reason (see the file) - mainly the two settings that public
  buckets intentionally relax, and hardening steps out of scope for this exercise (KMS-by-default,
  lifecycle rules, event notifications, state bucket access logging). Run with:
  ```bash
  checkov --config-file .checkov.yaml
  ```
