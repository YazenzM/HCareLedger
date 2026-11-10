-- Star schema: facts.
--   fct_claim_line     one row per medical claim line (7 claim types)
--   fct_drug_event     one row per Part D prescription drug event
--   fct_member_month   one row per beneficiary per enrolled month (PMPM denominator)
--   fct_inpatient_stay one row per acute inpatient stay after merging overlapping/transfer claims
create schema if not exists mart;

------------------------------------------------------------------------------------------------
-- fct_member_month
------------------------------------------------------------------------------------------------
create or replace table mart.fct_member_month as
select
    row_number() over (order by m.bene_id, m.month_start)::bigint as member_month_key,
    b.bene_year_key,
    m.bene_id,
    date_key(m.month_start)                  as month_key,
    m.has_part_a,
    m.has_part_b,
    m.has_part_d,
    m.has_hmo,
    m.is_dual,
    m.is_full_dual,
    m.is_medical_eligible::integer           as medical_member_month,
    m.is_rx_eligible::integer                as rx_member_month,
    m.month_start between window_start() and window_end() as is_in_reporting_window
from stg.v_member_month_eligibility m
join mart.dim_beneficiary_year b on b.bene_id = m.bene_id and b.year = m.year
where m.is_medicare_enrolled;

comment on table mart.fct_member_month is 'Periodic snapshot: one row per beneficiary per month enrolled in Medicare. Sum medical_member_month or rx_member_month to get PMPM denominators.';
comment on column mart.fct_member_month.member_month_key is 'Surrogate primary key.';
comment on column mart.fct_member_month.bene_year_key is 'FK to dim_beneficiary_year.';
comment on column mart.fct_member_month.bene_id is 'Beneficiary ID (degenerate, for distinct counts).';
comment on column mart.fct_member_month.month_key is 'FK to dim_date (first day of the month).';
comment on column mart.fct_member_month.has_part_a is 'Entitled to Part A this month.';
comment on column mart.fct_member_month.has_part_b is 'Entitled to Part B this month.';
comment on column mart.fct_member_month.has_part_d is 'Enrolled in a Part D contract this month.';
comment on column mart.fct_member_month.has_hmo is 'Enrolled in Medicare Advantage this month (never true in the synthetic data).';
comment on column mart.fct_member_month.is_dual is 'Dually eligible for Medicaid this month.';
comment on column mart.fct_member_month.is_full_dual is 'Full-benefit dual (status 02, 04, 08).';
comment on column mart.fct_member_month.medical_member_month is '1 when Part A + Part B + no HMO; medical PMPM denominator.';
comment on column mart.fct_member_month.rx_member_month is '1 when enrolled in Part D; Part D PMPM denominator.';
comment on column mart.fct_member_month.is_in_reporting_window is 'Month falls in Mar-2015 .. Feb-2023.';

------------------------------------------------------------------------------------------------
-- fct_claim_line
------------------------------------------------------------------------------------------------
create or replace table mart.fct_claim_line as
select
    row_number() over (order by c.claim_type, c.claim_id, c.line_number)::bigint as claim_line_key,
    c.claim_id,
    c.line_number,
    st.service_type_key,
    coalesce(b.bene_year_key, -1)                    as bene_year_key,
    c.bene_id,
    date_key(c.claim_from_date)                      as from_date_key,
    date_key(c.claim_thru_date)                      as thru_date_key,
    date_key(c.incurred_month)                       as incurred_month_key,
    coalesce(dx.diagnosis_key, -1)                   as principal_diagnosis_key,
    coalesce(bp.provider_key, -1)                    as billing_provider_key,
    coalesce(cp.provider_key, -1)                    as clinician_provider_key,
    c.hcpcs_code,
    c.revenue_center_code,
    c.place_of_service_code,
    c.units,
    c.paid_amount,
    c.charge_amount,
    c.allowed_amount,
    c.is_header_line,
    coalesce(e.is_medical_eligible, false)           as is_medical_eligible_month,
    c.claim_from_date between window_start() and window_end() as is_in_reporting_window
