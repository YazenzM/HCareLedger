-- Star schema: dimensions.
-- Every dimension except dim_date carries an "unknown" member with key -1 so facts never hold a NULL
-- foreign key (Power BI and most BI tools handle -1 members better than blanks).
create schema if not exists mart;

------------------------------------------------------------------------------------------------
-- dim_date: one row per calendar day, 2014-01-01 .. 2025-12-31 (covers every claim and enrollment date)
------------------------------------------------------------------------------------------------
create or replace table mart.dim_date as
select
    date_key(d)                                    as date_key,
    d                                              as date,
    year(d)                                        as year,
    quarter(d)                                     as quarter,
    'Q' || quarter(d)                              as quarter_label,
    month(d)                                       as month,
    strftime(d, '%b')                              as month_short,
    strftime(d, '%B')                              as month_name,
    date_trunc('month', d)::date                   as month_start,
    date_key(date_trunc('month', d)::date)         as month_key,
    strftime(d, '%Y-%m')                           as year_month,
    year(d) * 100 + month(d)                       as year_month_number,
    isodow(d)                                      as day_of_week,
    strftime(d, '%a')                              as day_name,
    d = last_day(d)                                as is_month_end,
    d between window_start() and window_end()      as is_in_reporting_window
from (select unnest(generate_series(date '2014-01-01', date '2025-12-31', interval 1 day))::date as d);

comment on table mart.dim_date is 'Calendar dimension, one row per day from 2014-01-01 to 2025-12-31. Role-plays as service, paid and month dates.';
comment on column mart.dim_date.date_key is 'Primary key, integer YYYYMMDD.';
comment on column mart.dim_date.date is 'Calendar date.';
comment on column mart.dim_date.year is 'Calendar year.';
comment on column mart.dim_date.quarter is 'Calendar quarter, 1-4.';
comment on column mart.dim_date.quarter_label is 'Quarter label, Q1-Q4.';
comment on column mart.dim_date.month is 'Month number, 1-12.';
comment on column mart.dim_date.month_short is 'Month abbreviation (Jan).';
comment on column mart.dim_date.month_name is 'Month name (January).';
comment on column mart.dim_date.day_of_week is 'ISO day of week, 1 = Monday.';
comment on column mart.dim_date.day_name is 'Day abbreviation (Mon).';
comment on column mart.dim_date.is_month_end is 'True on the last day of the month.';
comment on column mart.dim_date.month_start is 'First day of the month containing this date.';
comment on column mart.dim_date.month_key is 'date_key of month_start; facts carry incurred_month_key at this grain.';
comment on column mart.dim_date.year_month is 'Month label, YYYY-MM.';
comment on column mart.dim_date.year_month_number is 'Sortable month number, YYYYMM.';
comment on column mart.dim_date.is_in_reporting_window is 'True from 2015-03-01 to 2023-02-28, the complete months of claims experience.';

------------------------------------------------------------------------------------------------
-- dim_service_type: the eight benefit categories used for PMPM
------------------------------------------------------------------------------------------------
create or replace table mart.dim_service_type as
select * from (values
    (1, 'inpatient',  'Inpatient',     'Part A', 'Facility',     1),
    (2, 'snf',        'SNF',           'Part A', 'Facility',     2),
    (3, 'hha',        'Home Health',   'Part A', 'Facility',     3),
    (4, 'hospice',    'Hospice',       'Part A', 'Facility',     4),
    (5, 'outpatient', 'Outpatient',    'Part B', 'Facility',     5),
    (6, 'carrier',    'Professional',  'Part B', 'Professional', 6),
    (7, 'dme',        'DME',           'Part B', 'Professional', 7),
    (8, 'pde',        'Part D',        'Part D', 'Pharmacy',     8)
) as t(service_type_key, claim_type, service_type, benefit, setting, sort_order);

