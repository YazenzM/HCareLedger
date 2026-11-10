-- Step 1 profiling: measure the raw files exactly as CMS shipped them.
-- Outputs:
--   audit.profile_tables   one row per raw table (row counts, keys, date span)
--   audit.profile_columns  one row per raw column (null %, distinct count, min/max) via SUMMARIZE
--   audit.profile_checks   one row per named check (duplicates, nulls, impossible dates, consistency)

create schema if not exists audit;

-- Common shape over the seven claim files so each check is written once.
create or replace view audit.v_raw_claim_lines as
select 'carrier' as table_name, BENE_ID as bene_id, CLM_ID as clm_id, LINE_NUM as line_num,
       CLM_FROM_DT as from_dt, CLM_THRU_DT as thru_dt, null::varchar as admsn_dt, null::varchar as dschrg_dt,
       CLM_PMT_AMT as clm_pmt, LINE_NCH_PMT_AMT as line_pmt from raw.carrier
union all
select 'dme', BENE_ID, CLM_ID, LINE_NUM, CLM_FROM_DT, CLM_THRU_DT, null, null, CLM_PMT_AMT, LINE_NCH_PMT_AMT from raw.dme
union all
select 'inpatient', BENE_ID, CLM_ID, CLM_LINE_NUM, CLM_FROM_DT, CLM_THRU_DT, CLM_ADMSN_DT, NCH_BENE_DSCHRG_DT, CLM_PMT_AMT, null from raw.inpatient
union all
select 'outpatient', BENE_ID, CLM_ID, CLM_LINE_NUM, CLM_FROM_DT, CLM_THRU_DT, null, null, CLM_PMT_AMT, REV_CNTR_PMT_AMT_AMT from raw.outpatient
union all
select 'snf', BENE_ID, CLM_ID, CLM_LINE_NUM, CLM_FROM_DT, CLM_THRU_DT, CLM_ADMSN_DT, NCH_BENE_DSCHRG_DT, CLM_PMT_AMT, null from raw.snf
union all
select 'hha', BENE_ID, CLM_ID, CLM_LINE_NUM, CLM_FROM_DT, CLM_THRU_DT, CLM_ADMSN_DT, null, CLM_PMT_AMT, REV_CNTR_PMT_AMT_AMT from raw.hha
union all
select 'hospice', BENE_ID, CLM_ID, CLM_LINE_NUM, CLM_FROM_DT, CLM_THRU_DT, CLM_HOSPC_START_DT_ID, NCH_BENE_DSCHRG_DT, CLM_PMT_AMT, REV_CNTR_PMT_AMT_AMT from raw.hospice;

-- One row per beneficiary with stable attributes (birth date is constant across years; checked below).
create or replace temp view v_bene as
select BENE_ID as bene_id, min(parse_dt(BENE_BIRTH_DT)) as birth_date, min(parse_dt(BENE_DEATH_DT)) as death_date
from raw.beneficiary group by 1;

------------------------------------------------------------------------------------------------
-- audit.profile_tables
------------------------------------------------------------------------------------------------
create or replace table audit.profile_tables as
with claims as (
    select table_name,
           count(*) as row_count,
           count(distinct clm_id) as distinct_ids,
           count(distinct (clm_id, line_num)) as distinct_grain_keys,
           count(distinct bene_id) as distinct_benes,
           min(parse_dt(from_dt)) as min_service_date,
           max(parse_dt(from_dt)) as max_service_date
    from audit.v_raw_claim_lines group by 1
),
cols as (
    select table_name, count(*) as column_count from duckdb_columns() where schema_name = 'raw' group by 1
)
select c.table_name, 'CLM_ID + line number' as grain, cols.column_count, c.row_count, c.distinct_ids,
       c.distinct_grain_keys, c.row_count - c.distinct_grain_keys as duplicate_grain_rows,
       c.distinct_benes, c.min_service_date, c.max_service_date
from claims c join cols using (table_name)
union all
select 'pde', 'PDE_ID', (select column_count from cols where table_name = 'pde'),
       count(*), count(distinct PDE_ID), count(distinct PDE_ID), count(*) - count(distinct PDE_ID),
       count(distinct BENE_ID), min(parse_dt(SRVC_DT)), max(parse_dt(SRVC_DT))
