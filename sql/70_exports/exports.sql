-- Exports.
--   outputs/powerbi/*.parquet  star schema for the Power BI model (Parquet keeps types and is ~10x smaller than CSV)
--   outputs/reports/*.csv      metric tables for Excel / review
--   outputs/quality/*.csv      profiling and test results
-- Folders are created by pipeline/build.py.

copy mart.dim_date             to '{{out_dir}}/powerbi/dim_date.parquet'             (format parquet, compression zstd);
copy mart.dim_service_type     to '{{out_dir}}/powerbi/dim_service_type.parquet'     (format parquet, compression zstd);
copy mart.dim_beneficiary_year to '{{out_dir}}/powerbi/dim_beneficiary_year.parquet' (format parquet, compression zstd);
copy mart.dim_provider         to '{{out_dir}}/powerbi/dim_provider.parquet'         (format parquet, compression zstd);
copy mart.dim_diagnosis        to '{{out_dir}}/powerbi/dim_diagnosis.parquet'        (format parquet, compression zstd);
copy mart.fct_claim_line       to '{{out_dir}}/powerbi/fct_claim_line.parquet'       (format parquet, compression zstd);
copy mart.fct_drug_event       to '{{out_dir}}/powerbi/fct_drug_event.parquet'       (format parquet, compression zstd);
copy mart.fct_member_month     to '{{out_dir}}/powerbi/fct_member_month.parquet'     (format parquet, compression zstd);
copy mart.fct_inpatient_stay   to '{{out_dir}}/powerbi/fct_inpatient_stay.parquet'   (format parquet, compression zstd);

copy rpt.pmpm_monthly             to '{{out_dir}}/reports/pmpm_monthly.csv'             (header, delimiter ',');
copy rpt.pmpm_yearly              to '{{out_dir}}/reports/pmpm_yearly.csv'              (header, delimiter ',');
copy rpt.utilization_yearly       to '{{out_dir}}/reports/utilization_yearly.csv'       (header, delimiter ',');
copy rpt.readmission_yearly       to '{{out_dir}}/reports/readmission_yearly.csv'       (header, delimiter ',');
copy rpt.readmission_by_segment   to '{{out_dir}}/reports/readmission_by_segment.csv'   (header, delimiter ',');
copy rpt.top_diagnosis_categories to '{{out_dir}}/reports/top_diagnosis_categories.csv' (header, delimiter ',');
copy rpt.top_diagnosis_codes      to '{{out_dir}}/reports/top_diagnosis_codes.csv'      (header, delimiter ',');
copy rpt.partd_yearly             to '{{out_dir}}/reports/partd_yearly.csv'             (header, delimiter ',');
copy rpt.cost_concentration       to '{{out_dir}}/reports/cost_concentration.csv'       (header, delimiter ',');
copy rpt.kpi_summary              to '{{out_dir}}/reports/kpi_summary.csv'              (header, delimiter ',');

copy audit.test_results   to '{{out_dir}}/quality/test_results.csv'   (header, delimiter ',');
copy audit.profile_tables to '{{out_dir}}/quality/profile_tables.csv' (header, delimiter ',');
copy audit.profile_checks to '{{out_dir}}/quality/profile_checks.csv' (header, delimiter ',');
copy (select * from audit.profile_columns order by table_name, column_name)
                          to '{{out_dir}}/quality/profile_columns.csv' (header, delimiter ',');