comment on table mart.dim_service_type is 'Benefit category of a claim line or drug event. Drives PMPM by service type.';
comment on column mart.dim_service_type.service_type_key is 'Primary key.';
comment on column mart.dim_service_type.claim_type is 'Source CMS file: carrier, dme, inpatient, outpatient, snf, hha, hospice, pde.';
comment on column mart.dim_service_type.service_type is 'Reporting label (Inpatient, Outpatient, Professional, ...).';
comment on column mart.dim_service_type.benefit is 'Medicare benefit: Part A, Part B or Part D.';
comment on column mart.dim_service_type.setting is 'Facility, Professional or Pharmacy.';
comment on column mart.dim_service_type.sort_order is 'Display order for reports.';

------------------------------------------------------------------------------------------------
-- dim_beneficiary_year: one row per beneficiary per enrollment year (attributes can change by year)
------------------------------------------------------------------------------------------------
create or replace table mart.dim_beneficiary_year as
with months as (
    select bene_id, year,
           count(*) filter (where has_part_a)          as part_a_months,
           count(*) filter (where has_part_b)          as part_b_months,
           count(*) filter (where has_part_d)          as part_d_months,
           count(*) filter (where is_dual)             as dual_months,
           count(*) filter (where is_medical_eligible) as medical_member_months,
           count(*) filter (where is_rx_eligible)      as rx_member_months
    from stg.v_member_month_eligibility group by 1, 2
)
select
    row_number() over (order by b.bene_id, b.year)::integer as bene_year_key,
    b.bene_id,
    b.year,
    b.birth_date,
    b.death_date,
    b.age_at_end_of_year,
    case when b.age_at_end_of_year < 65 then 'Under 65'
         when b.age_at_end_of_year < 70 then '65-69'
         when b.age_at_end_of_year < 75 then '70-74'
         when b.age_at_end_of_year < 80 then '75-79'
         when b.age_at_end_of_year < 85 then '80-84'
         else '85+' end                                           as age_band,
    case when b.age_at_end_of_year < 65 then 1
         when b.age_at_end_of_year < 70 then 2
         when b.age_at_end_of_year < 75 then 3
         when b.age_at_end_of_year < 80 then 4
         when b.age_at_end_of_year < 85 then 5
         else 6 end                                               as age_band_order,
    b.sex_code,
    case b.sex_code when '1' then 'Male' when '2' then 'Female' else 'Unknown' end as sex,
    b.race_code,
    case b.race_code when '1' then 'White' when '2' then 'Black' when '3' then 'Other' when '4' then 'Asian'
                     when '5' then 'Hispanic' when '6' then 'North American Native' else 'Unknown' end as race,
    b.state_code,
    b.county_code,
    b.orig_entitlement_reason_code,
    case b.orig_entitlement_reason_code when '0' then 'Old age' when '1' then 'Disability'
                                        when '2' then 'ESRD' when '3' then 'Disability and ESRD' else 'Unknown' end as orig_entitlement_reason,
    b.esrd_flag,
    m.part_a_months, m.part_b_months, m.part_d_months, m.dual_months,
    m.dual_months > 0                                             as is_dual_any_month,
    case when m.dual_months > 0 then 'Dual eligible' else 'Medicare only' end as dual_status,
    m.medical_member_months,
    m.rx_member_months
from stg.beneficiary_year b
join months m using (bene_id, year)
union all
select -1, 'UNKNOWN', null, null, null, null, 'Unknown', 7, null, 'Unknown', null, 'Unknown', null, null, null, 'Unknown',
       null, 0, 0, 0, 0, false, 'Unknown', 0, 0;

