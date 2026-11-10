-- Data tests on the star schema. Each test returns rows_tested and rows_failing; the build reports
-- the % of rows failing each test (one of the project's headline measures).
--   severity 'error' = the model is wrong if this fails; 'warn' = known data condition, quantified.
create schema if not exists audit;

create or replace table audit.test_results as
with tests as (
    ------------------------------------------------------------------ primary keys: unique + not null
    select 'unique' as test_type, 'dim_date' as model, 'date_key' as column_name, 'error' as severity,
           'Primary key is unique' as description, count(*) as rows_tested, count(*) - count(distinct date_key) as rows_failing
    from mart.dim_date
    union all select 'unique', 'dim_beneficiary_year', 'bene_year_key', 'error', 'Primary key is unique', count(*), count(*) - count(distinct bene_year_key) from mart.dim_beneficiary_year
    union all select 'unique', 'dim_beneficiary_year', 'bene_id + year', 'error', 'Natural key is unique', count(*), count(*) - count(distinct (bene_id, year)) from mart.dim_beneficiary_year
    union all select 'unique', 'dim_provider', 'provider_key', 'error', 'Primary key is unique', count(*), count(*) - count(distinct provider_key) from mart.dim_provider
    union all select 'unique', 'dim_provider', 'provider_id + id_type', 'error', 'Natural key is unique', count(*), count(*) - count(distinct (provider_id, id_type)) from mart.dim_provider
    union all select 'unique', 'dim_diagnosis', 'diagnosis_key', 'error', 'Primary key is unique', count(*), count(*) - count(distinct diagnosis_key) from mart.dim_diagnosis
    union all select 'unique', 'dim_diagnosis', 'diagnosis_code', 'error', 'Natural key is unique', count(*), count(*) - count(distinct diagnosis_code) from mart.dim_diagnosis
    union all select 'unique', 'dim_service_type', 'service_type_key', 'error', 'Primary key is unique', count(*), count(*) - count(distinct service_type_key) from mart.dim_service_type
    union all select 'unique', 'fct_claim_line', 'claim_line_key', 'error', 'Primary key is unique', count(*), count(*) - count(distinct claim_line_key) from mart.fct_claim_line
    union all select 'unique', 'fct_claim_line', 'claim_id + line_number', 'error', 'Grain is unique', count(*), count(*) - count(distinct (claim_id, line_number)) from mart.fct_claim_line
    union all select 'unique', 'fct_drug_event', 'pde_id', 'error', 'Grain is unique', count(*), count(*) - count(distinct pde_id) from mart.fct_drug_event
    union all select 'unique', 'fct_member_month', 'bene_id + month_key', 'error', 'Grain is unique', count(*), count(*) - count(distinct (bene_id, month_key)) from mart.fct_member_month
    union all select 'unique', 'fct_inpatient_stay', 'stay_key', 'error', 'Primary key is unique', count(*), count(*) - count(distinct stay_key) from mart.fct_inpatient_stay

    ------------------------------------------------------------------ not null
    union all select 'not_null', 'fct_claim_line', 'claim_id', 'error', 'Required field', count(*), count(*) filter (where claim_id is null) from mart.fct_claim_line
    union all select 'not_null', 'fct_claim_line', 'bene_id', 'error', 'Required field', count(*), count(*) filter (where bene_id is null) from mart.fct_claim_line
    union all select 'not_null', 'fct_claim_line', 'from_date_key', 'error', 'Required field', count(*), count(*) filter (where from_date_key is null) from mart.fct_claim_line
    union all select 'not_null', 'fct_claim_line', 'paid_amount', 'error', 'Required field', count(*), count(*) filter (where paid_amount is null) from mart.fct_claim_line
    union all select 'not_null', 'fct_drug_event', 'service_date_key', 'error', 'Required field', count(*), count(*) filter (where service_date_key is null) from mart.fct_drug_event
    union all select 'not_null', 'fct_drug_event', 'total_drug_cost', 'error', 'Required field', count(*), count(*) filter (where total_drug_cost is null or plan_paid_amount is null) from mart.fct_drug_event
    union all select 'not_null', 'fct_inpatient_stay', 'admission/discharge date', 'error', 'Required field', count(*), count(*) filter (where admission_date_key is null or discharge_date_key is null) from mart.fct_inpatient_stay
    union all select 'not_null', 'dim_beneficiary_year', 'birth_date', 'error', 'Required field (excl. unknown member)', count(*), count(*) filter (where birth_date is null) from mart.dim_beneficiary_year where bene_year_key <> -1

    ------------------------------------------------------------------ relationships (foreign keys resolve)
    union all select 'relationship', 'fct_claim_line', 'bene_year_key', 'error', 'FK exists in dim_beneficiary_year', count(*), count(*) filter (where d.bene_year_key is null)
              from mart.fct_claim_line f left join mart.dim_beneficiary_year d using (bene_year_key)
    union all select 'relationship', 'fct_claim_line', 'from_date_key', 'error', 'FK exists in dim_date', count(*), count(*) filter (where d.date_key is null)
              from mart.fct_claim_line f left join mart.dim_date d on d.date_key = f.from_date_key
    union all select 'relationship', 'fct_claim_line', 'incurred_month_key', 'error', 'FK exists in dim_date', count(*), count(*) filter (where d.date_key is null)
              from mart.fct_claim_line f left join mart.dim_date d on d.date_key = f.incurred_month_key
    union all select 'relationship', 'fct_claim_line', 'principal_diagnosis_key', 'error', 'FK exists in dim_diagnosis', count(*), count(*) filter (where d.diagnosis_key is null)
              from mart.fct_claim_line f left join mart.dim_diagnosis d on d.diagnosis_key = f.principal_diagnosis_key
    union all select 'relationship', 'fct_claim_line', 'billing_provider_key', 'error', 'FK exists in dim_provider', count(*), count(*) filter (where d.provider_key is null)
              from mart.fct_claim_line f left join mart.dim_provider d on d.provider_key = f.billing_provider_key
    union all select 'relationship', 'fct_claim_line', 'clinician_provider_key', 'error', 'FK exists in dim_provider', count(*), count(*) filter (where d.provider_key is null)
              from mart.fct_claim_line f left join mart.dim_provider d on d.provider_key = f.clinician_provider_key
    union all select 'relationship', 'fct_claim_line', 'service_type_key', 'error', 'FK exists in dim_service_type', count(*), count(*) filter (where d.service_type_key is null)
              from mart.fct_claim_line f left join mart.dim_service_type d using (service_type_key)
    union all select 'relationship', 'fct_drug_event', 'bene_year_key', 'error', 'FK exists in dim_beneficiary_year', count(*), count(*) filter (where d.bene_year_key is null)
              from mart.fct_drug_event f left join mart.dim_beneficiary_year d using (bene_year_key)
    union all select 'relationship', 'fct_drug_event', 'service_date_key', 'error', 'FK exists in dim_date', count(*), count(*) filter (where d.date_key is null)
              from mart.fct_drug_event f left join mart.dim_date d on d.date_key = f.service_date_key
    union all select 'relationship', 'fct_drug_event', 'prescriber_provider_key', 'error', 'FK exists in dim_provider', count(*), count(*) filter (where d.provider_key is null)
              from mart.fct_drug_event f left join mart.dim_provider d on d.provider_key = f.prescriber_provider_key
    union all select 'relationship', 'fct_member_month', 'bene_year_key', 'error', 'FK exists in dim_beneficiary_year', count(*), count(*) filter (where d.bene_year_key is null)
              from mart.fct_member_month f left join mart.dim_beneficiary_year d using (bene_year_key)
    union all select 'relationship', 'fct_member_month', 'month_key', 'error', 'FK exists in dim_date', count(*), count(*) filter (where d.date_key is null)
              from mart.fct_member_month f left join mart.dim_date d on d.date_key = f.month_key
    union all select 'relationship', 'fct_inpatient_stay', 'principal_diagnosis_key', 'error', 'FK exists in dim_diagnosis', count(*), count(*) filter (where d.diagnosis_key is null)
              from mart.fct_inpatient_stay f left join mart.dim_diagnosis d on d.diagnosis_key = f.principal_diagnosis_key

    ------------------------------------------------------------------ accepted values
    union all select 'accepted_values', 'dim_service_type', 'service_type', 'error', 'In the 8 defined categories', count(*),
              count(*) filter (where service_type not in ('Inpatient', 'SNF', 'Home Health', 'Hospice', 'Outpatient', 'Professional', 'DME', 'Part D')) from mart.dim_service_type
    union all select 'accepted_values', 'dim_beneficiary_year', 'sex_code', 'error', 'In (1, 2)', count(*), count(*) filter (where sex_code not in ('1', '2')) from mart.dim_beneficiary_year where bene_year_key <> -1
    union all select 'accepted_values', 'dim_beneficiary_year', 'race_code', 'error', 'In (0-6)', count(*), count(*) filter (where race_code not in ('0', '1', '2', '3', '4', '5', '6')) from mart.dim_beneficiary_year where bene_year_key <> -1
    union all select 'accepted_values', 'dim_beneficiary_year', 'orig_entitlement_reason_code', 'error', 'In (0-3)', count(*), count(*) filter (where orig_entitlement_reason_code not in ('0', '1', '2', '3')) from mart.dim_beneficiary_year where bene_year_key <> -1
    union all select 'accepted_values', 'stg.member_month', 'buyin_code', 'error', 'In (0, 1, 2, 3, A, B, C) or null', count(*), count(*) filter (where buyin_code not in ('0', '1', '2', '3', 'A', 'B', 'C')) from stg.member_month
    union all select 'accepted_values', 'fct_drug_event', 'brand_generic_code', 'error', 'In (B, G)', count(*), count(*) filter (where brand_generic_code not in ('B', 'G') or brand_generic_code is null) from mart.fct_drug_event
    union all select 'accepted_values', 'fct_inpatient_stay', 'admission_type_code', 'error', 'In (1-5, 9)', count(*), count(*) filter (where admission_type_code not in ('1', '2', '3', '4', '5', '9')) from mart.fct_inpatient_stay
    union all select 'accepted_values', 'dim_diagnosis', 'match_type', 'error', 'In (exact, prefix, unmatched)', count(*), count(*) filter (where match_type not in ('exact', 'prefix', 'unmatched')) from mart.dim_diagnosis

    ------------------------------------------------------------------ ranges
    union all select 'range', 'fct_claim_line', 'paid_amount', 'error', 'Paid amount >= 0', count(*), count(*) filter (where paid_amount < 0) from mart.fct_claim_line
    union all select 'range', 'fct_drug_event', 'total_drug_cost', 'error', 'Drug cost >= 0', count(*), count(*) filter (where total_drug_cost < 0 or plan_paid_amount < 0) from mart.fct_drug_event
    union all select 'range', 'fct_drug_event', 'days_supply', 'error', 'Days supply 1-365', count(*), count(*) filter (where days_supply not between 1 and 365) from mart.fct_drug_event
    union all select 'range', 'fct_inpatient_stay', 'length_of_stay', 'error', 'Length of stay >= 0', count(*), count(*) filter (where length_of_stay < 0) from mart.fct_inpatient_stay
    union all select 'range', 'dim_beneficiary_year', 'age_at_end_of_year', 'error', 'Age 0-120', count(*), count(*) filter (where age_at_end_of_year not between 0 and 120) from mart.dim_beneficiary_year where bene_year_key <> -1
    union all select 'range', 'fct_claim_line', 'thru_date_key', 'error', 'Thru date >= from date', count(*), count(*) filter (where thru_date_key < from_date_key) from mart.fct_claim_line

    ------------------------------------------------------------------ reconciliation to source
    union all
    select 'reconciliation', 'fct_claim_line', 'paid_amount', 'error', 'Per-claim SUM(paid_amount) equals CMS header payment (claims)',
           count(*), count(*) filter (where abs(f.paid - s.header_paid) >= 0.01)
    from (select claim_id, sum(paid_amount) as paid from mart.fct_claim_line group by 1) f
    join (select claim_id, max(claim_paid_amount) as header_paid from stg.claim_line group by 1) s using (claim_id)
    union all
    select 'reconciliation', 'fct_claim_line', 'row count', 'error', 'Every raw claim line lands in the fact (raw lines)',
           (select count(*) from raw.carrier) + (select count(*) from raw.dme) + (select count(*) from raw.inpatient) + (select count(*) from raw.outpatient)
             + (select count(*) from raw.snf) + (select count(*) from raw.hha) + (select count(*) from raw.hospice),
           abs(((select count(*) from raw.carrier) + (select count(*) from raw.dme) + (select count(*) from raw.inpatient) + (select count(*) from raw.outpatient)
             + (select count(*) from raw.snf) + (select count(*) from raw.hha) + (select count(*) from raw.hospice)) - (select count(*) from mart.fct_claim_line))
    union all
    select 'reconciliation', 'fct_drug_event', 'total_drug_cost', 'error', 'Gross cost = patient + other TrOOP + LICS + PLRO + plan paid',
           count(*), count(*) filter (where abs(total_drug_cost - (patient_pay_amount + other_troop_amount + lics_amount + plro_amount + plan_paid_amount)) >= 0.01)
    from mart.fct_drug_event
    union all
    select 'reconciliation', 'fct_inpatient_stay', 'claim_count', 'error', 'Every inpatient claim is in exactly one stay (claims)',
           (select count(distinct claim_id) from stg.claim_line where claim_type = 'inpatient'),
           abs((select count(distinct claim_id) from stg.claim_line where claim_type = 'inpatient') - (select sum(claim_count) from mart.fct_inpatient_stay))

    ------------------------------------------------------------------ documentation
    union all select 'documentation', 'mart.*', 'comment', 'error', 'Every star-schema column has a data-dictionary description (columns)',
              count(*), count(*) filter (where comment is null or comment = '') from duckdb_columns() where schema_name = 'mart'

    ------------------------------------------------------------------ known data conditions (warn, quantified)
    union all select 'business_rule', 'fct_claim_line', 'is_medical_eligible_month', 'warn', 'In-window claim lines incurred in a month without Part A + B (excluded from PMPM)',
              count(*), count(*) filter (where not is_medical_eligible_month) from mart.fct_claim_line where is_in_reporting_window
    union all select 'business_rule', 'fct_drug_event', 'is_rx_eligible_month', 'warn', 'In-window fills in a month without Part D enrollment (excluded from Part D PMPM)',
              count(*), count(*) filter (where not is_rx_eligible_month) from mart.fct_drug_event where is_in_reporting_window
    union all select 'business_rule', 'fct_claim_line', 'bene_year_key', 'warn', 'Lines mapped to the unknown beneficiary-year (-1)',
              count(*), count(*) filter (where bene_year_key = -1) from mart.fct_claim_line
    union all select 'business_rule', 'fct_claim_line', 'clinician_provider_key', 'warn', 'Lines with no rendering or attending NPI (-1)',
              count(*), count(*) filter (where clinician_provider_key = -1) from mart.fct_claim_line
    union all select 'business_rule', 'dim_diagnosis', 'match_type', 'warn', 'Diagnosis codes not found exactly in FY2023 ICD-10-CM',
              count(*), count(*) filter (where match_type <> 'exact') from mart.dim_diagnosis where diagnosis_key <> -1
    union all select 'business_rule', 'fct_claim_line', 'principal_diagnosis_key', 'warn', 'Claim lines whose principal diagnosis has no ICD-10-CM description',
              count(*), count(*) filter (where d.match_type = 'unmatched') from mart.fct_claim_line f join mart.dim_diagnosis d on d.diagnosis_key = f.principal_diagnosis_key
)
select
    row_number() over (order by case severity when 'error' then 0 else 1 end, test_type, model, column_name) as test_id,
    test_type, model, column_name, severity, description, rows_tested, rows_failing,
    round(100.0 * rows_failing / nullif(rows_tested, 0), 4) as pct_failing,
    case when rows_failing = 0 then 'pass' when severity = 'error' then 'FAIL' else 'warn' end as status
from tests;
