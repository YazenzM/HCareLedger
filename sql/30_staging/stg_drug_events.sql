-- Staging: Part D prescription drug events (one row per PDE_ID).
create schema if not exists stg;

create or replace table stg.drug_event as
select
    PDE_ID                                       as pde_id,
    BENE_ID                                      as bene_id,
    parse_dt(SRVC_DT)                            as service_date,
    parse_dt(PD_DT)                              as paid_date,
    date_trunc('month', parse_dt(SRVC_DT))::date as incurred_month,
    PRSCRBR_ID_QLFYR_CD                          as prescriber_id_qualifier,
    PRSCRBR_ID                                   as prescriber_id,
    PROD_SRVC_ID                                 as ndc,
    PLAN_CNTRCT_REC_ID                           as plan_contract_id,
    PLAN_PBP_REC_NUM                             as plan_pbp_id,
    BRND_GNRC_CD                                 as brand_generic_code,
    try_cast(QTY_DSPNSD_NUM as decimal(14, 3))   as quantity_dispensed,
    try_cast(DAYS_SUPLY_NUM as integer)          as days_supply,
    try_cast(FILL_NUM as integer)                as fill_number,
    DRUG_CVRG_STUS_CD                            as coverage_status_code,
    CTSTRPHC_CVRG_CD                             as catastrophic_coverage_code,
    PHRMCY_SRVC_TYPE_CD                          as pharmacy_service_type_code,
    money(TOT_RX_CST_AMT)                        as total_drug_cost,
    money(CVRD_D_PLAN_PD_AMT)                    as covered_plan_paid_amount,
    money(NCVRD_PLAN_PD_AMT)                     as noncovered_plan_paid_amount,
    (money(CVRD_D_PLAN_PD_AMT) + money(NCVRD_PLAN_PD_AMT))::decimal(18, 2) as plan_paid_amount,
    money(PTNT_PAY_AMT)                          as patient_pay_amount,
    money(LICS_AMT)                              as lics_amount,
    money(OTHR_TROOP_AMT)                        as other_troop_amount,
    money(PLRO_AMT)                              as plro_amount,
    money(GDC_BLW_OOPT_AMT)                      as gross_cost_below_oop_threshold,
    money(GDC_ABV_OOPT_AMT)                      as gross_cost_above_oop_threshold
from raw.pde;
