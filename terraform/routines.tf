resource "google_bigquery_routine" "is_valid_cusip" {
  project         = var.project_id
  dataset_id      = var.bigquery_dataset
  routine_id      = "is_valid_cusip"
  routine_type    = "SCALAR_FUNCTION"
  language        = "SQL"
  description     = "Validates whether a given string is a valid CUSIP number using the Modulus 10 check-digit algorithm."

  arguments {
    name          = "cusip"
    argument_kind = "FIXED_TYPE"
    data_type     = jsonencode({ typeKind = "STRING" })
  }

  return_type = jsonencode({ typeKind = "BOOL" })

  definition_body = <<-EOS
    (
      WITH input_data AS (
        SELECT UPPER(TRIM(cusip)) AS c
      )
      SELECT
        CASE
          WHEN c IS NULL OR NOT REGEXP_CONTAINS(c, r'^[0-9A-Z*@#]{8}[0-9]$') THEN FALSE
          ELSE (
            SELECT
              MOD(10 - MOD(SUM(DIV(prod, 10) + MOD(prod, 10)), 10), 10) = CAST(SUBSTR(c, 9, 1) AS INT64)
            FROM
              UNNEST(GENERATE_ARRAY(1, 8)) AS pos,
              UNNEST([SUBSTR(c, pos, 1)]) AS ch,
              UNNEST([
                CASE
                  WHEN ch BETWEEN '0' AND '9' THEN CAST(ch AS INT64)
                  WHEN ch BETWEEN 'A' AND 'Z' THEN ASCII(ch) - 55
                  WHEN ch = '*' THEN 36
                  WHEN ch = '@' THEN 37
                  WHEN ch = '#' THEN 38
                END * IF(MOD(pos, 2) = 0, 2, 1)
              ]) AS prod
          )
        END
      FROM input_data
    )
  EOS
}