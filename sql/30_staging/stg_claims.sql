-- Staging: medical claims. Seven CMS claim files are conformed into one claim-line table.
--
-- Payment rule (from audit.profile_checks):
--   * Carrier (professional) and DME line payments reconcile exactly to the claim header,
--     so line payment is used as-is.
--   * Institutional files (inpatient, outpatient, SNF, HHA, hospice) do not reconcile:
--     inpatient/SNF have no line payment at all and outpatient/HHA/hospice line sums are off
--     by up to 2x. The header payment (CLM_PMT_AMT) is the authoritative amount, so it is
--     placed on the claim's first line and the other lines carry 0.
--   Either way, SUM(paid_amount) over any set of whole claims equals the sum of header payments.
--
-- Header dates: 24 DME claims have lines whose from-dates differ by a day, so claim from/thru
-- dates are normalised to the claim-wide min/max. Every claim then falls in exactly one month.
create schema if not exists stg;

create or replace table stg.claim_line as
with lines as (
    -- Professional (Part B carrier) ---------------------------------------------------------------
    select 'carrier' as claim_type, CLM_ID as claim_id, LINE_NUM::integer as line_number, BENE_ID as bene_id,
           parse_dt(CLM_FROM_DT) as line_from_date, parse_dt(CLM_THRU_DT) as line_thru_date,
           parse_dt(NCH_WKLY_PROC_DT) as processed_date,
           null::date as admission_date, null::date as discharge_date,
           money(CLM_PMT_AMT) as claim_paid_amount, money(LINE_NCH_PMT_AMT) as line_paid_amount_reported,
           money(LINE_SBMTD_CHRG_AMT) as charge_amount, money(LINE_ALOWD_CHRG_AMT) as allowed_amount,
           PRNCPAL_DGNS_CD as principal_dx_code, null::varchar as admitting_dx_code, LINE_ICD_DGNS_CD as line_dx_code,
           HCPCS_CD as hcpcs_code, HCPCS_1ST_MDFR_CD as hcpcs_modifier_1, null::varchar as revenue_center_code,
           LINE_PLACE_OF_SRVC_CD as place_of_service_code, try_cast(LINE_SRVC_CNT as decimal(12, 3)) as units,
           BETOS_CD as betos_code, null::varchar as drg_code,
           null::varchar as admission_type_code, null::varchar as admission_source_code, null::varchar as discharge_status_code,
           null::integer as utilization_day_count,
           null::varchar as facility_ccn, CARR_CLM_BLG_NPI_NUM as billing_npi, PRF_PHYSN_NPI as rendering_npi,
           null::varchar as attending_npi, RFR_PHYSN_NPI as referring_npi,
           PRVDR_STATE_CD as provider_state_code, CARR_CLM_PMT_DNL_CD as payment_denial_code
    from raw.carrier
    union all
    -- Durable medical equipment ---------------------------------------------------------------
    select 'dme', CLM_ID, LINE_NUM::integer, BENE_ID,
           parse_dt(CLM_FROM_DT), parse_dt(CLM_THRU_DT), parse_dt(NCH_WKLY_PROC_DT), null, null,
           money(CLM_PMT_AMT), money(LINE_NCH_PMT_AMT), money(LINE_SBMTD_CHRG_AMT), money(LINE_ALOWD_CHRG_AMT),
           PRNCPAL_DGNS_CD, null, null,
           HCPCS_CD, HCPCS_1ST_MDFR_CD, null, LINE_PLACE_OF_SRVC_CD, try_cast(LINE_SRVC_CNT as decimal(12, 3)),
           BETOS_CD, null, null, null, null, null,
           null, PRVDR_NPI, null, null, RFR_PHYSN_NPI,
           PRVDR_STATE_CD, CARR_CLM_PMT_DNL_CD
    from raw.dme
    union all
    -- Inpatient (Part A) -------------------------------------------------------------------------
    select 'inpatient', CLM_ID, CLM_LINE_NUM::integer, BENE_ID,
           parse_dt(CLM_FROM_DT), parse_dt(CLM_THRU_DT), parse_dt(NCH_WKLY_PROC_DT),
           parse_dt(CLM_ADMSN_DT), parse_dt(NCH_BENE_DSCHRG_DT),
           money(CLM_PMT_AMT), null, null, null,
           PRNCPAL_DGNS_CD, ADMTG_DGNS_CD, null,
           HCPCS_CD, null, REV_CNTR, null, null,
           null, CLM_DRG_CD, CLM_IP_ADMSN_TYPE_CD, CLM_SRC_IP_ADMSN_CD, lpad(PTNT_DSCHRG_STUS_CD, 2, '0'),
           try_cast(CLM_UTLZTN_DAY_CNT as integer),
           PRVDR_NUM, ORG_NPI_NUM, null, AT_PHYSN_NPI, null,
           PRVDR_STATE_CD, CLM_MDCR_NON_PMT_RSN_CD
    from raw.inpatient
    union all
    -- Outpatient facility (Part B) -----------------------------------------------------------------
    select 'outpatient', CLM_ID, CLM_LINE_NUM::integer, BENE_ID,
           parse_dt(CLM_FROM_DT), parse_dt(CLM_THRU_DT), parse_dt(NCH_WKLY_PROC_DT), null, null,
           money(CLM_PMT_AMT), money(REV_CNTR_PMT_AMT_AMT), money(REV_CNTR_TOT_CHRG_AMT), null,
           PRNCPAL_DGNS_CD, null, null,
           HCPCS_CD, HCPCS_1ST_MDFR_CD, REV_CNTR, null, try_cast(REV_CNTR_UNIT_CNT as decimal(12, 3)),
           null, null, null, null, lpad(PTNT_DSCHRG_STUS_CD, 2, '0'), null,
           PRVDR_NUM, ORG_NPI_NUM, RNDRNG_PHYSN_NPI, AT_PHYSN_NPI, null,
           PRVDR_STATE_CD, CLM_MDCR_NON_PMT_RSN_CD
    from raw.outpatient
    union all
    -- Skilled nursing facility (Part A) -----------------------------------------------------------
    select 'snf', CLM_ID, CLM_LINE_NUM::integer, BENE_ID,
           parse_dt(CLM_FROM_DT), parse_dt(CLM_THRU_DT), parse_dt(NCH_WKLY_PROC_DT),
           parse_dt(CLM_ADMSN_DT), parse_dt(NCH_BENE_DSCHRG_DT),
           money(CLM_PMT_AMT), null, money(REV_CNTR_TOT_CHRG_AMT), null,
           PRNCPAL_DGNS_CD, ADMTG_DGNS_CD, null,
           HCPCS_CD, null, REV_CNTR, null, try_cast(REV_CNTR_UNIT_CNT as decimal(12, 3)),
           null, CLM_DRG_CD, CLM_IP_ADMSN_TYPE_CD, CLM_SRC_IP_ADMSN_CD, lpad(PTNT_DSCHRG_STUS_CD, 2, '0'),
           try_cast(CLM_UTLZTN_DAY_CNT as integer),
           PRVDR_NUM, ORG_NPI_NUM, RNDRNG_PHYSN_NPI, AT_PHYSN_NPI, null,
           PRVDR_STATE_CD, CLM_MDCR_NON_PMT_RSN_CD
    from raw.snf
    union all
    -- Home health ---------------------------------------------------------------------------------
    select 'hha', CLM_ID, CLM_LINE_NUM::integer, BENE_ID,
           parse_dt(CLM_FROM_DT), parse_dt(CLM_THRU_DT), parse_dt(NCH_WKLY_PROC_DT),
           parse_dt(CLM_ADMSN_DT), null,
           money(CLM_PMT_AMT), money(REV_CNTR_PMT_AMT_AMT), money(REV_CNTR_TOT_CHRG_AMT), null,
           PRNCPAL_DGNS_CD, null, null,
           HCPCS_CD, HCPCS_1ST_MDFR_CD, REV_CNTR, null, try_cast(REV_CNTR_UNIT_CNT as decimal(12, 3)),
           null, null, null, null, lpad(PTNT_DSCHRG_STUS_CD, 2, '0'), null,
           PRVDR_NUM, ORG_NPI_NUM, RNDRNG_PHYSN_NPI, AT_PHYSN_NPI, null,
           PRVDR_STATE_CD, CLM_MDCR_NON_PMT_RSN_CD
    from raw.hha
    union all
    -- Hospice -------------------------------------------------------------------------------------
    select 'hospice', CLM_ID, CLM_LINE_NUM::integer, BENE_ID,
           parse_dt(CLM_FROM_DT), parse_dt(CLM_THRU_DT), parse_dt(NCH_WKLY_PROC_DT),
           parse_dt(CLM_HOSPC_START_DT_ID), parse_dt(NCH_BENE_DSCHRG_DT),
           money(CLM_PMT_AMT), money(REV_CNTR_PMT_AMT_AMT), money(REV_CNTR_TOT_CHRG_AMT), null,
           PRNCPAL_DGNS_CD, null, null,
           HCPCS_CD, HCPCS_1ST_MDFR_CD, REV_CNTR, null, try_cast(REV_CNTR_UNIT_CNT as decimal(12, 3)),
           null, null, null, null, lpad(PTNT_DSCHRG_STUS_CD, 2, '0'),
           try_cast(CLM_UTLZTN_DAY_CNT as integer),
           PRVDR_NUM, ORG_NPI_NUM, RNDRNG_PHYSN_NPI, AT_PHYSN_NPI, null,
           PRVDR_STATE_CD, CLM_MDCR_NON_PMT_RSN_CD
    from raw.hospice
),
framed as (
    select *,
           min(line_from_date) over w as claim_from_date,
           max(line_thru_date) over w as claim_thru_date,
           line_number = min(line_number) over w as is_header_line
    from lines
    window w as (partition by claim_type, claim_id)
)
select
    claim_type, claim_id, line_number, bene_id,
    claim_from_date, claim_thru_date, line_from_date, line_thru_date, processed_date,
    admission_date, discharge_date,
    date_trunc('month', claim_from_date)::date as incurred_month,
    is_header_line,
    claim_paid_amount,
    line_paid_amount_reported,
    case when claim_type in ('carrier', 'dme') then coalesce(line_paid_amount_reported, 0)
         when is_header_line then coalesce(claim_paid_amount, 0)
         else 0 end::decimal(18, 2) as paid_amount,
    charge_amount, allowed_amount,
    principal_dx_code, admitting_dx_code, line_dx_code,
    hcpcs_code, hcpcs_modifier_1, revenue_center_code, place_of_service_code, units, betos_code,
    drg_code, admission_type_code, admission_source_code, discharge_status_code, utilization_day_count,
    facility_ccn, billing_npi, rendering_npi, attending_npi, referring_npi,
    provider_state_code, payment_denial_code
from framed;