from stg.claim_line c
join mart.dim_service_type st on st.claim_type = c.claim_type
left join mart.dim_beneficiary_year b on b.bene_id = c.bene_id and b.year = year(c.claim_from_date)
left join mart.dim_diagnosis dx on dx.diagnosis_code = c.principal_dx_code
left join mart.dim_provider bp
       on bp.provider_id = coalesce(c.facility_ccn, c.billing_npi)
      and bp.id_type = case when c.facility_ccn is not null then 'CCN' else 'NPI' end
left join mart.dim_provider cp on cp.provider_id = coalesce(c.rendering_npi, c.attending_npi) and cp.id_type = 'NPI'
left join stg.v_member_month_eligibility e on e.bene_id = c.bene_id and e.month_start = c.incurred_month;

comment on table mart.fct_claim_line is 'One row per medical claim line across inpatient, outpatient, SNF, home health, hospice, professional (carrier) and DME claims. SUM(paid_amount) over whole claims equals CMS header payments.';
comment on column mart.fct_claim_line.claim_line_key is 'Surrogate primary key.';
comment on column mart.fct_claim_line.claim_id is 'CMS claim ID (CLM_ID), degenerate dimension. Unique across claim types.';
comment on column mart.fct_claim_line.line_number is 'Line number within the claim (LINE_NUM or CLM_LINE_NUM).';
comment on column mart.fct_claim_line.service_type_key is 'FK to dim_service_type.';
comment on column mart.fct_claim_line.bene_year_key is 'FK to dim_beneficiary_year for the year of the claim from date; -1 when no enrollment record exists.';
comment on column mart.fct_claim_line.bene_id is 'Beneficiary ID (degenerate, for distinct member counts).';
comment on column mart.fct_claim_line.from_date_key is 'FK to dim_date: claim from date (min across lines).';
comment on column mart.fct_claim_line.thru_date_key is 'FK to dim_date: claim thru date (max across lines).';
comment on column mart.fct_claim_line.incurred_month_key is 'FK to dim_date: first day of the claim from-date month. Used for PMPM.';
comment on column mart.fct_claim_line.principal_diagnosis_key is 'FK to dim_diagnosis: claim principal diagnosis.';
comment on column mart.fct_claim_line.billing_provider_key is 'FK to dim_provider: facility CCN for institutional claims, billing NPI for professional/DME.';
comment on column mart.fct_claim_line.clinician_provider_key is 'FK to dim_provider: rendering NPI, else attending NPI.';
comment on column mart.fct_claim_line.hcpcs_code is 'HCPCS/CPT procedure code on the line.';
comment on column mart.fct_claim_line.revenue_center_code is 'Revenue center code (institutional claims only).';
comment on column mart.fct_claim_line.place_of_service_code is 'Place of service (professional and DME only).';
comment on column mart.fct_claim_line.units is 'Service units on the line.';
comment on column mart.fct_claim_line.paid_amount is 'Medicare paid amount. Professional/DME: line payment. Institutional: claim header payment on the first line, 0 on other lines.';
comment on column mart.fct_claim_line.charge_amount is 'Submitted charge on the line (null for inpatient).';
comment on column mart.fct_claim_line.allowed_amount is 'Allowed amount (professional and DME only).';
comment on column mart.fct_claim_line.is_header_line is 'True for the first line of each claim. SUM of this = claim count.';
comment on column mart.fct_claim_line.is_medical_eligible_month is 'Member had Part A + B and no HMO in the incurred month. PMPM numerators include only these lines.';
comment on column mart.fct_claim_line.is_in_reporting_window is 'Claim from date in Mar-2015 .. Feb-2023.';

