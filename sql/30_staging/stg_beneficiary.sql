-- Staging: beneficiary enrollment. One typed row per beneficiary-year, plus a monthly unpivot.
create schema if not exists stg;

create or replace table stg.beneficiary_year as
select
    BENE_ID                               as bene_id,
    _file_year::integer                   as year,
    BENE_ENROLLMT_REF_YR::integer         as enrollment_ref_year,
    parse_dt(BENE_BIRTH_DT)               as birth_date,
    parse_dt(BENE_DEATH_DT)               as death_date,
    AGE_AT_END_REF_YR::integer            as age_at_end_of_year,
    SEX_IDENT_CD                          as sex_code,
    BENE_RACE_CD                          as race_code,
    RTI_RACE_CD                           as rti_race_code,
    STATE_CODE                            as state_code,
    COUNTY_CD                             as county_code,
    ZIP_CD                                as zip_code,
    ENTLMT_RSN_ORIG                       as orig_entitlement_reason_code,
    ENTLMT_RSN_CURR                       as curr_entitlement_reason_code,
    ESRD_IND = 'Y'                        as esrd_flag,
    BENE_HI_CVRAGE_TOT_MONS::integer      as part_a_months_reported,
    BENE_SMI_CVRAGE_TOT_MONS::integer     as part_b_months_reported,
    BENE_HMO_CVRAGE_TOT_MONS::integer     as hmo_months_reported,
    PTD_PLAN_CVRG_MONS::integer           as part_d_months_reported,
    DUAL_ELGBL_MONS::integer              as dual_months_reported
from raw.beneficiary;

-- Monthly enrollment. The annual totals above disagree with the monthly fields for some
-- beneficiary-years (see audit.profile_checks), and claims line up with the monthly buy-in flags,
-- so eligibility is always derived from these monthly values.
create or replace table stg.member_month as
with u as (
    select
        BENE_ID as bene_id,
        _file_year::integer as year,
        unnest(range(1, 13)) as month_num,
        unnest([MDCR_ENTLMT_BUYIN_IND_01, MDCR_ENTLMT_BUYIN_IND_02, MDCR_ENTLMT_BUYIN_IND_03, MDCR_ENTLMT_BUYIN_IND_04,
                MDCR_ENTLMT_BUYIN_IND_05, MDCR_ENTLMT_BUYIN_IND_06, MDCR_ENTLMT_BUYIN_IND_07, MDCR_ENTLMT_BUYIN_IND_08,
                MDCR_ENTLMT_BUYIN_IND_09, MDCR_ENTLMT_BUYIN_IND_10, MDCR_ENTLMT_BUYIN_IND_11, MDCR_ENTLMT_BUYIN_IND_12]) as buyin_code,
        unnest([HMO_IND_01, HMO_IND_02, HMO_IND_03, HMO_IND_04, HMO_IND_05, HMO_IND_06,
                HMO_IND_07, HMO_IND_08, HMO_IND_09, HMO_IND_10, HMO_IND_11, HMO_IND_12]) as hmo_code,
        unnest([PTD_CNTRCT_ID_01, PTD_CNTRCT_ID_02, PTD_CNTRCT_ID_03, PTD_CNTRCT_ID_04, PTD_CNTRCT_ID_05, PTD_CNTRCT_ID_06,
                PTD_CNTRCT_ID_07, PTD_CNTRCT_ID_08, PTD_CNTRCT_ID_09, PTD_CNTRCT_ID_10, PTD_CNTRCT_ID_11, PTD_CNTRCT_ID_12]) as part_d_contract_id,
        unnest([DUAL_STUS_CD_01, DUAL_STUS_CD_02, DUAL_STUS_CD_03, DUAL_STUS_CD_04, DUAL_STUS_CD_05, DUAL_STUS_CD_06,
                DUAL_STUS_CD_07, DUAL_STUS_CD_08, DUAL_STUS_CD_09, DUAL_STUS_CD_10, DUAL_STUS_CD_11, DUAL_STUS_CD_12]) as dual_status_code
    from raw.beneficiary
)
select
    bene_id, year, month_num,
    make_date(year, month_num, 1) as month_start,
    buyin_code, hmo_code, part_d_contract_id, dual_status_code,
    -- Buy-in indicator: 1/A = Part A only, 2/B = Part B only, 3/C = Parts A and B (A-C = state buy-in), 0/null = not entitled.
    coalesce(buyin_code in ('1', '3', 'A', 'C'), false)                                   as has_part_a,
    coalesce(buyin_code in ('2', '3', 'B', 'C'), false)                                   as has_part_b,
    coalesce(buyin_code not in ('0'), false)                                              as is_medicare_enrolled,
    -- HMO indicator: 0/null = fee-for-service; anything else = Medicare Advantage, whose claims are not in FFS files.
    coalesce(hmo_code is not null and hmo_code <> '0', false)                             as has_hmo,
    -- Part D: a 5-character contract ID means enrolled; 0/N/X/* are "not enrolled" placeholders.
    coalesce(length(part_d_contract_id) = 5 and left(part_d_contract_id, 1) not in ('N', 'X', '0', '*'), false) as has_part_d,
    coalesce(dual_status_code in ('01', '02', '03', '04', '05', '06', '08'), false)       as is_dual,
    coalesce(dual_status_code in ('02', '04', '08'), false)                               as is_full_dual
from u;

-- Eligibility rules used everywhere downstream:
--   medical member month = Part A and Part B, not in an HMO (FFS claims are complete only for these months)
--   Part D member month  = enrolled in a Part D contract
create or replace view stg.v_member_month_eligibility as
select *,
       has_part_a and has_part_b and not has_hmo as is_medical_eligible,
       has_part_d                                as is_rx_eligible
from stg.member_month;
