"""Generate the Power BI project (PBIP: TMDL semantic model + PBIR report) from the built warehouse.

Output: powerbi/HCareLedger.pbip  -> open in Power BI Desktop (File > Open > .pbip), then Refresh.

The semantic model reads the star-schema Parquet files in outputs/powerbi/ through the DataFolder
parameter. Column types and descriptions come from DuckDB metadata (the same COMMENT ON text as the
data dictionary), so the model always matches the warehouse.

Usage:  .venv\\Scripts\\python.exe -I pipeline\\powerbi.py
"""
from __future__ import annotations

import json
import shutil
import uuid
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "hcareledger.duckdb"
OUT = ROOT / "powerbi"
NAME = "HCareLedger"
SM = OUT / f"{NAME}.SemanticModel"
RPT = OUT / f"{NAME}.Report"
NS = uuid.UUID("6f1d2c1e-6b0a-4f3e-9d55-2f9b8f0e1a10")
SCHEMA = "https://developer.microsoft.com/json-schemas/fabric"

TABLES = ["dim_date", "dim_service_type", "dim_beneficiary_year", "dim_provider", "dim_diagnosis",
          "fct_claim_line", "fct_drug_event", "fct_member_month", "fct_inpatient_stay"]

# (from table, from column, to table, to column, active)
RELATIONSHIPS = [
    ("fct_claim_line", "bene_year_key", "dim_beneficiary_year", "bene_year_key", True),
    ("fct_claim_line", "incurred_month_key", "dim_date", "date_key", True),
    ("fct_claim_line", "service_type_key", "dim_service_type", "service_type_key", True),
    ("fct_claim_line", "principal_diagnosis_key", "dim_diagnosis", "diagnosis_key", True),
    ("fct_claim_line", "billing_provider_key", "dim_provider", "provider_key", True),
    ("fct_claim_line", "from_date_key", "dim_date", "date_key", False),
    ("fct_claim_line", "clinician_provider_key", "dim_provider", "provider_key", False),
    ("fct_drug_event", "bene_year_key", "dim_beneficiary_year", "bene_year_key", True),
    ("fct_drug_event", "incurred_month_key", "dim_date", "date_key", True),
    ("fct_drug_event", "service_type_key", "dim_service_type", "service_type_key", True),
    ("fct_drug_event", "prescriber_provider_key", "dim_provider", "provider_key", True),
    ("fct_drug_event", "service_date_key", "dim_date", "date_key", False),
    ("fct_member_month", "bene_year_key", "dim_beneficiary_year", "bene_year_key", True),
    ("fct_member_month", "month_key", "dim_date", "date_key", True),
    ("fct_inpatient_stay", "bene_year_key", "dim_beneficiary_year", "bene_year_key", True),
    ("fct_inpatient_stay", "admission_date_key", "dim_date", "date_key", True),
    ("fct_inpatient_stay", "principal_diagnosis_key", "dim_diagnosis", "diagnosis_key", True),
    ("fct_inpatient_stay", "facility_provider_key", "dim_provider", "provider_key", True),
    ("fct_inpatient_stay", "discharge_date_key", "dim_date", "date_key", False),
]

SORT_BY = {
    ("dim_date", "month_name"): "month",
    ("dim_date", "month_short"): "month",
    ("dim_date", "day_name"): "day_of_week",
    ("dim_date", "quarter_label"): "quarter",
    ("dim_beneficiary_year", "age_band"): "age_band_order",
    ("dim_service_type", "service_type"): "sort_order",
}

USD0 = r"\$#,0;(\$#,0);\$#,0"
USD2 = r"\$#,0.00;(\$#,0.00);\$#,0.00"
PCT1 = "0.0%;-0.0%;0.0%"

# DAX measures: (display folder, name, format string, description, expression)
IN_WINDOW_MED = ("fct_claim_line[is_in_reporting_window] = TRUE(),\n"
                 "    fct_claim_line[is_medical_eligible_month] = TRUE()")
STAY_FILTER = ("fct_inpatient_stay[is_admission_in_window] = TRUE(),\n"
               "    fct_inpatient_stay[is_medical_eligible_month] = TRUE()")
DISCHARGE_ROLE = "USERELATIONSHIP(fct_inpatient_stay[discharge_date_key], dim_date[date_key])"