------------------------------------------------------------------------------------------------
-- fct_drug_event
------------------------------------------------------------------------------------------------
create or replace table mart.fct_drug_event as
select
    row_number() over (order by d.pde_id)::bigint    as drug_event_key,
    d.pde_id,
    st.service_type_key,
    coalesce(b.bene_year_key, -1)                    as bene_year_key,
    d.bene_id,
    date_key(d.service_date)                         as service_date_key,
    date_key(d.paid_date)                            as paid_date_key,
    date_key(d.incurred_month)                       as incurred_month_key,
    coalesce(p.provider_key, -1)                     as prescriber_provider_key,
    d.ndc,
    d.brand_generic_code,
    case d.brand_generic_code when 'B' then 'Brand' when 'G' then 'Generic' else 'Unknown' end as brand_generic,
    d.quantity_dispensed,
    d.days_supply,
    d.fill_number,
    d.total_drug_cost,
    d.plan_paid_amount,
    d.covered_plan_paid_amount,
    d.noncovered_plan_paid_amount,
    d.patient_pay_amount,
    d.lics_amount,
    d.other_troop_amount,
    d.plro_amount,
    coalesce(e.is_rx_eligible, false)                as is_rx_eligible_month,
    d.service_date between window_start() and window_end() as is_in_reporting_window
from stg.drug_event d
join mart.dim_service_type st on st.claim_type = 'pde'
left join mart.dim_beneficiary_year b on b.bene_id = d.bene_id and b.year = year(d.service_date)
left join mart.dim_provider p on p.provider_id = d.prescriber_id and p.id_type = 'NPI'
left join stg.v_member_month_eligibility e on e.bene_id = d.bene_id and e.month_start = d.incurred_month;

comment on table mart.fct_drug_event is 'One row per Part D prescription drug event (fill).';
comment on column mart.fct_drug_event.drug_event_key is 'Surrogate primary key.';
comment on column mart.fct_drug_event.pde_id is 'CMS PDE ID, degenerate dimension.';
comment on column mart.fct_drug_event.service_type_key is 'FK to dim_service_type (always Part D).';
comment on column mart.fct_drug_event.bene_year_key is 'FK to dim_beneficiary_year for the service year.';
comment on column mart.fct_drug_event.bene_id is 'Beneficiary ID (degenerate).';
comment on column mart.fct_drug_event.service_date_key is 'FK to dim_date: date of fill.';
comment on column mart.fct_drug_event.paid_date_key is 'FK to dim_date: date the plan paid.';
comment on column mart.fct_drug_event.incurred_month_key is 'FK to dim_date: first day of the fill month.';
comment on column mart.fct_drug_event.prescriber_provider_key is 'FK to dim_provider: prescriber NPI.';
comment on column mart.fct_drug_event.ndc is '11-digit National Drug Code (PROD_SRVC_ID).';
comment on column mart.fct_drug_event.brand_generic_code is 'BRND_GNRC_CD: B = brand, G = generic.';
comment on column mart.fct_drug_event.brand_generic is 'Brand or Generic.';
comment on column mart.fct_drug_event.covered_plan_paid_amount is 'Plan paid for covered Part D drugs (CVRD_D_PLAN_PD_AMT).';
comment on column mart.fct_drug_event.noncovered_plan_paid_amount is 'Plan paid for supplemental, non-Part D drugs (NCVRD_PLAN_PD_AMT).';
comment on column mart.fct_drug_event.other_troop_amount is 'Other payer amounts that count toward true out-of-pocket (OTHR_TROOP_AMT).';
comment on column mart.fct_drug_event.plro_amount is 'Patient liability reduction due to other payer (PLRO_AMT).';
comment on column mart.fct_drug_event.quantity_dispensed is 'Quantity dispensed.';
comment on column mart.fct_drug_event.days_supply is 'Days supply.';
comment on column mart.fct_drug_event.fill_number is 'Fill number (0 = original fill).';
comment on column mart.fct_drug_event.total_drug_cost is 'Gross drug cost (TOT_RX_CST_AMT) = patient pay + other TrOOP + LICS + PLRO + plan paid.';
comment on column mart.fct_drug_event.plan_paid_amount is 'Covered + non-covered plan paid amount. Part D PMPM numerator.';
comment on column mart.fct_drug_event.patient_pay_amount is 'Beneficiary cost sharing.';
comment on column mart.fct_drug_event.lics_amount is 'Low-income cost-sharing subsidy.';
comment on column mart.fct_drug_event.is_rx_eligible_month is 'Member was enrolled in Part D in the fill month.';
comment on column mart.fct_drug_event.is_in_reporting_window is 'Fill date in Mar-2015 .. Feb-2023.';

