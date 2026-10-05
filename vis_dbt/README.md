Welcome to your new dbt project!

### Using the starter project

Try running the following commands:
- dbt run
- dbt test


### Resources:
- Learn more about dbt [in the docs](https://docs.getdbt.com/docs/introduction)
- Check out [Discourse](https://discourse.getdbt.com/) for commonly asked questions and answers
- Join the [chat](https://community.getdbt.com/) on Slack for live discussions and support
- Find [dbt events](https://events.getdbt.com) near you
- Check out [the blog](https://blog.getdbt.com/) for the latest news on dbt's development and best practices


### Column masking (BigQuery)

Mask a column by adding `mask_policy` to its YAML (see `models/masking.yml`):

```yaml
models:
  - name: customer
    columns:
      - name: email
        config:
          meta:
            mask_policy: email      # any key of vars.mask_data_policies
      - name: city
        config:
          meta:
            mask_policy: none       # explicitly unmasked
```

`macros/masking.sql` runs as a post-hook on every model and seed and attaches
the BigQuery data policy (plus the raw-access policy) to the column.

- Downstream models inherit masks: a column with the same name as a masked
  column in a parent model/seed/source gets the parent's policy automatically.
  Override it with another `mask_policy`, or `none` to opt out.
- Masked models must be tables (or incremental/seed/snapshot), not views.
- Policies are created by `terraform/masking.tf`; names live in
  `vars.mask_data_policies` in `dbt_project.yml`.
- Vars: `masking_enabled` (default true), `mask_inherit_from_parents`
  (default true), `data_policy_project` / `data_policy_location` (default to
  the target's project and location).
