-- Step 3 metrics. Every table here is computed only from the star schema (mart.*), so the same numbers
-- can be reproduced in Power BI (DAX) and Excel (Power Query + pivot).
--
-- Conventions used throughout:
--   * Reporting window Mar-2015 .. Feb-2023 (complete months of claims).
--   * Medical numerators include only claim lines incurred in a medical member month (Part A + B, no HMO);
--     Part D numerators only fills in a Part D member month. Numerator and denominator always match.
--   * Medical cost = Medicare paid amount. Part D cost = plan paid (covered + non-covered).
--   * Incurred month = claim from-date month (fill month for Part D).
create schema if not exists rpt;

------------------------------------------------------------------------------------------------
-- Monthly PMPM by service type (long format; the Excel Power Query source)
------------------------------------------------------------------------------------------------
create or replace table rpt.pmpm_monthly as
with months as (
    select month_key,
           sum(medical_member_month) as medical_member_months,
           sum(rx_member_month)      as rx_member_months
    from mart.fct_member_month where is_in_reporting_window group by 1
),
paid as (
    select incurred_month_key as month_key, service_type_key,
           sum(paid_amount) as paid_amount, sum(is_header_line::integer) as claim_count
    from mart.fct_claim_line where is_in_reporting_window and is_medical_eligible_month group by 1, 2
    union all
    select incurred_month_key, service_type_key, sum(plan_paid_amount), count(*)
    from mart.fct_drug_event where is_in_reporting_window and is_rx_eligible_month group by 1, 2
)
select
    d.month_start,
    d.year,
    d.month,
    d.year_month,
    st.service_type,
    st.benefit,
    st.sort_order,
    case when st.benefit = 'Part D' then m.rx_member_months else m.medical_member_months end as member_months,
    coalesce(p.paid_amount, 0)::decimal(18, 2) as paid_amount,
    coalesce(p.claim_count, 0)                 as claim_count,
    round(coalesce(p.paid_amount, 0) / nullif(case when st.benefit = 'Part D' then m.rx_member_months else m.medical_member_months end, 0), 2) as pmpm
from months m
join mart.dim_date d on d.date_key = m.month_key
cross join mart.dim_service_type st
left join paid p on p.month_key = m.month_key and p.service_type_key = st.service_type_key
order by d.month_start, st.sort_order;

------------------------------------------------------------------------------------------------
-- PMPM by year (headline measure) - per service type plus total medical
------------------------------------------------------------------------------------------------
create or replace table rpt.pmpm_yearly as
with by_type as (
    select year, service_type, benefit, sort_order,
           count(*) as months_in_window,
           sum(member_months) as member_months,
           sum(paid_amount)   as paid_amount,
           sum(claim_count)   as claim_count
    from rpt.pmpm_monthly group by all
),
total_medical as (
    select year, 'Total Medical' as service_type, 'Part A + B' as benefit, 9 as sort_order,
           max(months_in_window) as months_in_window,
           max(member_months) filter (where benefit <> 'Part D') as member_months,
           sum(paid_amount) filter (where benefit <> 'Part D')   as paid_amount,
           sum(claim_count) filter (where benefit <> 'Part D')   as claim_count
    from by_type group by 1
)
select year, service_type, benefit, sort_order, months_in_window, months_in_window < 12 as is_partial_year,
       member_months, paid_amount::decimal(18, 2) as paid_amount, claim_count,
       round(paid_amount / nullif(member_months, 0), 2) as pmpm
from (select * from by_type union all select * from total_medical)
order by year, sort_order;