------------------------------------------------------------------------------------------------
-- fct_inpatient_stay: acute inpatient stays and 30-day readmission flags
--
-- Method (simplified from the CMS Hospital-Wide Readmission measure):
--   1. One row per inpatient claim (header line).
--   2. Claims for the same beneficiary are merged into one stay when the admission is on or before
--      the latest discharge so far (overlapping claims and same-day transfers are one continuous stay).
--   3. A stay is an eligible index stay if it was discharged alive, not transferred and not against
--      medical advice (status 20/02/07 excluded) and discharge falls in the reporting window at least
--      30 days before its end, so every index stay has a full 30-day follow-up.
--   4. A readmission is any later stay admitted 1-30 days after the index discharge.
--      Planned-readmission proxy: readmissions with admission type 3 (elective) are counted separately
--      and excluded from the unplanned rate. The synthetic data has no procedure-based planned logic.
------------------------------------------------------------------------------------------------
create or replace table mart.fct_inpatient_stay as
with claims as (
    select claim_id, bene_id, admission_date, discharge_date, claim_paid_amount as paid_amount,
           principal_dx_code, admission_type_code, discharge_status_code, drg_code, facility_ccn
    from stg.claim_line
    where claim_type = 'inpatient' and is_header_line
),
ordered as (
    select *,
           max(discharge_date) over (partition by bene_id order by admission_date, discharge_date, claim_id
                                     rows between unbounded preceding and 1 preceding) as prior_max_discharge
    from claims
),
grouped as (
    select *,
           sum(case when prior_max_discharge is null or admission_date > prior_max_discharge then 1 else 0 end)
               over (partition by bene_id order by admission_date, discharge_date, claim_id rows unbounded preceding) as stay_seq
    from ordered
),
stays as (
    select bene_id, stay_seq,
           min(admission_date)                         as admission_date,
           max(discharge_date)                         as discharge_date,
           count(*)                                    as claim_count,
           sum(paid_amount)                            as paid_amount,
           arg_min(claim_id, admission_date)           as first_claim_id,
           arg_min(principal_dx_code, admission_date)  as principal_dx_code,
           arg_min(admission_type_code, admission_date) as admission_type_code,
           arg_max(discharge_status_code, discharge_date) as discharge_status_code,
           arg_min(drg_code, admission_date)           as drg_code,
           arg_min(facility_ccn, admission_date)       as facility_ccn
    from grouped group by bene_id, stay_seq
),
readmits as (
    select i.bene_id, i.stay_seq,
           min(r.admission_date - i.discharge_date)                                        as days_to_readmission,
           min(r.admission_date - i.discharge_date) filter (where r.admission_type_code <> '3') as days_to_unplanned_readmission
    from stays i
    join stays r on r.bene_id = i.bene_id
                and r.admission_date between i.discharge_date + 1 and i.discharge_date + 30
    group by 1, 2
)
select
    row_number() over (order by s.bene_id, s.stay_seq)::bigint as stay_key,
    s.bene_id,
    s.stay_seq,
    coalesce(b.bene_year_key, -1)                     as bene_year_key,
    date_key(s.admission_date)                        as admission_date_key,
    date_key(s.discharge_date)                        as discharge_date_key,
    s.discharge_date - s.admission_date               as length_of_stay,
    s.claim_count,
    s.paid_amount,
    s.first_claim_id,
    coalesce(dx.diagnosis_key, -1)                    as principal_diagnosis_key,
    coalesce(p.provider_key, -1)                      as facility_provider_key,
    s.drg_code,
    s.admission_type_code,
    case s.admission_type_code when '1' then 'Emergency' when '2' then 'Urgent' when '3' then 'Elective'
                               when '4' then 'Newborn' when '5' then 'Trauma' else 'Unknown' end as admission_type,
    s.discharge_status_code,
    coalesce(e.is_medical_eligible, false)            as is_medical_eligible_month,
    s.admission_date between window_start() and window_end() as is_admission_in_window,
    (s.discharge_status_code not in ('20', '02', '07')
        and s.discharge_date between window_start() and window_end() - 30) as is_index_eligible,
    r.days_to_readmission is not null                 as has_readmission_30d,
    r.days_to_unplanned_readmission is not null       as has_unplanned_readmission_30d,
    r.days_to_readmission,
    r.days_to_unplanned_readmission