MEASURES = [
    # ---------------------------------------------------------------- cost
    ("1. Cost", "Medical Paid", USD0,
     "Medicare paid on claim lines incurred in medical member months (Part A + B, no HMO), Mar-2015 to Feb-2023.",
     f"CALCULATE(\n    SUM(fct_claim_line[paid_amount]),\n    {IN_WINDOW_MED}\n)"),
    ("1. Cost", "Medical Member Months", "#,0",
     "Months with Part A + Part B and no HMO, in the reporting window. Medical PMPM denominator.",
     "CALCULATE(\n    SUM(fct_member_month[medical_member_month]),\n    fct_member_month[is_in_reporting_window] = TRUE()\n)"),
    ("1. Cost", "Medical PMPM", USD2,
     "Medical paid per medical member month.",
     "DIVIDE([Medical Paid], [Medical Member Months])"),
    ("1. Cost", "Medical PMPM PY", USD2,
     "Medical PMPM for the same period one year earlier.",
     "CALCULATE([Medical PMPM], SAMEPERIODLASTYEAR(dim_date[date]))"),
    ("1. Cost", "Medical PMPM YoY %", PCT1,
     "Change in medical PMPM versus the same period one year earlier.",
     "DIVIDE([Medical PMPM] - [Medical PMPM PY], [Medical PMPM PY])"),
    ("1. Cost", "Medical PMPM (Rolling 12M)", USD2,
     "Medical PMPM over the 12 months ending at the latest date in context.",
     "VAR LastDate = MAX(dim_date[date])\nRETURN\n    CALCULATE([Medical PMPM], DATESINPERIOD(dim_date[date], LastDate, -12, MONTH))"),
    ("1. Cost", "Part D Plan Paid", USD0,
     "Part D plan paid (covered + non-covered) on fills in Part D member months, Mar-2015 to Feb-2023.",
     "CALCULATE(\n    SUM(fct_drug_event[plan_paid_amount]),\n    fct_drug_event[is_in_reporting_window] = TRUE(),\n    fct_drug_event[is_rx_eligible_month] = TRUE()\n)"),
    ("1. Cost", "Part D Member Months", "#,0",
     "Months enrolled in Part D, in the reporting window. Part D PMPM denominator.",
     "CALCULATE(\n    SUM(fct_member_month[rx_member_month]),\n    fct_member_month[is_in_reporting_window] = TRUE()\n)"),
    ("1. Cost", "Part D PMPM", USD2,
     "Part D plan paid per Part D member month.",
     "DIVIDE([Part D Plan Paid], [Part D Member Months])"),
    ("1. Cost", "Part D Plan Paid PMPY", USD2,
     "Part D plan paid per average enrolled member per year (member months / 12).",
     "DIVIDE([Part D Plan Paid], DIVIDE([Part D Member Months], 12))"),
    ("1. Cost", "PMPM", USD2,
     "PMPM that follows the service type in context: Part D PMPM for Part D, medical PMPM otherwise (including totals).",
     'IF(\n    SELECTEDVALUE(dim_service_type[benefit]) = "Part D",\n    [Part D PMPM],\n    [Medical PMPM]\n)'),
    ("1. Cost", "Total Spend", USD0,
     "Medical paid plus Part D plan paid.",
     "[Medical Paid] + [Part D Plan Paid]"),
    ("1. Cost", "Top 5% Share of Spend", PCT1,
     "Share of total spend (medical + Part D) from the costliest 5% of members with at least one medical member month in context. Zero-spend members count in the population.",
     "VAR MemberSpend =\n    ADDCOLUMNS(\n        FILTER(VALUES(dim_beneficiary_year[bene_id]), [Medical Member Months] > 0),\n"
     "        \"@Spend\", [Medical Paid] + [Part D Plan Paid]\n    )\n"
     "VAR MemberCount = COUNTROWS(MemberSpend)\nVAR TopCount = ROUNDUP(MemberCount * 0.05, 0)\n"
     "VAR TopSpend = SUMX(TOPN(TopCount, MemberSpend, [@Spend], DESC), [@Spend])\n"
     "RETURN\n    DIVIDE(TopSpend, SUMX(MemberSpend, [@Spend]))"),
    # ---------------------------------------------------------------- utilization
    ("2. Utilization", "Admissions", "#,0",
     "Acute inpatient stays admitted in the window during a medical member month (overlapping and transfer claims merged).",
     f"CALCULATE(\n    COUNTROWS(fct_inpatient_stay),\n    {STAY_FILTER}\n)"),
    ("2. Utilization", "Admits per 1,000", "#,0.0",
     "Admissions per 1,000 members per year = admissions / medical member months x 12,000.",
     "DIVIDE([Admissions] * 12000, [Medical Member Months])"),
    ("2. Utilization", "Inpatient Days", "#,0",
     "Inpatient days for admissions in context; same-day stays count as 1 day.",
     f"CALCULATE(\n    SUMX(fct_inpatient_stay, MAX(fct_inpatient_stay[length_of_stay], 1)),\n    {STAY_FILTER}\n)"),
    ("2. Utilization", "Days per 1,000", "#,0.0",
     "Inpatient days per 1,000 members per year.",
     "DIVIDE([Inpatient Days] * 12000, [Medical Member Months])"),
    ("2. Utilization", "Average Length of Stay", "0.00",
     "Inpatient days per admission.",
     "DIVIDE([Inpatient Days], [Admissions])"),
    ("2. Utilization", "Paid per Admission", USD2,
     "Medicare paid per acute inpatient stay.",
     f"DIVIDE(\n    CALCULATE(SUM(fct_inpatient_stay[paid_amount]), {STAY_FILTER.replace(chr(10) + '    ', ' ')}),\n    [Admissions]\n)"),
    ("2. Utilization", "Outpatient Visits", "#,0",
     "Outpatient facility claims incurred in medical member months.",
     f'CALCULATE(\n    COUNTROWS(fct_claim_line),\n    fct_claim_line[is_header_line] = TRUE(),\n    {IN_WINDOW_MED},\n    dim_service_type[claim_type] = "outpatient"\n)'),
    ("2. Utilization", "Outpatient Visits per 1,000", "#,0.0",
     "Outpatient visits per 1,000 members per year.",
     "DIVIDE([Outpatient Visits] * 12000, [Medical Member Months])"),
    ("2. Utilization", "Professional Claims", "#,0",
     "Professional (carrier) claims incurred in medical member months.",
     f'CALCULATE(\n    COUNTROWS(fct_claim_line),\n    fct_claim_line[is_header_line] = TRUE(),\n    {IN_WINDOW_MED},\n    dim_service_type[claim_type] = "carrier"\n)'),
    ("2. Utilization", "Professional Claims per 1,000", "#,0.0",
     "Professional claims per 1,000 members per year.",
     "DIVIDE([Professional Claims] * 12000, [Medical Member Months])"),
    ("2. Utilization", "Diagnosis Cost Rank", "0",
     "Rank of a diagnosis category by medical paid among the categories in context.",
     "IF(\n    ISINSCOPE(dim_diagnosis[category_description]),\n"
     "    RANKX(ALLSELECTED(dim_diagnosis[category_description]), [Medical Paid], , DESC)\n)"),
    ("2. Utilization", "Medical Paid (Top 10 Dx)", USD0,
     "Medical paid for the 10 costliest diagnosis categories; blank for the rest, so visuals show only the top 10.",
     "IF([Diagnosis Cost Rank] <= 10, [Medical Paid])"),
    ("2. Utilization", "% of Medical Paid", PCT1,
     "Share of medical paid across the diagnoses in context.",
     "DIVIDE([Medical Paid], CALCULATE([Medical Paid], ALLSELECTED(dim_diagnosis)))"),
    # ---------------------------------------------------------------- readmissions (by discharge date)
    ("3. Readmissions", "Index Stays", "#,0",
     "Stays eligible as readmission index stays, dated by discharge: discharged alive, not transferred or AMA, with a full 30-day follow-up in the window.",
     f"CALCULATE(\n    COUNTROWS(fct_inpatient_stay),\n    fct_inpatient_stay[is_index_eligible] = TRUE(),\n    {DISCHARGE_ROLE}\n)"),
    ("3. Readmissions", "Readmissions (30-day)", "#,0",
     "Index stays followed by any admission 1-30 days after discharge.",
     "CALCULATE([Index Stays], fct_inpatient_stay[has_readmission_30d] = TRUE())"),
    ("3. Readmissions", "Readmission Rate", PCT1,
     "30-day all-cause readmission rate.",
     "DIVIDE([Readmissions (30-day)], [Index Stays])"),
    ("3. Readmissions", "Unplanned Readmissions (30-day)", "#,0",
     "Index stays followed by a non-elective admission 1-30 days after discharge (elective = planned proxy).",
     "CALCULATE([Index Stays], fct_inpatient_stay[has_unplanned_readmission_30d] = TRUE())"),
    ("3. Readmissions", "Unplanned Readmission Rate", PCT1,
     "30-day unplanned readmission rate.",
     "DIVIDE([Unplanned Readmissions (30-day)], [Index Stays])"),
    ("3. Readmissions", "Avg Days to Readmission", "0.0",
     "Average days from index discharge to the next admission, for readmitted index stays.",
     f"CALCULATE(\n    AVERAGE(fct_inpatient_stay[days_to_readmission]),\n    fct_inpatient_stay[is_index_eligible] = TRUE(),\n    {DISCHARGE_ROLE}\n)"),
]