comment on table mart.dim_beneficiary_year is 'Beneficiary-year dimension: demographics and enrollment summary for one beneficiary in one calendar year. Key -1 = unknown.';
comment on column mart.dim_beneficiary_year.bene_year_key is 'Surrogate primary key.';
comment on column mart.dim_beneficiary_year.bene_id is 'CMS synthetic beneficiary ID (BENE_ID). Natural key together with year.';
comment on column mart.dim_beneficiary_year.year is 'Enrollment reference year.';
comment on column mart.dim_beneficiary_year.birth_date is 'Date of birth (constant across years).';
comment on column mart.dim_beneficiary_year.death_date is 'Date of death. Null for every synthetic beneficiary.';
comment on column mart.dim_beneficiary_year.sex_code is 'SEX_IDENT_CD: 1 = male, 2 = female.';
comment on column mart.dim_beneficiary_year.race_code is 'BENE_RACE_CD: 0-6.';
comment on column mart.dim_beneficiary_year.county_code is 'SSA county code of residence.';
comment on column mart.dim_beneficiary_year.orig_entitlement_reason_code is 'ENTLMT_RSN_ORIG: 0 = old age, 1 = disability, 2 = ESRD, 3 = disability and ESRD.';
comment on column mart.dim_beneficiary_year.is_dual_any_month is 'Dually eligible for Medicaid in at least one month of the year.';
comment on column mart.dim_beneficiary_year.dual_status is 'Dual eligible / Medicare only (label of is_dual_any_month).';
comment on column mart.dim_beneficiary_year.age_band_order is 'Sort order for age_band (1 = Under 65 ... 6 = 85+).';
comment on column mart.dim_beneficiary_year.age_at_end_of_year is 'Age on 31 December of the year (AGE_AT_END_REF_YR).';
comment on column mart.dim_beneficiary_year.age_band is 'Age band: Under 65, 65-69, 70-74, 75-79, 80-84, 85+.';
comment on column mart.dim_beneficiary_year.sex is 'Male / Female from SEX_IDENT_CD.';
comment on column mart.dim_beneficiary_year.race is 'Race from BENE_RACE_CD.';
comment on column mart.dim_beneficiary_year.state_code is 'SSA state code of residence.';
comment on column mart.dim_beneficiary_year.orig_entitlement_reason is 'Original reason for Medicare entitlement: Old age, Disability, ESRD, Disability and ESRD.';
comment on column mart.dim_beneficiary_year.esrd_flag is 'End-stage renal disease indicator.';
comment on column mart.dim_beneficiary_year.part_a_months is 'Months with Part A entitlement, derived from monthly buy-in flags.';
comment on column mart.dim_beneficiary_year.part_b_months is 'Months with Part B entitlement, derived from monthly buy-in flags.';
comment on column mart.dim_beneficiary_year.part_d_months is 'Months enrolled in a Part D contract, derived from monthly contract IDs.';
comment on column mart.dim_beneficiary_year.dual_months is 'Months dually eligible for Medicaid (monthly dual status 01-06, 08).';
comment on column mart.dim_beneficiary_year.medical_member_months is 'Months with Part A and Part B and no HMO; the denominator for medical PMPM.';
comment on column mart.dim_beneficiary_year.rx_member_months is 'Months enrolled in Part D; the denominator for Part D PMPM.';

------------------------------------------------------------------------------------------------
-- dim_provider: every NPI or CCN referenced on a claim or drug event
------------------------------------------------------------------------------------------------
create or replace table mart.dim_provider as
with refs as (
    select facility_ccn as provider_id, 'CCN' as id_type, 'Facility' as role, provider_state_code as state_code, claim_from_date as seen_date
    from stg.claim_line where facility_ccn is not null and is_header_line
    union all
    select billing_npi, 'NPI', 'Billing', provider_state_code, claim_from_date from stg.claim_line where billing_npi is not null and is_header_line
    union all
    select rendering_npi, 'NPI', 'Rendering', provider_state_code, claim_from_date from stg.claim_line where rendering_npi is not null
    union all
    select attending_npi, 'NPI', 'Attending', provider_state_code, claim_from_date from stg.claim_line where attending_npi is not null and is_header_line
    union all
    select prescriber_id, 'NPI', 'Prescriber', null, service_date from stg.drug_event where prescriber_id is not null
)
select
    row_number() over (order by id_type, provider_id)::integer as provider_key,
    provider_id,
    id_type,
    string_agg(distinct role, ', ' order by role)               as roles,
    mode(state_code)                                            as state_code,
    min(seen_date)                                              as first_seen_date,
    max(seen_date)                                              as last_seen_date,
    count(*)                                                    as reference_count
from refs group by provider_id, id_type
union all
select -1, 'UNKNOWN', 'UNKNOWN', 'Unknown', null, null, null, 0;