from stays s
left join readmits r using (bene_id, stay_seq)
left join mart.dim_beneficiary_year b on b.bene_id = s.bene_id and b.year = year(s.admission_date)
left join mart.dim_diagnosis dx on dx.diagnosis_code = s.principal_dx_code
left join mart.dim_provider p on p.provider_id = s.facility_ccn and p.id_type = 'CCN'
left join stg.v_member_month_eligibility e on e.bene_id = s.bene_id and e.month_start = date_trunc('month', s.admission_date)::date;

comment on table mart.fct_inpatient_stay is 'One row per acute inpatient stay. Overlapping and same-day-transfer claims are merged. Carries 30-day readmission flags for index stays.';
comment on column mart.fct_inpatient_stay.stay_key is 'Surrogate primary key.';
comment on column mart.fct_inpatient_stay.bene_id is 'Beneficiary ID (degenerate).';
comment on column mart.fct_inpatient_stay.drg_code is 'MS-DRG on the first claim of the stay.';
comment on column mart.fct_inpatient_stay.admission_type_code is 'CLM_IP_ADMSN_TYPE_CD: 1 emergency, 2 urgent, 3 elective, 4 newborn, 5 trauma.';
comment on column mart.fct_inpatient_stay.stay_seq is 'Stay sequence number within the beneficiary.';
comment on column mart.fct_inpatient_stay.bene_year_key is 'FK to dim_beneficiary_year for the admission year.';
comment on column mart.fct_inpatient_stay.admission_date_key is 'FK to dim_date: admission date.';
comment on column mart.fct_inpatient_stay.discharge_date_key is 'FK to dim_date: discharge date.';
comment on column mart.fct_inpatient_stay.length_of_stay is 'Discharge date minus admission date, in days (0 = same-day).';
comment on column mart.fct_inpatient_stay.claim_count is 'Inpatient claims merged into the stay.';
comment on column mart.fct_inpatient_stay.paid_amount is 'Sum of claim header payments for the stay.';
comment on column mart.fct_inpatient_stay.first_claim_id is 'CLM_ID of the first claim in the stay.';
comment on column mart.fct_inpatient_stay.principal_diagnosis_key is 'FK to dim_diagnosis: principal diagnosis of the first claim.';
comment on column mart.fct_inpatient_stay.facility_provider_key is 'FK to dim_provider: admitting facility CCN.';
comment on column mart.fct_inpatient_stay.admission_type is 'Emergency, Urgent, Elective, Newborn, Trauma. Elective readmissions are treated as planned.';
comment on column mart.fct_inpatient_stay.discharge_status_code is 'Patient discharge status (01 = home; all synthetic stays are 01).';
comment on column mart.fct_inpatient_stay.is_medical_eligible_month is 'Member had Part A + B in the admission month; admissions per 1,000 count only these.';
comment on column mart.fct_inpatient_stay.is_admission_in_window is 'Admission date in Mar-2015 .. Feb-2023.';
comment on column mart.fct_inpatient_stay.is_index_eligible is 'Counts in the readmission denominator: discharged alive, not transferred or AMA, discharged at least 30 days before the window ends.';
comment on column mart.fct_inpatient_stay.has_readmission_30d is 'Any stay admitted 1-30 days after this discharge.';
comment on column mart.fct_inpatient_stay.has_unplanned_readmission_30d is 'A non-elective stay admitted 1-30 days after this discharge.';
comment on column mart.fct_inpatient_stay.days_to_readmission is 'Days from discharge to the next admission within 30 days.';
comment on column mart.fct_inpatient_stay.days_to_unplanned_readmission is 'Days from discharge to the next non-elective admission within 30 days.';