------------------------------------------------------------------------------------------------
-- Utilization by year: admissions, days and visits per 1,000 members
-- (per 1,000 = count / member months * 12,000). Same-day stays count as 1 inpatient day.
------------------------------------------------------------------------------------------------
create or replace table rpt.utilization_yearly as
with mm as (
    select d.year, sum(f.medical_member_month) as member_months
    from mart.fct_member_month f join mart.dim_date d on d.date_key = f.month_key
    where f.is_in_reporting_window group by 1
),
ip as (
    select d.year, count(*) as admissions, sum(greatest(s.length_of_stay, 1)) as inpatient_days, sum(s.paid_amount) as inpatient_paid
    from mart.fct_inpatient_stay s join mart.dim_date d on d.date_key = s.admission_date_key
    where s.is_admission_in_window and s.is_medical_eligible_month group by 1
),
other as (
    select d.year,
           sum(f.is_header_line::integer) filter (where st.claim_type = 'outpatient') as outpatient_visits,
           sum(f.is_header_line::integer) filter (where st.claim_type = 'carrier')    as professional_claims,
           sum(f.is_header_line::integer) filter (where st.claim_type = 'snf')        as snf_claims,
           sum(f.is_header_line::integer) filter (where st.claim_type = 'hha')        as home_health_claims
    from mart.fct_claim_line f
    join mart.dim_service_type st using (service_type_key)
    join mart.dim_date d on d.date_key = f.incurred_month_key
    where f.is_in_reporting_window and f.is_medical_eligible_month group by 1
)
select
    mm.year,
    mm.member_months,
    round(mm.member_months / 12.0, 1)                               as average_members,
    ip.admissions,
    round(ip.admissions * 12000.0 / mm.member_months, 1)            as admissions_per_1000,
    ip.inpatient_days,
    round(ip.inpatient_days * 12000.0 / mm.member_months, 1)        as inpatient_days_per_1000,
    round(ip.inpatient_days * 1.0 / ip.admissions, 2)               as average_length_of_stay,
    round(ip.inpatient_paid / ip.admissions, 2)                     as paid_per_admission,
    other.outpatient_visits,
    round(other.outpatient_visits * 12000.0 / mm.member_months, 1)  as outpatient_visits_per_1000,
    other.professional_claims,
    round(other.professional_claims * 12000.0 / mm.member_months, 1) as professional_claims_per_1000,
    round(other.snf_claims * 12000.0 / mm.member_months, 1)         as snf_claims_per_1000,
    round(other.home_health_claims * 12000.0 / mm.member_months, 1) as home_health_claims_per_1000
from mm left join ip using (year) left join other using (year)
order by year;

------------------------------------------------------------------------------------------------
-- 30-day readmission rate by discharge year, and overall (headline measure)
------------------------------------------------------------------------------------------------
create or replace table rpt.readmission_yearly as
select
    case when grouping(d.year) = 1 then 'All years' else d.year::varchar end  as period,
    d.year                                                                   as discharge_year,
    count(*)                                                                 as index_stays,
    sum(s.has_readmission_30d::integer)                                      as readmissions_30d,
    round(100.0 * avg(s.has_readmission_30d::integer), 2)                    as readmission_rate_pct,
    sum(s.has_unplanned_readmission_30d::integer)                            as unplanned_readmissions_30d,
    round(100.0 * avg(s.has_unplanned_readmission_30d::integer), 2)          as unplanned_readmission_rate_pct,
    round(avg(s.days_to_readmission), 1)                                     as avg_days_to_readmission
from mart.fct_inpatient_stay s
join mart.dim_date d on d.date_key = s.discharge_date_key
where s.is_index_eligible
group by grouping sets ((d.year), ())
order by d.year nulls last;

-- Readmission rate by member segment, full window (for the readmissions page)
create or replace table rpt.readmission_by_segment as
select 'Age band' as segment_type, b.age_band as segment, count(*) as index_stays,
       round(100.0 * avg(s.has_readmission_30d::integer), 2) as readmission_rate_pct,
       round(100.0 * avg(s.has_unplanned_readmission_30d::integer), 2) as unplanned_readmission_rate_pct
from mart.fct_inpatient_stay s join mart.dim_beneficiary_year b using (bene_year_key)
where s.is_index_eligible group by all
union all
select 'Dual status', case when b.is_dual_any_month then 'Dual eligible' else 'Medicare only' end, count(*),
       round(100.0 * avg(s.has_readmission_30d::integer), 2), round(100.0 * avg(s.has_unplanned_readmission_30d::integer), 2)
from mart.fct_inpatient_stay s join mart.dim_beneficiary_year b using (bene_year_key)
where s.is_index_eligible group by all
union all
select 'Index admission type', s.admission_type, count(*),
       round(100.0 * avg(s.has_readmission_30d::integer), 2), round(100.0 * avg(s.has_unplanned_readmission_30d::integer), 2)
from mart.fct_inpatient_stay s
where s.is_index_eligible group by all
order by segment_type, segment;

------------------------------------------------------------------------------------------------
-- Top diagnoses by cost (principal diagnosis on the claim; medical paid, full window)
------------------------------------------------------------------------------------------------
create or replace table rpt.top_diagnosis_categories as
with base as (
    select d.category_code, d.category_description, d.chapter_description,
           sum(f.paid_amount) as paid_amount, sum(f.is_header_line::integer) as claim_count, count(distinct f.bene_id) as members
    from mart.fct_claim_line f join mart.dim_diagnosis d on d.diagnosis_key = f.principal_diagnosis_key
    where f.is_in_reporting_window and f.is_medical_eligible_month
    group by all
)
select rank() over (order by paid_amount desc) as cost_rank, category_code, category_description, chapter_description,
       paid_amount, round(100.0 * paid_amount / sum(paid_amount) over (), 2) as pct_of_medical_paid,
       claim_count, members, round(paid_amount / nullif(claim_count, 0), 2) as paid_per_claim