def tag(*parts: str) -> str:
    """Deterministic lineage tag so regenerating the project produces no spurious diffs."""
    return str(uuid.uuid5(NS, "/".join(parts)))


def q(name: str) -> str:
    """Quote a TMDL object name when needed."""
    return name if name.replace("_", "").isalnum() else "'" + name.replace("'", "''") + "'"


def type_map(table: str, col: str, dt: str):
    """DuckDB type -> (TMDL dataType, M type, formatString or None)."""
    int_like = dt in ("BIGINT", "INTEGER", "SMALLINT", "TINYINT", "HUGEINT", "UBIGINT", "UINTEGER")
    if int_like:
        plain = col.endswith(("_key", "year", "month", "quarter", "_number", "_order", "_seq", "day_of_week", "line_number"))
        return "int64", "Int64.Type", "0" if plain else "#,0"
    if dt == "DECIMAL(18,2)":
        return "decimal", "Currency.Type", USD2
    if dt.startswith("DECIMAL") or dt in ("DOUBLE", "FLOAT"):
        return "double", "type number", "#,0.00"
    if dt == "DATE":
        return "dateTime", "type date", "Short Date"
    if dt == "BOOLEAN":
        return "boolean", "type logical", None
    return "string", "type text", None


def doc_lines(text: str | None, indent: str) -> list[str]:
    return [f"{indent}/// {line}" for line in (text or "").splitlines() if line.strip()]


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def write_json(path: Path, obj: dict) -> None:
    write(path, json.dumps(obj, indent=2) + "\n")


