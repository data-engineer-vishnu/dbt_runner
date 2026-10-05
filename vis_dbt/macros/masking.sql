{#-
  BigQuery dynamic column masking, driven by dbt YAML.

  Terraform (terraform/masking.tf) creates the direct v2 data policies.
  This post-hook attaches them to table columns based on YAML:

      models:
        - name: customer
          columns:
            - name: email
              config:
                meta:
                  mask_policy: email      # key of var('mask_data_policies')
            - name: city
              config:
                meta:
                  mask_policy: none       # explicit opt-out (stops inheritance)

  Rules
  * Explicit `mask_policy` on a column always wins.
  * Inheritance (var `mask_inherit_from_parents`, default true): when a model
    selects a column with the same name as a masked column of one of its
    parents (models, seeds, snapshots or sources), the parent's policy is
    re-applied downstream. This stops `select * from {{ ref('customer') }}`
    from silently producing an unmasked copy of PII.
  * Every protected column gets [masking policy, raw_data_policy]: grantees of
    the masking policy see masked values, grantees of raw_data_policy see the
    original values, everyone else gets "Access Denied" on that column.
  * Views can't carry data policies. A view over masked tables is still
    protected by the base table's policies, so inherited masks are skipped for
    views; an explicit mask_policy on a view column is an error.
-#}

{% macro get_column_mask_policy(column) %}
  {#- dbt >= 1.10 stores column meta under `config.meta`; fall back to the legacy top-level `meta`. -#}
  {%- set config_meta = (column.get('config') or {}).get('meta') or {} -%}
  {%- set legacy_meta = column.get('meta') or {} -%}
  {%- set policy = config_meta.get('mask_policy', legacy_meta.get('mask_policy')) -%}
  {%- if policy is none or (policy | string | trim) == '' -%}
    {{ return(none) }}
  {%- endif -%}
  {{ return(policy | string | trim | lower) }}
{% endmacro %}


{% macro is_mask_opt_out(policy) %}
  {{ return(policy in ['none', 'unmasked', 'false']) }}
{% endmacro %}


{% macro resolve_data_policy_ref(policy_id) %}
  {#- Accepts a bare policy ID (mask_email_v2) or a full <project>.region-<loc>.<id> reference. -#}
  {%- if '.' in policy_id -%}
    {{ return(policy_id) }}
  {%- endif -%}
  {%- set project = var('data_policy_project', target.project) -%}
  {%- set location = var('data_policy_location', target.get('location')) -%}
  {%- if not location -%}
    {{ exceptions.raise_compiler_error("Cannot resolve data policy '" ~ policy_id ~ "': set `location` in the dbt profile or the `data_policy_location` var.") }}
  {%- endif -%}
  {{ return(project ~ '.region-' ~ (location | lower) ~ '.' ~ policy_id) }}
{% endmacro %}


{% macro apply_column_masks() %}
  {%- if not execute or not var('masking_enabled', true) -%}
    {{ return('') }}
  {%- endif -%}

  {%- set mask_map = var('mask_data_policies', {}) -%}
  {%- set raw_policy = var('raw_data_policy', none) -%}
  {%- set materialized = model.config.materialized -%}
  {%- set is_view = materialized in ['view', 'materialized_view'] -%}

  {#- 1. Policies declared on this model's own columns. -#}
  {%- set explicit = {} -%}
  {%- for column in model.columns.values() -%}
    {%- set policy = get_column_mask_policy(column) -%}
    {%- if policy is not none -%}
      {%- do explicit.update({(column.name | lower): {'name': column.name, 'policy': policy}}) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- if is_view -%}
    {%- for key, item in explicit.items() if not is_mask_opt_out(item.policy) -%}
      {{ exceptions.raise_compiler_error(
          "Model '" ~ model.name ~ "' column '" ~ item.name ~ "' sets mask_policy but is materialized as a view. "
          ~ "BigQuery data policies can only be attached to tables; mask the upstream table instead."
      ) }}
    {%- endfor -%}
    {{ return('') }}
  {%- endif -%}

  {#- 2. Policies inherited from parents' masked columns. -#}
  {%- set inherited = {} -%}
  {%- if var('mask_inherit_from_parents', true) -%}
    {%- for parent_id in model.depends_on.nodes -%}
      {%- set parent = graph.nodes.get(parent_id) or graph.sources.get(parent_id) -%}
      {%- if parent -%}
        {%- for pcol in parent.columns.values() -%}
          {%- set policy = get_column_mask_policy(pcol) -%}
          {%- if policy is not none and not is_mask_opt_out(policy) and (pcol.name | lower) not in inherited -%}
            {%- do inherited.update({(pcol.name | lower): {'policy': policy, 'parent': parent.name}}) -%}
          {%- endif -%}
        {%- endfor -%}
      {%- endif -%}
    {%- endfor -%}
  {%- endif -%}

  {#- 3. Final column -> policy plan. -#}
  {%- set plan = [] -%}
  {%- for key, item in explicit.items() -%}
    {%- if is_mask_opt_out(item.policy) -%}
      {%- if key in inherited -%}
        {{ log("masking: " ~ this ~ "." ~ item.name ~ " opted out of inherited '" ~ inherited[key].policy ~ "' policy from " ~ inherited[key].parent, info=true) }}
      {%- endif -%}
    {%- else -%}
      {%- do plan.append({'column': item.name, 'policy': item.policy, 'source': 'yaml'}) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- if inherited -%}
    {%- for col in adapter.get_columns_in_relation(this) -%}
      {%- set key = col.name | lower -%}
      {%- if key in inherited and key not in explicit -%}
        {%- do plan.append({'column': col.name, 'policy': inherited[key].policy, 'source': 'inherited from ' ~ inherited[key].parent}) -%}
      {%- endif -%}
    {%- endfor -%}
  {%- endif -%}

  {%- if not plan -%}
    {{ return('') }}
  {%- endif -%}

  {#- 4. Validate, then attach. -#}
  {%- for item in plan -%}
    {%- if item.policy not in mask_map -%}
      {{ exceptions.raise_compiler_error(
          "Model '" ~ model.name ~ "' column '" ~ item.column ~ "' uses mask_policy '" ~ item.policy ~ "' ("
          ~ item.source ~ "), which isn't in the mask_data_policies var. Known policies: "
          ~ (mask_map.keys() | list | join(', '))
      ) }}
    {%- endif -%}
  {%- endfor -%}

  {%- for item in plan -%}
    {%- set refs = [resolve_data_policy_ref(mask_map[item.policy])] -%}
    {%- if raw_policy -%}
      {%- do refs.append(resolve_data_policy_ref(raw_policy)) -%}
    {%- endif -%}
    {%- set ddl -%}
      alter table {{ this }}
      alter column {{ adapter.quote(item.column) }}
      set options (data_policies = [
        {%- for policy_ref in refs %}
        "{'name':'{{ policy_ref }}'}"{{ "," if not loop.last }}
        {%- endfor %}
      ])
    {%- endset -%}
    {{ log("masking: " ~ this ~ "." ~ item.column ~ " -> '" ~ item.policy ~ "' (" ~ item.source ~ ")", info=true) }}
    {%- do run_query(ddl) -%}
  {%- endfor -%}
{% endmacro %}