from base
qualify cost_rank <= 25
order by cost_rank;

create or replace table rpt.top_diagnosis_codes as
with base as (
    select d.diagnosis_code, d.diagnosis_description, d.match_type, d.category_description,
           sum(f.paid_amount) as paid_amount, sum(f.is_header_line::integer) as claim_count, count(distinct f.bene_id) as members
    from mart.fct_claim_line f join mart.dim_diagnosis d on d.diagnosis_key = f.principal_diagnosis_key
    where f.is_in_reporting_window and f.is_medical_eligible_month
    group by all
)
select rank() over (order by paid_amount desc) as cost_rank, diagnosis_code, diagnosis_description, match_type, category_description,
       paid_amount, round(100.0 * paid_amount / sum(paid_amount) over (), 2) as pct_of_medical_paid,
       claim_count, members, round(paid_amount / nullif(claim_count, 0), 2) as paid_per_claim
from base
qualify cost_rank <= 25
order by cost_rank;

------------------------------------------------------------------------------------------------
-- Part D spend per member, by year
-- Per member per year uses average enrolled members (Part D member months / 12), so partial years
-- (2015 = 10 months, 2023 = 2 months) are annualised consistently.
------------------------------------------------------------------------------------------------
create or replace table rpt.partd_yearly as
with mm as (
    select d.year, sum(f.rx_member_month) as rx_member_months,
           count(distinct f.bene_id) filter (where f.rx_member_month = 1) as enrolled_members
    from mart.fct_member_month f join mart.dim_date d on d.date_key = f.month_key
    where f.is_in_reporting_window group by 1
),
rx as (
    select d.year, count(*) as fills, count(distinct f.bene_id) as utilizing_members,
           sum(f.total_drug_cost) as gross_drug_cost, sum(f.plan_paid_amount) as plan_paid,
           sum(f.patient_pay_amount) as patient_pay, sum(f.lics_amount) as lics_paid,
           avg((f.brand_generic_code = 'G')::integer) as generic_rate
    from mart.fct_drug_event f join mart.dim_date d on d.date_key = f.incurred_month_key
    where f.is_in_reporting_window and f.is_rx_eligible_month group by 1
)
select
    mm.year,
    mm.rx_member_months,
    round(mm.rx_member_months / 12.0, 1)                               as average_enrolled_members,
    mm.enrolled_members,
    rx.utilizing_members,
    rx.fills,
    rx.gross_drug_cost,
    rx.plan_paid,
    rx.patient_pay,
    rx.lics_paid,
    round(rx.plan_paid / mm.rx_member_months, 2)                       as plan_paid_pmpm,
    round(rx.plan_paid / (mm.rx_member_months / 12.0), 2)              as plan_paid_per_member_per_year,
    round(rx.gross_drug_cost / (mm.rx_member_months / 12.0), 2)        as gross_cost_per_member_per_year,
    round(rx.fills * 12000.0 / mm.rx_member_months, 1)                 as fills_per_1000,
    round(rx.gross_drug_cost / rx.fills, 2)                            as gross_cost_per_fill,
    round(100.0 * rx.generic_rate, 1)                                  as generic_dispensing_rate_pct
from mm join rx using (year)
order by year;