# ------------------------------------------------------------------------------------------ model
def table_tmdl(con: duckdb.DuckDBPyConnection, table: str) -> str:
    tcomment = con.execute("select comment from duckdb_tables() where schema_name = 'mart' and table_name = ?", [table]).fetchone()[0]
    cols = con.execute(
        "select column_name, data_type, comment from duckdb_columns() where schema_name = 'mart' and table_name = ? order by column_index",
        [table]).fetchall()
    T = "\t"
    out = doc_lines(tcomment, "") + [f"table {table}", f"{T}lineageTag: {tag(table)}"]
    if table == "dim_date":
        out.append(f"{T}dataCategory: Time")
    out.append("")
    m_types = []
    for name, dt, comment in cols:
        tm, mtype, fmt = type_map(table, name, dt)
        m_types.append(f'{{"{name}", {mtype}}}')
        out += doc_lines(comment, T)
        out.append(f"{T}column {name}")
        out.append(f"{T}{T}dataType: {tm}")
        if fmt:
            out.append(f"{T}{T}formatString: {fmt}")
        if name.endswith("_key") or (table.startswith("fct_") and name == "bene_id"):
            out.append(f"{T}{T}isHidden")
        if table == "dim_date" and name == "date":
            out.append(f"{T}{T}isKey")
        out.append(f"{T}{T}lineageTag: {tag(table, name)}")
        out.append(f"{T}{T}summarizeBy: none")
        out.append(f"{T}{T}sourceColumn: {name}")
        if (table, name) in SORT_BY:
            out.append(f"{T}{T}sortByColumn: {SORT_BY[(table, name)]}")
        out.append("")
    out += [
        f"{T}partition {table} = m",
        f"{T}{T}mode: import",
        f"{T}{T}source =",
        f"{T}{T}{T}{T}let",
        f'{T}{T}{T}{T}    Source = Parquet.Document(File.Contents(DataFolder & "\\{table}.parquet")),',
        f"{T}{T}{T}{T}    Typed = Table.TransformColumnTypes(Source, {{{', '.join(m_types)}}})",
        f"{T}{T}{T}{T}in",
        f"{T}{T}{T}{T}    Typed",
        "",
        f"{T}annotation PBI_ResultType = Table",
        "",
    ]
    return "\n".join(out)