from raw.pde
union all
select 'beneficiary', 'BENE_ID + reference year', (select column_count from cols where table_name = 'beneficiary') - 2,
       count(*), count(distinct BENE_ID), count(distinct (BENE_ID, _file_year)),
       count(*) - count(distinct (BENE_ID, _file_year)), count(distinct BENE_ID),
       make_date(min(_file_year::int), 1, 1), make_date(max(_file_year::int), 12, 31)
from raw.beneficiary;

------------------------------------------------------------------------------------------------
-- audit.profile_columns: null %, cardinality and range for every raw column
------------------------------------------------------------------------------------------------
create or replace table audit.profile_columns as
select 'beneficiary' as table_name, column_name, count, null_percentage, approx_unique, min, max from (summarize raw.beneficiary)
union all select 'carrier', column_name, count, null_percentage, approx_unique, min, max from (summarize raw.carrier)
union all select 'dme', column_name, count, null_percentage, approx_unique, min, max from (summarize raw.dme)
union all select 'inpatient', column_name, count, null_percentage, approx_unique, min, max from (summarize raw.inpatient)
union all select 'outpatient', column_name, count, null_percentage, approx_unique, min, max from (summarize raw.outpatient)
union all select 'snf', column_name, count, null_percentage, approx_unique, min, max from (summarize raw.snf)
union all select 'hha', column_name, count, null_percentage, approx_unique, min, max from (summarize raw.hha)
union all select 'hospice', column_name, count, null_percentage, approx_unique, min, max from (summarize raw.hospice)
union all select 'pde', column_name, count, null_percentage, approx_unique, min, max from (summarize raw.pde);