------------------------------------------------------------------------------------------------
-- Cost concentration: share of total spend (medical paid + Part D plan paid) from the top 1/5/10/20%
-- of members (headline measure: top 5%). Population = every member with >= 1 medical member month in
-- the period, including members with zero spend.
------------------------------------------------------------------------------------------------
create or replace table rpt.cost_concentration as
with pop as (
    select d.year, f.bene_id
    from mart.fct_member_month f join mart.dim_date d on d.date_key = f.month_key
    where f.is_in_reporting_window and f.medical_member_month = 1 group by 1, 2
),
med as (
    select d.year, f.bene_id, sum(f.paid_amount) as paid
    from mart.fct_claim_line f join mart.dim_date d on d.date_key = f.incurred_month_key
    where f.is_in_reporting_window and f.is_medical_eligible_month group by 1, 2
),
rx as (
    select d.year, f.bene_id, sum(f.plan_paid_amount) as paid
    from mart.fct_drug_event f join mart.dim_date d on d.date_key = f.incurred_month_key
    where f.is_in_reporting_window and f.is_rx_eligible_month group by 1, 2
),
member_year as (
    select p.year, p.bene_id, coalesce(med.paid, 0) as medical_paid, coalesce(rx.paid, 0) as rx_paid
    from pop p left join med using (year, bene_id) left join rx using (year, bene_id)
),
member_period as (   -- each calendar year, plus the full window as one period
    select year::varchar as period, year, bene_id, medical_paid, rx_paid from member_year
    union all
    select 'All years', null, bene_id, sum(medical_paid), sum(rx_paid) from member_year group by bene_id
),
ranked as (
    select *, medical_paid + rx_paid as total_paid,
           row_number() over (partition by period order by medical_paid + rx_paid desc, bene_id) as rn,
           row_number() over (partition by period order by medical_paid desc, bene_id)           as rn_med,
           count(*) over (partition by period) as n
    from member_period
)
select
    period,
    any_value(year)                                                                   as year,
    -- 2015 has 10 months and 2023 has 2; "All years" pools members with different exposure lengths.
    -- Compare complete calendar years only.
    coalesce(any_value(year) not between 2016 and 2022, true)                         as is_partial_or_pooled,
    any_value(n)                                                                      as members,
    sum(total_paid)::decimal(18, 2)                                                   as total_paid,
    ceil(0.05 * any_value(n))::integer                                                as top_5pct_member_count,
    round(100.0 * sum(total_paid) filter (where rn <= ceil(0.01 * n)) / sum(total_paid), 2) as top_1pct_share,
    round(100.0 * sum(total_paid) filter (where rn <= ceil(0.05 * n)) / sum(total_paid), 2) as top_5pct_share,
    round(100.0 * sum(total_paid) filter (where rn <= ceil(0.10 * n)) / sum(total_paid), 2) as top_10pct_share,
    round(100.0 * sum(total_paid) filter (where rn <= ceil(0.20 * n)) / sum(total_paid), 2) as top_20pct_share,
    round(100.0 * sum(total_paid) filter (where rn > ceil(0.50 * n)) / sum(total_paid), 2)  as bottom_50pct_share,
    round(100.0 * sum(medical_paid) filter (where rn_med <= ceil(0.05 * n)) / sum(medical_paid), 2) as top_5pct_share_medical_only,
    min(total_paid) filter (where rn <= ceil(0.05 * n))::decimal(18, 2)               as top_5pct_threshold_spend,
    round(100.0 * count(*) filter (where total_paid = 0) / any_value(n), 2)           as pct_members_zero_spend
from ranked
group by period
order by year nulls last;

------------------------------------------------------------------------------------------------
-- KPI summary: headline numbers for the full window and the last complete year
------------------------------------------------------------------------------------------------
create or replace table rpt.kpi_summary as
with window_pmpm as (
    select service_type, sum(member_months) as mm, sum(paid_amount) as paid
    from rpt.pmpm_yearly where service_type in ('Total Medical', 'Part D') group by 1
)
select * from (
    select 1 as sort_order, 'Medical member months' as metric, 'Mar-2015 to Feb-2023' as period,
           (select mm from window_pmpm where service_type = 'Total Medical')::double as value, 'member months' as unit
    union all select 2, 'Medical PMPM (Medicare paid)', 'Mar-2015 to Feb-2023',
           round((select paid / mm from window_pmpm where service_type = 'Total Medical'), 2), 'USD'
    union all select 3, 'Medical PMPM (Medicare paid)', '2022',
           (select pmpm from rpt.pmpm_yearly where year = 2022 and service_type = 'Total Medical'), 'USD'
    union all select 4, 'Part D plan paid PMPM', 'Mar-2015 to Feb-2023',
           round((select paid / mm from window_pmpm where service_type = 'Part D'), 2), 'USD'
    union all select 5, 'Part D plan paid per member per year', '2022',
           (select plan_paid_per_member_per_year from rpt.partd_yearly where year = 2022), 'USD'
    union all select 6, 'Inpatient admissions per 1,000', '2022',
           (select admissions_per_1000 from rpt.utilization_yearly where year = 2022), 'per 1,000 members'
    union all select 7, '30-day all-cause readmission rate', 'All years',
           (select readmission_rate_pct from rpt.readmission_yearly where period = 'All years'), '%'
    union all select 8, '30-day unplanned readmission rate', 'All years',
           (select unplanned_readmission_rate_pct from rpt.readmission_yearly where period = 'All years'), '%'
    union all select 9, 'Share of spend from top 5% of members', '2022',
           (select top_5pct_share from rpt.cost_concentration where period = '2022'), '%'
    union all select 10, 'Error-severity data tests passing', 'Build',
           (select round(100.0 * avg((status = 'pass')::integer), 1) from audit.test_results where severity = 'error'), '%'
    union all select 11, 'Warning tests (quantified data conditions)', 'Build',
           (select count(*) from audit.test_results where status = 'warn'), 'tests'
)
order by sort_order;