comment on table mart.dim_provider is 'Providers referenced in claims and drug events: facilities (CCN) and clinicians/organisations (NPI). Synthetic IDs carry no names. Key -1 = unknown.';
comment on column mart.dim_provider.provider_key is 'Surrogate primary key.';
comment on column mart.dim_provider.provider_id is 'NPI (10 digits) or CMS Certification Number (6 characters).';
comment on column mart.dim_provider.id_type is 'NPI or CCN.';
comment on column mart.dim_provider.roles is 'Roles this ID appears in: Attending, Billing, Facility, Prescriber, Rendering.';
comment on column mart.dim_provider.state_code is 'Most frequent provider state on its claims.';
comment on column mart.dim_provider.first_seen_date is 'Earliest service date on which the ID appears.';
comment on column mart.dim_provider.last_seen_date is 'Latest service date on which the ID appears.';
comment on column mart.dim_provider.reference_count is 'Number of claim or drug-event references.';

------------------------------------------------------------------------------------------------
-- dim_diagnosis: ICD-10-CM codes found on claims, described by longest-prefix match to FY2023 ICD-10-CM
------------------------------------------------------------------------------------------------
create or replace table mart.dim_diagnosis as
with codes as (
    select distinct code from (
        select principal_dx_code as code from stg.claim_line
        union all select admitting_dx_code from stg.claim_line
        union all select line_dx_code from stg.claim_line
    ) where code is not null
),
prefixes as (   -- every prefix of length >= 3, so 'T7421X' can fall back to the 'T7421' subcategory
    select code, n, left(code, n) as prefix
    from (select code, unnest(range(3, length(code) + 1)) as n from codes)
),
best as (
    select p.code, i.icd10_code as matched_code, i.long_description, i.is_billable
    from prefixes p join stg.icd10cm i on i.icd10_code = p.prefix
    qualify row_number() over (partition by p.code order by p.n desc) = 1
)
select
    row_number() over (order by c.code)::integer as diagnosis_key,
    c.code                                       as diagnosis_code,
    coalesce(b.long_description, 'Not found in ICD-10-CM FY2023') as diagnosis_description,
    case when b.matched_code = c.code then 'exact'
         when b.matched_code is not null then 'prefix'
         else 'unmatched' end                    as match_type,
    b.matched_code,
    coalesce(b.is_billable and b.matched_code = c.code, false) as is_billable_code,
    left(c.code, 3)                              as category_code,
    coalesce(cat.long_description, 'Unknown category') as category_description,
    ch.chapter_number,
    coalesce(ch.chapter_description, 'Unknown chapter') as chapter_description
from codes c
left join best b using (code)
left join stg.icd10cm cat on cat.icd10_code = left(c.code, 3)
left join stg.icd10cm_chapter ch on left(c.code, 3) between ch.range_start and ch.range_end
union all
select -1, 'UNKNOWN', 'No diagnosis on claim', 'unmatched', null, false, 'UNK', 'Unknown category', null, 'Unknown chapter';

comment on table mart.dim_diagnosis is 'ICD-10-CM diagnosis codes seen on claims. Descriptions come from the FY2023 ICD-10-CM order file by longest-prefix match. Key -1 = no diagnosis.';
comment on column mart.dim_diagnosis.diagnosis_key is 'Surrogate primary key.';
comment on column mart.dim_diagnosis.diagnosis_code is 'ICD-10-CM code as it appears on the claim, no decimal point.';
comment on column mart.dim_diagnosis.diagnosis_description is 'Description of the longest matching ICD-10-CM code or header.';
comment on column mart.dim_diagnosis.match_type is 'exact = code exists in FY2023 ICD-10-CM; prefix = described by a parent header (e.g. a code missing its 7th character); unmatched = no match.';
comment on column mart.dim_diagnosis.matched_code is 'The ICD-10-CM code or header that supplied the description.';
comment on column mart.dim_diagnosis.is_billable_code is 'True when the claim code is itself a billable FY2023 code.';
comment on column mart.dim_diagnosis.category_code is 'Three-character ICD-10-CM category.';
comment on column mart.dim_diagnosis.category_description is 'Description of the three-character category.';
comment on column mart.dim_diagnosis.chapter_number is 'ICD-10-CM chapter, 1-22.';
comment on column mart.dim_diagnosis.chapter_description is 'ICD-10-CM chapter title.';