def measures_tmdl() -> str:
    T = "\t"
    out = ["/// Home table for all DAX measures. Placeholder column is hidden.",
           "table _Measures", f"{T}lineageTag: {tag('_Measures')}", ""]
    for folder, name, fmt, desc, expr in MEASURES:
        out += doc_lines(desc, T)
        out.append(f"{T}measure {q(name)} =")
        out += [f"{T}{T}{T}{line}" for line in expr.splitlines()]
        out.append(f"{T}{T}formatString: {fmt}")
        out.append(f"{T}{T}displayFolder: {folder}")
        out.append(f"{T}{T}lineageTag: {tag('_Measures', name)}")
        out.append("")
    out += [
        f"{T}column Placeholder",
        f"{T}{T}dataType: string",
        f"{T}{T}isHidden",
        f"{T}{T}lineageTag: {tag('_Measures', 'Placeholder')}",
        f"{T}{T}summarizeBy: none",
        f"{T}{T}sourceColumn: Placeholder",
        "",
        f"{T}partition _Measures = m",
        f"{T}{T}mode: import",
        f"{T}{T}source = #table(type table [Placeholder = text], {{}})",
        "",
        f"{T}annotation PBI_ResultType = Table",
        "",
    ]
    return "\n".join(out)


def build_model(con: duckdb.DuckDBPyConnection) -> None:
    T = "\t"
    d = SM / "definition"
    write_json(SM / "definition.pbism", {"$schema": f"{SCHEMA}/item/semanticModel/definitionProperties/1.0.0/schema.json",
                                         "version": "4.0", "settings": {}})
    write(d / "database.tmdl", f"database\n{T}compatibilityLevel: 1600\n")
    all_tables = ["_Measures"] + TABLES
    write(d / "model.tmdl", "\n".join([
        "model Model",
        f"{T}culture: en-US",
        f"{T}defaultPowerBIDataSourceVersion: powerBI_V3",
        f"{T}discourageImplicitMeasures",
        f"{T}sourceQueryCulture: en-US",
        f"{T}dataAccessOptions",
        f"{T}{T}legacyRedirects",
        f"{T}{T}returnErrorValuesAsNull",
        "",
        "annotation __PBI_TimeIntelligenceEnabled = 0",
        "",
        "annotation PBI_QueryOrder = " + json.dumps(["DataFolder"] + all_tables, separators=(",", ":")),
        "",
        *[f"ref table {t}" for t in all_tables],
        "",
    ]))
    folder = (ROOT / "outputs" / "powerbi").resolve()
    write(d / "expressions.tmdl", "\n".join([
        "/// Folder holding the star-schema Parquet files written by pipeline/build.py. Change it if the repo lives elsewhere.",
        f'expression DataFolder = "{folder}" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]',
        f"{T}lineageTag: {tag('DataFolder')}",
        "",
        f"{T}annotation PBI_ResultType = Text",
        "",
    ]))
    rels = []
    for ft, fc, tt, tc, active in RELATIONSHIPS:
        rels.append(f"relationship {tag('rel', ft, fc, tt, tc)}")
        if not active:
            rels.append(f"{T}isActive: false")
        rels += [f"{T}fromColumn: {ft}.{fc}", f"{T}toColumn: {tt}.{tc}", ""]
    write(d / "relationships.tmdl", "\n".join(rels))
    for t in TABLES:
        write(d / "tables" / f"{t}.tmdl", table_tmdl(con, t))
    write(d / "tables" / "_Measures.tmdl", measures_tmdl())


# ------------------------------------------------------------------------------------------ report
def m(name: str) -> tuple:
    return ("Measure", "_Measures", name)


def c(table: str, name: str) -> tuple:
    return ("Column", table, name)


