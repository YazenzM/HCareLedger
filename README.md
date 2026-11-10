# HCareLedger: Medicare claims data mart

A claims data mart built on the **CMS Synthetic Medicare Claims PUFs (May 2023)**: raw-file profiling, a tested star schema,
and the cost and utilization measures a health plan's actuarial or finance team reports each month:
PMPM by service type, admissions per 1,000, 30-day readmissions, top diagnoses by cost, Part D spend per member and cost concentration.

> **Synthetic data.** CMS states that the synthetic files' payment amounts and utilization do not match real Medicare.
> Every number here demonstrates a method; none is a fact about Medicare.

## Headline measures

| Measure | Result | Where |
| --- | --- | --- |
| % of rows failing each test | 54 of 54 error-severity tests pass at 0%; 6 warning tests quantify known data conditions (0.0003% - 6.3%) | [docs/data_quality.md](docs/data_quality.md) |
| Medical PMPM by year | $1,345 - $1,665 (2016-2022); $1,665 in 2022 | [docs/results.md](docs/results.md#pmpm-by-year-and-service-type) |
| 30-day readmission rate | 30.8% all-cause, 29.4% unplanned (19,532 index stays) | [docs/results.md](docs/results.md#30-day-readmissions) |
| Share of spend from the top 5% of members | 45.4% in 2022 (range 41-49% across 2016-2022) | [docs/results.md](docs/results.md#cost-concentration) |

## Data

| File | Rows | Grain |
| --- | --- | --- |
| Carrier (professional) | 1,121,004 | claim line |
| Outpatient | 575,092 | claim line (revenue center) |
| Part D events | 515,520 | drug fill |
| DME | 103,828 | claim line |
| Inpatient | 58,066 | claim line (revenue center) |
| SNF / Hospice / Home health | 12,548 / 12,107 / 6,215 | claim line |
| Beneficiary summary 2015-2025 | 86,917 | beneficiary-year (10,000 beneficiaries) |

Pipe-delimited files from [data.cms.gov](https://data.cms.gov/collection/synthetic-medicare-enrollment-fee-for-service-claims-and-prescription-drug-event),
linked by `BENE_ID`. Claims run from March 2015 to early March 2023. Diagnosis descriptions come from the FY2023 ICD-10-CM order file (CDC/NCHS).

## Run it

Requires Python 3.12. The whole build takes about 40 seconds.

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe -I pipeline\download.py   # ~230 MB download (~1 GB extracted) into data/raw/
.venv\Scripts\python.exe -I pipeline\build.py      # raw -> profile -> staging -> star schema -> tests -> reports -> exports
.venv\Scripts\python.exe -I pipeline\docs.py       # regenerates docs/ from the warehouse
```

`build.py 40 50` reruns only the steps whose folder starts with those numbers. The build exits non-zero if any error-severity test fails.

Then generate the BI deliverables from the built warehouse:

```powershell
.venv\Scripts\python.exe -I pipeline\powerbi.py    # powerbi/HCareLedger.pbip  (open in Power BI Desktop, Refresh)
.venv\Scripts\python.exe -I pipeline\excel.py      # excel/HCareLedger_PMPM_Budget.xlsx
```

## Deliverables

| | What | Guide |
| --- | --- | --- |
| Power BI | `powerbi/HCareLedger.pbip`: TMDL semantic model on the star schema (32 DAX measures, 19 relationships) and a PBIR report with **Cost Trend**, **Utilization** and **Readmissions** pages | [docs/powerbi.md](docs/powerbi.md) |
| Excel | `excel/HCareLedger_PMPM_Budget.xlsx`: Power Query `qPMPM_Monthly` loading the monthly PMPM table, a PivotTable by service type and year, an XLOOKUP budget-vs-actual variance sheet, and a checks sheet | [docs/excel.md](docs/excel.md) |
| Results | Every metric table with method notes | [docs/results.md](docs/results.md) |
| Data quality | Raw-file profile and the % of rows failing each test | [docs/data_quality.md](docs/data_quality.md) |
| Data dictionary | Every star-schema table and column | [docs/data_dictionary.md](docs/data_dictionary.md) |

Power BI Desktop and Excel were not available on the build machine. The report JSON validates against Microsoft's
PBIR schemas, the TMDL round-trips through Microsoft's Tabular Object Model, and the workbook passes the Open XML SDK
validator with zero errors. Each guide lists check values to confirm after the first open.

## How it is built

```
data/raw/*.csv  ──►  raw.*      all-VARCHAR copy of every file (lossless, profiled as delivered)
                     audit.*    profile_tables / profile_columns / profile_checks
                ──►  stg.*      typed, conformed: one claim-line table for 7 claim types, monthly enrollment
                ──►  mart.*     star schema (4 facts, 5 dimensions) + data-dictionary comments
                     audit.test_results   60 tests: keys, nulls, relationships, accepted values, ranges, reconciliation
                ──►  rpt.*      PMPM, utilization, readmissions, top diagnoses, Part D, cost concentration
                ──►  outputs/   Parquet for Power BI, CSV for Excel and review
```

All SQL is in [`sql/`](sql/), run in folder order by [`pipeline/build.py`](pipeline/build.py) against DuckDB.

### Star schema

| Facts | Dimensions |
| --- | --- |
| `fct_claim_line`: 1.89M medical claim lines | `dim_beneficiary_year`: demographics and enrollment per beneficiary-year |
| `fct_drug_event`: 516K Part D fills | `dim_provider`: NPIs and facility CCNs |
| `fct_member_month`: 953K enrolled months (the PMPM denominator) | `dim_diagnosis`: ICD-10-CM code, category and chapter |
| `fct_inpatient_stay`: 19.8K merged acute stays with readmission flags | `dim_date`, `dim_service_type` |

Full column-level documentation: [docs/data_dictionary.md](docs/data_dictionary.md) (generated from the database, and a test fails if any column is undocumented).

### Method decisions that change the numbers

These came out of profiling (step 1) and are each enforced by a test:

1. **Institutional line payments don't reconcile to the claim header** (outpatient lines sum to 75% of header payment, home health to 200%).
   Professional and DME line payments do. The header payment is used for institutional claims, placed on the first line,
   and a reconciliation test checks per-claim totals against CMS to the cent.
2. **Eligibility comes from the monthly enrollment fields, not the annual totals.** The annual Part B, Part D and dual-month totals disagree with
   the monthly flags for 3-24% of beneficiary-years; the monthly flags match the claims (no professional claim falls in a Part-A-only month).
3. **Numerators and denominators match.** Medical PMPM counts only claims incurred in Part A + B, non-HMO months, over exactly those member months.
   Claims in other months ($52M, 2.3% of lines) are excluded and reported by a warning test.
4. **Reporting window March 2015 - February 2023**, the complete months of claims. The 2024-2025 enrollment files have no claims.
5. **Readmissions:** overlapping and same-day-transfer claims merge into one stay. Index stays need a full 30-day follow-up.
   Elective readmissions are excluded from the unplanned rate as a planned-readmission proxy.
6. **Diagnosis descriptions by longest-prefix match**: 314 of 336 codes match ICD-10-CM exactly. 19 synthetic codes are missing their 7th character and roll up to their parent.
   3 don't match: 2 of them are ICD-10-PCS procedure codes sitting in a diagnosis field.

### Synthetic-data artifacts to keep in mind

- Pregnancy supervision (Z34) is the #2 diagnosis category by cost in a Medicare population.
- 78% of inpatient claims have zero utilization days, average length of stay is under 2 days, and every discharge status is "home".
- Outpatient is about two-thirds of medical PMPM. The 30-day readmission rate is about double typical Medicare rates.
- No beneficiary has a death date or an HMO month.

## Roadmap

- [x] 1. Load and profile every file
- [x] 2. Star schema, tests, data dictionary
- [x] 3. Member months, PMPM, admits/1,000, readmissions, top diagnoses, Part D per member, cost concentration
- [x] 4. Power BI: cost trend, utilization and readmissions pages with DAX measures (open in Desktop to confirm the check values)
- [x] 5. Excel for finance: Power Query monthly PMPM, pivot by service type, XLOOKUP budget-vs-actual variance (open in Excel to confirm the checks)
- [ ] 6. Stretch: compare with the [Tuva Project](https://github.com/tuva-health/tuva) PMPM and readmission marts on DuckDB