------------------------------------------------------------------------------------------------
-- audit.profile_checks: named data-quality checks, long format
------------------------------------------------------------------------------------------------
create or replace table audit.profile_checks as
with
claim_hdr as (   -- one row per claim, with header-consistency diagnostics
    select table_name, clm_id,
           count(distinct bene_id) as n_bene, count(distinct from_dt) as n_from, count(distinct clm_pmt) as n_pmt,
           max(money(clm_pmt)) as clm_pmt, sum(money(line_pmt)) as line_pmt_sum
    from audit.v_raw_claim_lines group by 1, 2
),
id_types as (select clm_id, count(distinct table_name) as n_types from claim_hdr group by 1),
checks as (
    -- duplicates ---------------------------------------------------------------------------
    select table_name, 'duplicates' as category, 'Duplicate claim-line keys (CLM_ID + line number)' as check_name,
           count(*) as rows_checked, count(*) - count(distinct (clm_id, line_num)) as rows_flagged
    from audit.v_raw_claim_lines group by 1
    union all
    select h.table_name, 'duplicates', 'CLM_ID reused by another claim type', count(*), count(*) filter (where i.n_types > 1)
    from claim_hdr h join id_types i using (clm_id) group by 1
    union all
    select 'pde', 'duplicates', 'Duplicate PDE_ID', count(*), count(*) - count(distinct PDE_ID) from raw.pde
    union all
    select 'beneficiary', 'duplicates', 'Duplicate BENE_ID + reference year', count(*), count(*) - count(distinct (BENE_ID, _file_year)) from raw.beneficiary

    -- nulls in key fields -------------------------------------------------------------------
    union all
    select table_name, 'nulls', 'Null BENE_ID, CLM_ID or claim from date', count(*),
           count(*) filter (where bene_id is null or clm_id is null or from_dt is null)
    from audit.v_raw_claim_lines group by 1
    union all
    select 'pde', 'nulls', 'Null PDE_ID, BENE_ID or service date', count(*),
           count(*) filter (where PDE_ID is null or BENE_ID is null or SRVC_DT is null) from raw.pde
    union all
    select 'beneficiary', 'nulls', 'Null BENE_ID or birth date', count(*),
           count(*) filter (where BENE_ID is null or BENE_BIRTH_DT is null) from raw.beneficiary
    union all
    select 'beneficiary', 'nulls', 'Null death date (no deaths recorded)', count(*), count(*) filter (where BENE_DEATH_DT is null) from raw.beneficiary

    -- impossible or out-of-range dates -------------------------------------------------------
    union all
    select table_name, 'dates', 'Unparseable claim from/thru date', count(*),
           count(*) filter (where (from_dt is not null and parse_dt(from_dt) is null) or (thru_dt is not null and parse_dt(thru_dt) is null))
    from audit.v_raw_claim_lines group by 1
    union all
    select table_name, 'dates', 'Claim thru date before from date', count(*),
           count(*) filter (where parse_dt(thru_dt) < parse_dt(from_dt))
    from audit.v_raw_claim_lines group by 1
    union all
    select table_name, 'dates', 'Discharge date before admission date', count(*),
           count(*) filter (where parse_dt(dschrg_dt) < parse_dt(admsn_dt))
    from audit.v_raw_claim_lines where table_name in ('inpatient', 'snf', 'hospice') group by 1
    union all
    select table_name, 'dates', 'Service date outside data period (before 2015 or after Mar-2023)', count(*),
           count(*) filter (where parse_dt(from_dt) < date '2015-01-01' or parse_dt(from_dt) > date '2023-03-31')
    from audit.v_raw_claim_lines group by 1
    union all
    select c.table_name, 'dates', 'Service date before beneficiary birth date', count(*),
           count(*) filter (where parse_dt(c.from_dt) < b.birth_date)
    from audit.v_raw_claim_lines c join v_bene b using (bene_id) group by 1
    union all
    select c.table_name, 'dates', 'Service date after beneficiary death date', count(*),
           count(*) filter (where parse_dt(c.from_dt) > b.death_date)
    from audit.v_raw_claim_lines c join v_bene b using (bene_id) group by 1
    union all
    select 'pde', 'dates', 'Unparseable service or paid date', count(*),
           count(*) filter (where parse_dt(SRVC_DT) is null or (PD_DT is not null and parse_dt(PD_DT) is null)) from raw.pde
    union all
    select 'pde', 'dates', 'Paid date before service date', count(*), count(*) filter (where parse_dt(PD_DT) < parse_dt(SRVC_DT)) from raw.pde
    union all
    select 'pde', 'dates', 'Service date before beneficiary birth date', count(*), count(*) filter (where parse_dt(p.SRVC_DT) < b.birth_date)
    from raw.pde p join v_bene b on b.bene_id = p.BENE_ID
    union all
    select 'beneficiary', 'dates', 'Birth date after end of reference year', count(*),
           count(*) filter (where parse_dt(BENE_BIRTH_DT) > make_date(_file_year::int, 12, 31)) from raw.beneficiary
    union all
    select 'beneficiary', 'dates', 'Enrollment year with no claims coverage (after Mar-2023)', count(*),
           count(*) filter (where _file_year::int > 2023) from raw.beneficiary

    -- referential integrity ---------------------------------------------------------------------
    union all
    select c.table_name, 'referential', 'BENE_ID missing from every beneficiary file', count(*),
           count(*) filter (where b.bene_id is null)
    from audit.v_raw_claim_lines c left join v_bene b using (bene_id) group by 1
    union all
    select c.table_name, 'referential', 'No beneficiary record for the service year', count(*),
           count(*) filter (where y.BENE_ID is null)
    from audit.v_raw_claim_lines c
    left join raw.beneficiary y on y.BENE_ID = c.bene_id and y._file_year::int = year(parse_dt(c.from_dt))
    group by 1
    union all
    select 'pde', 'referential', 'No beneficiary record for the service year', count(*), count(*) filter (where y.BENE_ID is null)
    from raw.pde p left join raw.beneficiary y on y.BENE_ID = p.BENE_ID and y._file_year::int = year(parse_dt(p.SRVC_DT))

    -- internal consistency ----------------------------------------------------------------------
    union all
    select table_name, 'consistency', 'Header fields (bene, from date, payment) vary across lines of one claim', count(*),
           count(*) filter (where n_bene > 1 or n_from > 1 or n_pmt > 1)
    from claim_hdr group by 1
    union all
    select table_name, 'consistency', 'Line payments do not sum to claim payment (claims)', count(*),
           count(*) filter (where abs(line_pmt_sum - clm_pmt) >= 0.01)
    from claim_hdr where table_name in ('carrier', 'dme', 'outpatient', 'hha', 'hospice') group by 1
    union all
    select 'pde', 'consistency', 'Cost components do not sum to total drug cost', count(*),
           count(*) filter (where abs(money(TOT_RX_CST_AMT) - (money(PTNT_PAY_AMT) + money(OTHR_TROOP_AMT) + money(LICS_AMT)
                                  + money(PLRO_AMT) + money(CVRD_D_PLAN_PD_AMT) + money(NCVRD_PLAN_PD_AMT))) >= 0.01)
    from raw.pde
    union all
    select 'beneficiary', 'consistency', 'Part B months total disagrees with monthly buy-in flags', count(*),
           count(*) filter (where BENE_SMI_CVRAGE_TOT_MONS::int <> len(list_filter(
               [MDCR_ENTLMT_BUYIN_IND_01, MDCR_ENTLMT_BUYIN_IND_02, MDCR_ENTLMT_BUYIN_IND_03, MDCR_ENTLMT_BUYIN_IND_04,
                MDCR_ENTLMT_BUYIN_IND_05, MDCR_ENTLMT_BUYIN_IND_06, MDCR_ENTLMT_BUYIN_IND_07, MDCR_ENTLMT_BUYIN_IND_08,
                MDCR_ENTLMT_BUYIN_IND_09, MDCR_ENTLMT_BUYIN_IND_10, MDCR_ENTLMT_BUYIN_IND_11, MDCR_ENTLMT_BUYIN_IND_12],
               lambda x: x in ('2', '3', 'B', 'C'))))
    from raw.beneficiary
    union all
    select 'beneficiary', 'consistency', 'Part D months total disagrees with monthly contract IDs', count(*),
           count(*) filter (where PTD_PLAN_CVRG_MONS::int <> len(list_filter(
               [PTD_CNTRCT_ID_01, PTD_CNTRCT_ID_02, PTD_CNTRCT_ID_03, PTD_CNTRCT_ID_04, PTD_CNTRCT_ID_05, PTD_CNTRCT_ID_06,
                PTD_CNTRCT_ID_07, PTD_CNTRCT_ID_08, PTD_CNTRCT_ID_09, PTD_CNTRCT_ID_10, PTD_CNTRCT_ID_11, PTD_CNTRCT_ID_12],
               lambda x: length(x) = 5 and left(x, 1) not in ('N', 'X', '0', '*'))))
    from raw.beneficiary
    union all
    select 'beneficiary', 'consistency', 'Dual-eligible months total disagrees with monthly dual status codes', count(*),
           count(*) filter (where DUAL_ELGBL_MONS::int <> len(list_filter(
               [DUAL_STUS_CD_01, DUAL_STUS_CD_02, DUAL_STUS_CD_03, DUAL_STUS_CD_04, DUAL_STUS_CD_05, DUAL_STUS_CD_06,
                DUAL_STUS_CD_07, DUAL_STUS_CD_08, DUAL_STUS_CD_09, DUAL_STUS_CD_10, DUAL_STUS_CD_11, DUAL_STUS_CD_12],
               lambda x: x in ('01', '02', '03', '04', '05', '06', '08'))))
    from raw.beneficiary
    union all
    select 'beneficiary', 'consistency', 'Age at end of year disagrees with birth date', count(*),
           count(*) filter (where AGE_AT_END_REF_YR::int <> date_sub('year', parse_dt(BENE_BIRTH_DT), make_date(_file_year::int, 12, 31)))
    from raw.beneficiary
    union all
    select 'beneficiary', 'consistency', 'Birth date, sex or state changes across years (beneficiaries)',
           count(distinct BENE_ID),
           (select count(*) from (select BENE_ID from raw.beneficiary group by 1
                                  having count(distinct BENE_BIRTH_DT) > 1 or count(distinct SEX_IDENT_CD) > 1 or count(distinct STATE_CODE) > 1))
    from raw.beneficiary
)
select table_name, category, check_name, rows_checked, rows_flagged,
       round(100.0 * rows_flagged / nullif(rows_checked, 0), 3) as pct_flagged
from checks
order by category, table_name, check_name;