def field(ref: tuple) -> dict:
    kind, entity, prop = ref
    return {kind: {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def literal(value: str) -> dict:
    return {"expr": {"Literal": {"Value": value}}}


def visual(name, vtype, x, y, w, h, roles, title=None, sort=None, objects=None, z=0):
    query_state = {
        role: {"projections": [{"field": field(r), "queryRef": f"{r[1]}.{r[2]}", "nativeQueryRef": r[2]} for r in refs]}
        for role, refs in roles.items()
    }
    v = {"visualType": vtype, "query": {"queryState": query_state}, "drillFilterOtherVisuals": True}
    if sort:
        ref, direction = sort
        v["query"]["sortDefinition"] = {"sort": [{"field": field(ref), "direction": direction}], "isDefaultSort": False}
    if objects:
        v["objects"] = objects
    if title:
        v["visualContainerObjects"] = {"title": [{"properties": {"show": literal("true"), "text": literal(f"'{title}'")}}]}
    return {
        "$schema": f"{SCHEMA}/item/report/definition/visualContainer/2.4.0/schema.json",
        "name": name,
        "position": {"x": x, "y": y, "z": z, "width": w, "height": h, "tabOrder": z},
        "visual": v,
    }


def card(name, x, measure, title, auto_units=False):
    objects = None if auto_units else {"labels": [{"properties": {"labelDisplayUnits": literal("1D")}}]}
    return visual(name, "card", x, 90, 297, 110, {"Values": [m(measure)]}, title=title, objects=objects)


def slicers(prefix: str) -> list[dict]:
    dropdown = {"data": [{"properties": {"mode": literal("'Dropdown'")}}]}
    return [
        visual(f"{prefix}_slicer_year", "slicer", 20, 15, 200, 60, {"Values": [c("dim_date", "year")]}, title="Year", objects=dropdown),
        visual(f"{prefix}_slicer_age", "slicer", 235, 15, 200, 60, {"Values": [c("dim_beneficiary_year", "age_band")]}, title="Age band", objects=dropdown),
        visual(f"{prefix}_slicer_dual", "slicer", 450, 15, 200, 60, {"Values": [c("dim_beneficiary_year", "dual_status")]}, title="Dual status", objects=dropdown),
    ]


def pages() -> list[tuple[str, str, list[dict]]]:
    xs = [20, 332, 644, 956]  # four 297px cards with 15px gutters
    cost = slicers("cost") + [
        card("cost_card_pmpm", xs[0], "Medical PMPM", "Medical PMPM"),
        card("cost_card_partd", xs[1], "Part D PMPM", "Part D PMPM"),
        card("cost_card_paid", xs[2], "Medical Paid", "Medical paid", auto_units=True),
        card("cost_card_top5", xs[3], "Top 5% Share of Spend", "Spend from top 5% of members"),
        visual("cost_line_monthly", "lineChart", 20, 215, 800, 240,
               {"Category": [c("dim_date", "month_start")], "Y": [m("Medical PMPM"), m("Medical PMPM (Rolling 12M)")]},
               title="Medical PMPM by month, with rolling 12-month PMPM"),
        visual("cost_column_service", "columnChart", 835, 215, 425, 240,
               {"Category": [c("dim_date", "year")], "Series": [c("dim_service_type", "service_type")], "Y": [m("Medical PMPM")]},
               title="Medical PMPM by service type"),
        visual("cost_matrix_pmpm", "pivotTable", 20, 470, 800, 235,
               {"Rows": [c("dim_date", "year")], "Columns": [c("dim_service_type", "service_type")], "Values": [m("PMPM")]},
               title="PMPM by year and service type (total = medical)"),
        visual("cost_table_trend", "tableEx", 835, 470, 425, 235,
               {"Values": [c("dim_date", "year"), m("Medical PMPM"), m("Medical PMPM YoY %"), m("Top 5% Share of Spend")]},
               title="Trend and cost concentration"),
    ]
    util = slicers("util") + [
        card("util_card_admits", xs[0], "Admits per 1,000", "Admits per 1,000"),
        card("util_card_alos", xs[1], "Average Length of Stay", "Average length of stay (days)"),
        card("util_card_op", xs[2], "Outpatient Visits per 1,000", "Outpatient visits per 1,000"),
        card("util_card_paid_adm", xs[3], "Paid per Admission", "Paid per admission"),
        visual("util_column_admits", "clusteredColumnChart", 20, 215, 620, 240,
               {"Category": [c("dim_date", "year")], "Y": [m("Admits per 1,000")]}, title="Inpatient admits per 1,000 by year"),
        visual("util_line_visits", "lineChart", 655, 215, 605, 240,
               {"Category": [c("dim_date", "year")], "Y": [m("Outpatient Visits per 1,000"), m("Professional Claims per 1,000")]},
               title="Outpatient visits and professional claims per 1,000"),
        visual("util_bar_dx", "clusteredBarChart", 20, 470, 620, 235,
               {"Category": [c("dim_diagnosis", "category_description")], "Y": [m("Medical Paid (Top 10 Dx)")]},
               title="Top 10 diagnosis categories by medical paid", sort=(m("Medical Paid (Top 10 Dx)"), "Descending")),
        visual("util_table_year", "tableEx", 655, 470, 605, 235,
               {"Values": [c("dim_date", "year"), m("Medical Member Months"), m("Admissions"), m("Admits per 1,000"),
                           m("Days per 1,000"), m("Average Length of Stay")]},
               title="Utilization by year"),
    ]
    readm = slicers("readm") + [
        card("readm_card_index", xs[0], "Index Stays", "Index stays"),
        card("readm_card_rate", xs[1], "Readmission Rate", "30-day readmission rate"),
        card("readm_card_unplanned", xs[2], "Unplanned Readmission Rate", "Unplanned readmission rate"),
        card("readm_card_days", xs[3], "Avg Days to Readmission", "Avg days to readmission"),
        visual("readm_line_year", "lineChart", 20, 215, 620, 240,
               {"Category": [c("dim_date", "year")], "Y": [m("Readmission Rate"), m("Unplanned Readmission Rate")]},
               title="30-day readmission rate by discharge year"),
        visual("readm_bar_age", "clusteredBarChart", 655, 215, 605, 240,
               {"Category": [c("dim_beneficiary_year", "age_band")], "Y": [m("Readmission Rate")]},
               title="Readmission rate by age band"),
        visual("readm_bar_type", "clusteredBarChart", 20, 470, 620, 235,
               {"Category": [c("fct_inpatient_stay", "admission_type")], "Y": [m("Readmission Rate")]},
               title="Readmission rate by index admission type"),
        visual("readm_table_year", "tableEx", 655, 470, 605, 235,
               {"Values": [c("dim_date", "year"), m("Index Stays"), m("Readmissions (30-day)"), m("Readmission Rate"),
                           m("Unplanned Readmission Rate")]},
               title="Readmissions by discharge year"),
    ]
    return [("cost_trend", "Cost Trend", cost), ("utilization", "Utilization", util), ("readmissions", "Readmissions", readm)]


def build_report() -> None:
    d = RPT / "definition"
    write_json(RPT / "definition.pbir", {
        "$schema": f"{SCHEMA}/item/report/definitionProperties/2.0.0/schema.json",
        "version": "4.0",
        "datasetReference": {"byPath": {"path": f"../{NAME}.SemanticModel"}},
    })
    write_json(d / "version.json", {"$schema": f"{SCHEMA}/item/report/definition/versionMetadata/1.0.0/schema.json", "version": "2.0.0"})
    write_json(d / "report.json", {"$schema": f"{SCHEMA}/item/report/definition/report/3.0.0/schema.json", "themeCollection": {}})
    page_list = pages()
    write_json(d / "pages" / "pages.json", {
        "$schema": f"{SCHEMA}/item/report/definition/pagesMetadata/1.0.0/schema.json",
        "pageOrder": [p[0] for p in page_list],
        "activePageName": page_list[0][0],
    })
    for page_name, display, visuals in page_list:
        write_json(d / "pages" / page_name / "page.json", {
            "$schema": f"{SCHEMA}/item/report/definition/page/2.0.0/schema.json",
            "name": page_name, "displayName": display, "displayOption": "FitToPage", "height": 720, "width": 1280,
        })
        for v in visuals:
            write_json(d / "pages" / page_name / "visuals" / v["name"] / "visual.json", v)


CHECK_VALUES = [  # (visual / filter context, measure, SQL source of the expected value)
    ("No filters", "Medical PMPM", "select round(sum(paid_amount) / sum(member_months), 2) from rpt.pmpm_yearly where service_type = 'Total Medical'"),
    ("Year = 2022", "Medical PMPM", "select pmpm from rpt.pmpm_yearly where year = 2022 and service_type = 'Total Medical'"),
    ("Year = 2022", "PMPM (service type = Outpatient)", "select pmpm from rpt.pmpm_yearly where year = 2022 and service_type = 'Outpatient'"),
    ("No filters", "Part D PMPM", "select round(sum(paid_amount) / sum(member_months), 2) from rpt.pmpm_yearly where service_type = 'Part D'"),
    ("Year = 2022", "Part D Plan Paid PMPY", "select plan_paid_per_member_per_year from rpt.partd_yearly where year = 2022"),
    ("Year = 2022", "Admits per 1,000", "select admissions_per_1000 from rpt.utilization_yearly where year = 2022"),
    ("Year = 2022", "Average Length of Stay", "select average_length_of_stay from rpt.utilization_yearly where year = 2022"),
    ("No filters", "Index Stays", "select index_stays from rpt.readmission_yearly where period = 'All years'"),
    ("No filters", "Readmission Rate", "select readmission_rate_pct || '%' from rpt.readmission_yearly where period = 'All years'"),
    ("No filters", "Unplanned Readmission Rate", "select unplanned_readmission_rate_pct || '%' from rpt.readmission_yearly where period = 'All years'"),
    ("Year = 2022", "Top 5% Share of Spend", "select top_5pct_share || '%' from rpt.cost_concentration where period = '2022'"),
    ("Top diagnosis bar, rank 1", "Medical Paid (Top 10 Dx)", "select category_description || ': ' || paid_amount from rpt.top_diagnosis_categories where cost_rank = 1"),
]


def write_docs(con: duckdb.DuckDBPyConnection) -> None:
    checks = [(ctx, meas, str(con.execute(sql).fetchone()[0])) for ctx, meas, sql in CHECK_VALUES]
    lines = [
        "# Power BI model and report",
        "",
        "_Generated by `pipeline/powerbi.py`._",
        "",
        "`powerbi/HCareLedger.pbip` is a Power BI project: a TMDL semantic model plus a PBIR report with three pages",
        "(**Cost Trend**, **Utilization**, **Readmissions**). Everything is text, so changes show up as readable diffs.",
        "",
        "## Open it",
        "",
        "1. Run the pipeline (`pipeline/build.py`) so `outputs/powerbi/*.parquet` exists.",
        "2. In Power BI Desktop (free, Windows), **File > Open** `powerbi/HCareLedger.pbip`.",
        f"3. If the repo is not at `{(ROOT).resolve()}`, open **Transform data > Edit parameters** and point `DataFolder` at `outputs/powerbi`.",
        "4. **Refresh**. Then compare the check values below.",
        "",
        "How it was checked without Desktop: every report JSON file validates against Microsoft's published PBIR schemas,",
        "and the TMDL deserializes and round-trips through Microsoft's Tabular Object Model (`TmdlSerializer`).",
        "DAX is only evaluated by the engine, so the check values below are the real test.",
        "",
        "## Check values after refresh",
        "",
        "Each DAX measure should reproduce the SQL report table it mirrors.",
        "",
        "| Filter context | Measure | Expected (from SQL) |",
        "| --- | --- | --- |",
        *[f"| {a} | {b} | {c} |" for a, b, c in checks],
        "",
        "## Model",
        "",
        "Star schema: 4 fact tables, 5 dimensions, measures in `_Measures`. All relationships are many-to-one, single direction.",
        "Inactive relationships are role-playing dates or providers, used through `USERELATIONSHIP`",
        "(readmission measures date index stays by **discharge**, everything else by admission or incurred month).",
        "`dim_date` is marked as the date table, auto date/time is off, and implicit measures are discouraged.",
        "",
        "| From | To | Active |",
        "| --- | --- | --- |",
        *[f"| {ft}[{fc}] | {tt}[{tc}] | {'yes' if a else 'no'} |" for ft, fc, tt, tc, a in RELATIONSHIPS],
        "",
        "## Measures",
        "",
    ]
    folder = None
    for f, name, fmt, desc, expr in MEASURES:
        if f != folder:
            lines += [f"### {f}", ""]
            folder = f
        lines += [f"**{name}**: {desc}", "", "```dax", expr, "```", ""]
    write(ROOT / "docs" / "powerbi.md", "\n".join(lines))


def main() -> None:
    for p in (SM, RPT):
        if p.exists():
            shutil.rmtree(p)
    write_json(OUT / f"{NAME}.pbip", {
        "$schema": f"{SCHEMA}/pbip/pbipProperties/1.0.0/schema.json",
        "version": "1.0",
        "artifacts": [{"report": {"path": f"{NAME}.Report"}}],
        "settings": {"enableAutoRecovery": True},
    })
    write(OUT / ".gitignore", "**/.pbi/localSettings.json\n**/.pbi/cache.abf\n")
    con = duckdb.connect(str(DB_PATH), read_only=True)
    build_model(con)
    write_docs(con)
    con.close()
    build_report()
    n_files = sum(1 for _ in OUT.rglob("*") if _.is_file())
    print(f"wrote {n_files} files to {OUT.relative_to(ROOT)} ({len(MEASURES)} measures, {len(RELATIONSHIPS)} relationships)")


if __name__ == "__main__":
    main()
