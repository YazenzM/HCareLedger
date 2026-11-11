"""Generate the finance workbook: excel/HCareLedger_PMPM_Budget.xlsx

  PMPM_Data  tblPMPM, loaded by the Power Query qPMPM_Monthly from outputs/reports/pmpm_monthly.csv
  Pivot      PivotTable: weighted PMPM by service type (rows) and year (columns)
  Budget     trend assumptions + budget PMPM by year and service type (XLOOKUP on the trend table)
  Variance   budget vs actual for a selected year: SUMIFS actuals, XLOOKUP budget, $ and % variance
  Checks     formulas that reconcile the workbook to the SQL results

openpyxl writes the sheets, tables and formulas. openpyxl cannot write a Power Query or a PivotTable,
so those parts are added as raw Office Open XML, following [MS-QDEFF] for the query definition and the
SpreadsheetML schema for the pivot. Excel recalculates formulas on open (fullCalcOnLoad).

Usage:  .venv\\Scripts\\python.exe -I pipeline\\excel.py
"""
from __future__ import annotations

import base64
import io
import re
import struct
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

import sys

import duckdb
from openpyxl import Workbook
from openpyxl.formatting.rule import CellIsRule, FormulaRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.workbook.defined_name import DefinedName
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.worksheet.table import Table, TableStyleInfo

# One palette for Power BI and Excel: defined (and CVD-validated) in pipeline/powerbi.py.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from powerbi import PAGE_BG, PALETTE  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DB_PATH = ROOT / "data" / "hcareledger.duckdb"
OUT = ROOT / "excel" / "HCareLedger_PMPM_Budget.xlsx"
CSV_FOLDER = str((ROOT / "outputs" / "reports").resolve())
QUERY, TABLE = "qPMPM_Monthly", "tblPMPM"
NS = uuid.UUID("0b8e3c55-3c1f-4a43-9d0e-6f7f2d9a0c11")

# tblPMPM columns, in the order of outputs/reports/pmpm_monthly.csv
COLUMNS = [("month_start", "date"), ("year", "int"), ("month", "int"), ("year_month", "text"),
           ("service_type", "text"), ("benefit", "text"), ("sort_order", "int"), ("member_months", "int"),
           ("paid_amount", "money"), ("claim_count", "int"), ("pmpm", "money")]
M_TYPE = {"date": "type date", "int": "Int64.Type", "text": "type text", "money": "Currency.Type"}
SERVICE_TYPES = ["Inpatient", "SNF", "Home Health", "Hospice", "Outpatient", "Professional", "DME", "Part D"]
MEDICAL = SERVICE_TYPES[:-1]
# Illustrative annual trend assumptions used to set the budget (budget = prior-year actual PMPM x (1 + trend)).
TREND = {"Inpatient": 0.040, "SNF": 0.030, "Home Health": 0.025, "Hospice": 0.030,
         "Outpatient": 0.050, "Professional": 0.035, "DME": 0.020, "Part D": 0.060}
BUDGET_YEARS = list(range(2016, 2023))

# Styling
NAVY = "1F3A5F"
TEAL = "12A39A"
# Workbook theme colors (drive Excel table/pivot styles and the color picker): series palette as accents 1-6.
THEME_COLORS = {"dk2": NAVY, "lt2": PAGE_BG.lstrip("#"), **{f"accent{i + 1}": c.lstrip("#") for i, c in enumerate(PALETTE[:6])}}
TAB_COLORS = {"README": NAVY, "Variance": NAVY, "Pivot": NAVY, "Budget": TEAL, "PMPM_Data": "898781", "Checks": "898781"}
TITLE = Font(name="Calibri", size=16, bold=True, color=NAVY)
SUBTLE = Font(name="Calibri", size=10, italic=True, color="595959")
BOLD = Font(bold=True)
HEADER_FILL = PatternFill("solid", fgColor=NAVY)
HEADER_FONT = Font(bold=True, color="FFFFFF")
INPUT_FILL = PatternFill("solid", fgColor="FFF2CC")
TOTAL_BORDER = Border(top=Side(style="thin", color="000000"))
USD = '"$"#,##0.00'
USD0 = '"$"#,##0'
PCT = "0.0%;-0.0%;0.0%"
INT = "#,##0"


# ============================================================================== data
def load(con: duckdb.DuckDBPyConnection):
    monthly = con.execute(f"select {', '.join(c for c, _ in COLUMNS)} from rpt.pmpm_monthly order by month_start, sort_order").fetchall()
    yearly = {(y, s): float(p) for y, s, p in con.execute("select year, service_type, pmpm from rpt.pmpm_yearly").fetchall()}
    return monthly, yearly


def pmpm(rows, year=None, service=None):
    """Weighted PMPM from tblPMPM rows, mirroring the SUMIFS formulas used in the workbook."""
    sel = [r for r in rows if (year is None or r[1] == year) and (service is None or r[4] == service)]
    mm = sum(r[7] for r in sel)
    return float(sum(r[8] for r in sel)) / mm if mm else 0.0


def budget_rows(yearly):
    out = []
    for y in BUDGET_YEARS:
        for s in SERVICE_TYPES:
            base = round(yearly[(y - 1, s)], 2)
            out.append((f"{y}|{s}", y, s, "Part D" if s == "Part D" else ("Part A" if s in MEDICAL[:4] else "Part B"),
                        base, round(base * (1 + TREND[s]), 2)))
    return out


# ============================================================================== workbook (openpyxl)
def header(ws, row, col, labels):
    for i, label in enumerate(labels):
        c = ws.cell(row=row, column=col + i, value=label)
        c.font, c.fill = HEADER_FONT, HEADER_FILL
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)


def widths(ws, mapping):
    for col, w in mapping.items():
        ws.column_dimensions[col].width = w


def sheet_readme(wb):
    ws = wb.active
    ws.title = "README"
    ws.sheet_view.showGridLines = False
    widths(ws, {"A": 3, "B": 26, "C": 100})
    ws["B2"] = "HCareLedger: Medicare PMPM budget vs actual"
    ws["B2"].font = TITLE
    ws["B3"] = ("Synthetic data (CMS Synthetic Medicare Claims PUFs, May 2023). Payment amounts do not match real Medicare; "
                "the numbers demonstrate the method only.")
    ws["B3"].font = SUBTLE
    rows = [
        ("Sheets", ""),
        ("Variance", "Budget vs actual PMPM for the year chosen in C5. Actuals by SUMIFS on tblPMPM, budget by XLOOKUP on tblBudget."),
        ("Pivot", "PivotTable on tblPMPM: weighted PMPM (sum of paid / sum of member months) by service type and year."),
        ("Budget", "Trend assumptions (yellow, editable) and the budget table they drive: budget PMPM = prior-year actual PMPM x (1 + trend)."),
        ("PMPM_Data", "tblPMPM: monthly PMPM by service type, loaded by the Power Query qPMPM_Monthly."),
        ("Checks", "Formulas that reconcile this workbook to the SQL pipeline. All should read PASS."),
        ("", ""),
        ("Definitions", ""),
        ("PMPM", "Per member per month = paid / member months. Medical: Medicare paid / months with Part A + B and no HMO. "
                 "Part D: plan paid / Part D enrolled months."),
        ("Total Medical", "All Part A and Part B service types. Their PMPMs share one denominator, so they add up to the total."),
        ("Variance", "Actual minus budget. Positive = cost above budget = Unfavorable."),
        ("Reporting window", "March 2015 - February 2023 (complete months of claims). 2015 has 10 months, 2023 has 2."),
        ("", ""),
        ("Refresh the data", ""),
        ("1", "Run the SQL pipeline (pipeline/build.py) so outputs/reports/pmpm_monthly.csv is current."),
        ("2", f"Data > Queries & Connections > right-click CsvFolder > Edit, and set it to the folder holding pmpm_monthly.csv "
              f"(currently {CSV_FOLDER})."),
        ("3", "Data > Refresh All. tblPMPM reloads, the pivot refreshes on open, and every formula recalculates."),
    ]
    for r, (k, v) in enumerate(rows, start=5):
        key = ws.cell(row=r, column=2, value=k or None)
        key.font = Font(bold=True, color=NAVY, size=12) if k and not v else BOLD
        key.alignment = Alignment(vertical="top")
        ws.cell(row=r, column=3, value=v or None).alignment = Alignment(wrap_text=True, vertical="top")


def sheet_data(wb, monthly):
    ws = wb.create_sheet("PMPM_Data")
    header(ws, 1, 1, [c for c, _ in COLUMNS])
    for i, row in enumerate(monthly, start=2):
        for j, ((name, kind), v) in enumerate(zip(COLUMNS, row), start=1):
            cell = ws.cell(row=i, column=j, value=float(v) if kind == "money" else v)
            if kind == "date":
                cell.number_format = "yyyy-mm-dd"
            elif kind == "money":
                cell.number_format = USD
            elif name in ("member_months", "claim_count"):
                cell.number_format = INT
    last = len(monthly) + 1
    t = Table(displayName=TABLE, ref=f"A1:K{last}")
    t.tableStyleInfo = TableStyleInfo(name="TableStyleMedium2", showRowStripes=True)
    ws.add_table(t)
    ws.freeze_panes = "A2"
    widths(ws, {"A": 13, "B": 7, "C": 7, "D": 11, "E": 14, "F": 9, "G": 10, "H": 15, "I": 16, "J": 12, "K": 12})
    # Query tables carry a hidden sheet-scoped name for their range, as Excel writes them.
    ws.defined_names["ExternalData_1"] = DefinedName("ExternalData_1", hidden=True, attr_text=f"PMPM_Data!$A$1:$K${last}")
    return last


def sheet_budget(wb, budget):
    ws = wb.create_sheet("Budget")
    ws.sheet_view.showGridLines = False
    ws["A1"] = "Budget assumptions"
    ws["A1"].font = TITLE
    ws["A2"] = "Yellow cells are inputs. Budget PMPM = prior-year actual PMPM x (1 + annual trend), looked up with XLOOKUP."
    ws["A2"].font = SUBTLE
    header(ws, 4, 1, ["service_type", "annual_trend"])
    for i, s in enumerate(SERVICE_TYPES, start=5):
        ws.cell(row=i, column=1, value=s)
        c = ws.cell(row=i, column=2, value=TREND[s])
        c.number_format, c.fill = PCT, INPUT_FILL
    trend = Table(displayName="tblTrend", ref=f"A4:B{4 + len(SERVICE_TYPES)}")
    trend.tableStyleInfo = TableStyleInfo(name="TableStyleLight9", showRowStripes=False)
    ws.add_table(trend)

    cols = ["key", "year", "service_type", "benefit", "prior_year_actual_pmpm", "annual_trend", "budget_pmpm"]
    header(ws, 4, 4, cols)
    for i, (key, y, s, ben, base, _) in enumerate(budget, start=5):
        ws.cell(row=i, column=4, value=key)
        ws.cell(row=i, column=5, value=y)
        ws.cell(row=i, column=6, value=s)
        ws.cell(row=i, column=7, value=ben)
        ws.cell(row=i, column=8, value=base).number_format = USD
        ws.cell(row=i, column=9, value=f"=_xlfn.XLOOKUP(F{i},tblTrend[service_type],tblTrend[annual_trend],0)").number_format = PCT
        ws.cell(row=i, column=10, value=f"=ROUND(H{i}*(1+I{i}),2)").number_format = USD
    last = 4 + len(budget)
    bt = Table(displayName="tblBudget", ref=f"D4:J{last}")
    bt.tableStyleInfo = TableStyleInfo(name="TableStyleMedium2", showRowStripes=True)
    ws.add_table(bt)
    ws.freeze_panes = "A5"
    widths(ws, {"A": 14, "B": 13, "C": 3, "D": 20, "E": 7, "F": 14, "G": 9, "H": 14, "I": 13, "J": 13})


def sheet_variance(wb):
    ws = wb.create_sheet("Variance", 1)
    ws.sheet_view.showGridLines = False
    ws["B2"] = "Budget vs actual PMPM"
    ws["B2"].font = TITLE
    ws["B3"] = "Pick a year in C5. Positive variance = cost above budget (unfavorable). Synthetic data: method demonstration only."
    ws["B3"].font = SUBTLE
    ws["B5"] = "Year"
    ws["B5"].font = BOLD
    ws["C5"] = 2022
    ws["C5"].fill, ws["C5"].font = INPUT_FILL, Font(bold=True, size=12)
    ws["C5"].alignment = Alignment(horizontal="center")
    dv = DataValidation(type="list", formula1='"' + ",".join(str(y) for y in BUDGET_YEARS) + '"', allow_blank=False,
                        showErrorMessage=True, errorTitle="Year", error="Choose a budget year (2016-2022).")
    ws.add_data_validation(dv)
    dv.add("C5")

    cols = ["Service type", "Benefit", "Member months", "Actual paid", "Actual PMPM", "Budget PMPM", "PMPM variance",
            "Variance %", "Budget $ at actual members", "$ variance", "Status", "Prior-year PMPM", "YoY change"]
    header(ws, 7, 2, cols)
    ws.row_dimensions[7].height = 32
    order = MEDICAL + ["Total Medical", "Part D"]
    sumifs = lambda col, year, svc: f'SUMIFS(tblPMPM[{col}],tblPMPM[year],{year},tblPMPM[service_type],{svc})'
    for r, s in enumerate(order, start=8):
        ws.cell(row=r, column=2, value=s)
        ws.cell(row=r, column=3, value="Part D" if s == "Part D" else ("Part A + B" if s == "Total Medical" else ("Part A" if s in MEDICAL[:4] else "Part B")))
        if s == "Total Medical":
            first, last = 8, 8 + len(MEDICAL) - 1
            f = {
                "D": f'={sumifs("member_months", "$C$5", chr(34) + "Inpatient" + chr(34))}',
                "E": f"=SUM(E{first}:E{last})",
                "G": f"=SUM(G{first}:G{last})",
                "M": (f'=IFERROR(SUMIFS(tblPMPM[paid_amount],tblPMPM[year],$C$5-1,tblPMPM[benefit],"<>Part D")'
                      f'/{sumifs("member_months", "$C$5-1", chr(34) + "Inpatient" + chr(34))},"")'),
            }
        else:
            f = {
                "D": f"={sumifs('member_months', '$C$5', f'$B{r}')}",
                "E": f"={sumifs('paid_amount', '$C$5', f'$B{r}')}",
                "G": f'=_xlfn.XLOOKUP($C$5&"|"&$B{r},tblBudget[key],tblBudget[budget_pmpm],NA())',
                "M": f"=IFERROR({sumifs('paid_amount', '$C$5-1', f'$B{r}')}/{sumifs('member_months', '$C$5-1', f'$B{r}')},\"\")",
            }
        f |= {
            "F": f"=IFERROR(E{r}/D{r},0)",
            "H": f"=F{r}-G{r}",
            "I": f'=IFERROR(H{r}/G{r},"")',
            "J": f"=G{r}*D{r}",
            "K": f"=E{r}-J{r}",
            "L": f'=IF(H{r}>0,"Unfavorable","Favorable")',
            "N": f'=IFERROR(F{r}/M{r}-1,"")',
        }
        fmts = {"D": INT, "E": USD0, "F": USD, "G": USD, "H": USD, "I": PCT, "J": USD0, "K": USD0, "M": USD, "N": PCT}
        for col, formula in f.items():
            c = ws[f"{col}{r}"]
            c.value = formula
            if col in fmts:
                c.number_format = fmts[col]
        if s == "Total Medical":
            for col in "BCDEFGHIJKLMN":
                ws[f"{col}{r}"].font = BOLD
                ws[f"{col}{r}"].border = TOTAL_BORDER
    last = 7 + len(order)
    red, green = PatternFill("solid", fgColor="F8CBAD"), PatternFill("solid", fgColor="C6EFCE")
    ws.conditional_formatting.add(f"L8:L{last}", CellIsRule(operator="equal", formula=['"Unfavorable"'], fill=red))
    ws.conditional_formatting.add(f"L8:L{last}", CellIsRule(operator="equal", formula=['"Favorable"'], fill=green))
    ws.conditional_formatting.add(f"H8:H{last}", FormulaRule(formula=["H8>0"], font=Font(color="C00000")))
    ws[f"B{last + 2}"] = ("Budget = prior-year actual PMPM x (1 + trend) from the Budget sheet. $ variance = actual paid minus "
                          "budget PMPM x actual member months.")
    ws[f"B{last + 2}"].font = SUBTLE
    widths(ws, {"A": 2, "B": 16, "C": 11, "D": 13, "E": 14, "F": 12, "G": 12, "H": 12, "I": 10, "J": 15, "K": 13, "L": 13, "M": 13, "N": 11})
    ws.freeze_panes = "C8"


def sheet_pivot(wb, monthly):
    """Writes the pivot's rendered values (visible even in Protected View); the PivotTable itself is injected later."""
    ws = wb.create_sheet("Pivot", 2)
    ws["A1"] = "PMPM by service type and year (PivotTable)"
    ws["A1"].font = TITLE
    ws["A2"] = "Weighted PMPM = sum of paid / sum of member months. Grand Total = full-window PMPM. Refreshes on open from tblPMPM."
    ws["A2"].font = SUBTLE
    years = sorted({r[1] for r in monthly})
    ws["A4"], ws["B4"] = "PMPM ($)", "Year"
    ws["A5"] = "Service type"
    for j, y in enumerate(years, start=2):
        ws.cell(row=5, column=j, value=y)
    ws.cell(row=5, column=len(years) + 2, value="Grand Total")
    for i, s in enumerate(SERVICE_TYPES, start=6):
        ws.cell(row=i, column=1, value=s)
        for j, y in enumerate(years, start=2):
            ws.cell(row=i, column=j, value=round(pmpm(monthly, y, s), 2)).number_format = "#,##0.00"
        ws.cell(row=i, column=len(years) + 2, value=round(pmpm(monthly, None, s), 2)).number_format = "#,##0.00"
    widths(ws, {"A": 16, **{chr(66 + k): 11 for k in range(len(years) + 1)}})
    return years


def sheet_checks(wb, monthly, yearly, budget):
    ws = wb.create_sheet("Checks")
    ws.sheet_view.showGridLines = False
    ws["A1"] = "Workbook checks"
    ws["A1"].font = TITLE
    ws["A2"] = '=IF(COUNTIF(E5:E40,"FAIL")=0,"All checks pass","Check failures - see column E")'
    ws["A2"].font = Font(bold=True, size=12)
    header(ws, 4, 1, ["Check", "Expected (SQL pipeline)", "Workbook value", "Difference", "Result"])
    med = lambda y: (f'SUMIFS(tblPMPM[paid_amount],tblPMPM[year],{y},tblPMPM[benefit],"<>Part D")'
                     f'/SUMIFS(tblPMPM[member_months],tblPMPM[year],{y},tblPMPM[service_type],"Inpatient")')
    checks = [("Rows in tblPMPM", len(monthly), "=ROWS(tblPMPM)"),
              ("Rows in tblBudget", len(budget), "=ROWS(tblBudget)")]
    for y in sorted({r[1] for r in monthly}):
        checks.append((f"Total medical PMPM {y}", round(yearly[(y, "Total Medical")], 2), f"={med(y)}"))
    checks.append(("Part D PMPM 2022", round(yearly[(2022, "Part D")], 2),
                   '=SUMIFS(tblPMPM[paid_amount],tblPMPM[year],2022,tblPMPM[service_type],"Part D")'
                   '/SUMIFS(tblPMPM[member_months],tblPMPM[year],2022,tblPMPM[service_type],"Part D")'))
    b = {k: v for k, _, _, _, _, v in budget}
    checks.append(("Budget PMPM 2022 Outpatient (XLOOKUP)", b["2022|Outpatient"],
                   '=_xlfn.XLOOKUP("2022|Outpatient",tblBudget[key],tblBudget[budget_pmpm])'))
    budget_years = ",".join(str(y) for y in BUDGET_YEARS)
    sql_values = ",".join(f"{round(yearly[(y, 'Total Medical')], 2)}" for y in BUDGET_YEARS)
    checks.append(("Variance sheet: Total Medical actual PMPM for the selected year",
                   f"=_xlfn.XLOOKUP(Variance!$C$5,{{{budget_years}}},{{{sql_values}}})", "=Variance!F15"))
    for i, (name, expected, formula) in enumerate(checks, start=5):
        ws.cell(row=i, column=1, value=name)
        ws.cell(row=i, column=2, value=expected).number_format = "#,##0.00"
        ws.cell(row=i, column=3, value=formula).number_format = "#,##0.00"
        ws.cell(row=i, column=4, value=f"=C{i}-B{i}").number_format = "#,##0.00"
        ws.cell(row=i, column=5, value=f'=IF(ABS(D{i})<0.01,"PASS","FAIL")')
    ws.conditional_formatting.add(f"E5:E{4 + len(checks)}", CellIsRule(operator="equal", formula=['"PASS"'], fill=PatternFill("solid", fgColor="C6EFCE")))
    ws.conditional_formatting.add(f"E5:E{4 + len(checks)}", CellIsRule(operator="equal", formula=['"FAIL"'], fill=PatternFill("solid", fgColor="F8CBAD")))
    widths(ws, {"A": 52, "B": 22, "C": 16, "D": 12, "E": 9})
    return checks


# ============================================================================== Power Query (MS-QDEFF)
BOM = b"\xef\xbb\xbf"


def section_m() -> str:
    types = ", ".join(f'{{"{c}", {M_TYPE[k]}}}' for c, k in COLUMNS)
    m = (
        "section Section1;\r\n\r\n"
        f'shared CsvFolder = "{CSV_FOLDER}" meta [IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true];\r\n\r\n'
        f"shared {QUERY} = let\r\n"
        f'    Source = Csv.Document(File.Contents(CsvFolder & "\\pmpm_monthly.csv"), [Delimiter=",", Columns={len(COLUMNS)}, Encoding=65001, QuoteStyle=QuoteStyle.Csv]),\r\n'
        '    #"Promoted Headers" = Table.PromoteHeaders(Source, [PromoteAllScalars=true]),\r\n'
        f'    #"Changed Type" = Table.TransformColumnTypes(#"Promoted Headers", {{{types}}}, "en-US")\r\n'
        "in\r\n"
        '    #"Changed Type";'
    )
    return m


def opc_zip(parts: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in parts.items():
            z.writestr(name, data)
    return buf.getvalue()


def data_mashup(n_rows: int) -> bytes:
    package = opc_zip({
        "Config/Package.xml": BOM + b'<?xml version="1.0" encoding="utf-8"?><Package xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
                                    b'xmlns:xsd="http://www.w3.org/2001/XMLSchema"><Version>2.141.0.0</Version><MinVersion>2.21.0.0</MinVersion>'
                                    b'<Culture>en-US</Culture></Package>',
        "[Content_Types].xml": BOM + b'<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                                     b'<Default Extension="xml" ContentType="text/xml" /><Default Extension="m" ContentType="application/x-ms-m" /></Types>',
        "Formulas/Section1.m": section_m().encode("utf-8"),
    })
    permissions = BOM + (b'<?xml version="1.0" encoding="utf-8"?><PermissionList xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
                         b'xmlns:xsd="http://www.w3.org/2001/XMLSchema"><CanEvaluateFuturePackages>false</CanEvaluateFuturePackages>'
                         b'<FirewallEnabled>true</FirewallEnabled><WorkbookGroupType xsi:nil="true" /></PermissionList>')
    # "Last refreshed" = when the CSV the query reads was written by the pipeline.
    csv_mtime = (Path(CSV_FOLDER) / "pmpm_monthly.csv").stat().st_mtime
    now = datetime.fromtimestamp(csv_mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.0000000Z")
    names = [c for c, _ in COLUMNS]
    names_json = "[" + ",".join(f'"{n}"' for n in names) + "]"
    idents = ",".join(f'"Section1/{QUERY}/Changed Type.{{{n},{i}}}"' for i, n in enumerate(names))
    rel_info = (f'{{"columnCount":{len(names)},"keyColumnNames":[],"queryRelationships":[],"columnIdentities":[{idents}],'
                f'"ColumnCount":{len(names)},"KeyColumnNames":[],"ColumnIdentities":[{idents}],"RelationshipInfo":[]}}')

    def entries(items):  # double-quoted attributes with &quot;, as Excel writes them
        return "".join(f'<Entry Type="{t}" Value="{escape(v, {chr(34): "&quot;"})}" />' for t, v in items)

    query_entries = [
        ("IsPrivate", "l0"), ("ResultType", "sTable"), ("FillEnabled", "l1"), ("FillObjectType", "sTable"),
        ("FillToDataModelEnabled", "l0"), ("FillCount", f"l{n_rows}"), ("FillErrorCount", "l0"), ("FillErrorCode", "sUnknown"),
        ("FillColumnNames", "s" + names_json), ("FillLastUpdated", "d" + now), ("RelationshipInfoContainer", "s" + rel_info),
        ("FilledCompleteResultToWorksheet", "l1"), ("AddedToDataModel", "l0"), ("RecoveryTargetSheet", "sPMPM_Data"),
        ("RecoveryTargetColumn", "l1"), ("RecoveryTargetRow", "l1"), ("NameUpdatedAfterFill", "l0"),
        ("FillTarget", "s" + TABLE), ("FillTargetNameCustomized", "l1"), ("NavigationStepName", "sNavigation"),
        ("BufferNextRefresh", "l1"), ("FillStatus", "sComplete"), ("QueryID", "s" + str(uuid.uuid5(NS, QUERY))),
    ]
    param_entries = [
        ("IsPrivate", "l0"), ("ResultType", "sText"), ("FillEnabled", "l0"), ("FillObjectType", "sConnectionOnly"),
        ("FillToDataModelEnabled", "l0"), ("NavigationStepName", "sNavigation"), ("BufferNextRefresh", "l1"),
        ("QueryID", "s" + str(uuid.uuid5(NS, "CsvFolder"))),
    ]
    meta_xml = BOM + (
        '<?xml version="1.0" encoding="utf-8"?><LocalPackageMetadataFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xmlns:xsd="http://www.w3.org/2001/XMLSchema"><Items>'
        '<Item><ItemLocation><ItemType>AllFormulas</ItemType><ItemPath /></ItemLocation><StableEntries /></Item>'
        f'<Item><ItemLocation><ItemType>Formula</ItemType><ItemPath>Section1/{QUERY}</ItemPath></ItemLocation>'
        f'<StableEntries>{entries(query_entries)}</StableEntries></Item>'
        f'<Item><ItemLocation><ItemType>Formula</ItemType><ItemPath>Section1/CsvFolder</ItemPath></ItemLocation>'
        f'<StableEntries>{entries(param_entries)}</StableEntries></Item>'
        '</Items></LocalPackageMetadataFile>'
    ).encode("utf-8")
    empty_zip = b"PK\x05\x06" + b"\x00" * 18
    metadata = struct.pack("<I", 0) + struct.pack("<I", len(meta_xml)) + meta_xml + struct.pack("<I", len(empty_zip)) + empty_zip
    bindings = b"\x00"  # [MS-QDEFF] 2.6: a single null byte is allowed; Excel then uses default privacy permissions.
    blob = struct.pack("<I", 0)
    for part in (package, permissions, metadata, bindings):
        blob += struct.pack("<I", len(part)) + part
    return blob


# ============================================================================== PivotTable XML
def pivot_parts(monthly, years):
    def num_items(values, integer=True):
        lo, hi = min(values), max(values)
        ci = ' containsInteger="1"' if integer else ""
        return f'<sharedItems containsSemiMixedTypes="0" containsString="0" containsNumber="1"{ci} minValue="{lo}" maxValue="{hi}"/>'

    col = {c: [r[i] for r in monthly] for i, (c, _) in enumerate(COLUMNS)}
    dates = col["month_start"]
    fields = [
        f'<cacheField name="month_start" numFmtId="14"><sharedItems containsSemiMixedTypes="0" containsNonDate="0" containsDate="1" '
        f'containsString="0" minDate="{min(dates):%Y-%m-%dT00:00:00}" maxDate="{max(dates):%Y-%m-%dT00:00:00}"/></cacheField>',
        f'<cacheField name="year" numFmtId="0"><sharedItems containsSemiMixedTypes="0" containsString="0" containsNumber="1" containsInteger="1" '
        f'minValue="{min(years)}" maxValue="{max(years)}" count="{len(years)}">' + "".join(f'<n v="{y}"/>' for y in years) + "</sharedItems></cacheField>",
        f'<cacheField name="month" numFmtId="0">{num_items(col["month"])}</cacheField>',
        '<cacheField name="year_month" numFmtId="0"><sharedItems/></cacheField>',
        f'<cacheField name="service_type" numFmtId="0"><sharedItems count="{len(SERVICE_TYPES)}">'
        + "".join(f"<s v={quoteattr(s)}/>" for s in SERVICE_TYPES) + "</sharedItems></cacheField>",
        '<cacheField name="benefit" numFmtId="0"><sharedItems/></cacheField>',
        f'<cacheField name="sort_order" numFmtId="0">{num_items(col["sort_order"])}</cacheField>',
        f'<cacheField name="member_months" numFmtId="0">{num_items(col["member_months"])}</cacheField>',
        f'<cacheField name="paid_amount" numFmtId="0">{num_items([float(v) for v in col["paid_amount"]], integer=False)}</cacheField>',
        f'<cacheField name="claim_count" numFmtId="0">{num_items(col["claim_count"])}</cacheField>',
        f'<cacheField name="pmpm" numFmtId="0">{num_items([float(v) for v in col["pmpm"]], integer=False)}</cacheField>',
        '<cacheField name="WeightedPMPM" numFmtId="0" formula="paid_amount/member_months" databaseField="0"/>',
    ]
    cache = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<pivotCacheDefinition xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        f'saveData="0" refreshOnLoad="1" createdVersion="8" refreshedVersion="8" minRefreshableVersion="3" recordCount="{len(monthly)}">'
        f'<cacheSource type="worksheet"><worksheetSource name="{TABLE}"/></cacheSource>'
        f'<cacheFields count="{len(fields)}">' + "".join(fields) + "</cacheFields></pivotCacheDefinition>"
    )
    n_rows, n_cols = len(SERVICE_TYPES), len(years)
    last_col = chr(ord("A") + n_cols + 1)  # row labels + years + grand total
    pivot_fields = []
    for i, (c, _) in enumerate(COLUMNS):
        if c == "year":
            pivot_fields.append(f'<pivotField axis="axisCol" showAll="0"><items count="{n_cols + 1}">'
                                + "".join(f'<item x="{k}"/>' for k in range(n_cols)) + '<item t="default"/></items></pivotField>')
        elif c == "service_type":
            pivot_fields.append(f'<pivotField axis="axisRow" showAll="0"><items count="{n_rows + 1}">'
                                + "".join(f'<item x="{k}"/>' for k in range(n_rows)) + '<item t="default"/></items></pivotField>')
        elif c == "month_start":
            pivot_fields.append('<pivotField numFmtId="14" showAll="0"/>')
        else:
            pivot_fields.append('<pivotField showAll="0"/>')
    pivot_fields.append('<pivotField dataField="1" dragToRow="0" dragToCol="0" dragToPage="0" showAll="0" defaultSubtotal="0"/>')
    item = lambda k: "<i><x/></i>" if k == 0 else f'<i><x v="{k}"/></i>'
    table = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<pivotTableDefinition xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" name="ptPMPM" cacheId="1" '
        'applyNumberFormats="0" applyBorderFormats="0" applyFontFormats="0" applyPatternFormats="0" applyAlignmentFormats="0" '
        'applyWidthHeightFormats="1" dataCaption="Values" updatedVersion="8" minRefreshableVersion="3" useAutoFormatting="1" '
        'itemPrintTitles="1" createdVersion="8" indent="0" outline="1" outlineData="1" multipleFieldFilters="0" '
        'colGrandTotals="0" rowHeaderCaption="Service type" colHeaderCaption="Year">'
        f'<location ref="A4:{last_col}{5 + n_rows}" firstHeaderRow="1" firstDataRow="2" firstDataCol="1"/>'
        f'<pivotFields count="{len(pivot_fields)}">' + "".join(pivot_fields) + "</pivotFields>"
        f'<rowFields count="1"><field x="{[c for c, _ in COLUMNS].index("service_type")}"/></rowFields>'
        f'<rowItems count="{n_rows}">' + "".join(item(k) for k in range(n_rows)) + "</rowItems>"
        f'<colFields count="1"><field x="{[c for c, _ in COLUMNS].index("year")}"/></colFields>'
        f'<colItems count="{n_cols + 1}">' + "".join(item(k) for k in range(n_cols)) + '<i t="grand"><x/></i></colItems>'
        f'<dataFields count="1"><dataField name="PMPM ($)" fld="{len(COLUMNS)}" baseField="0" baseItem="0" numFmtId="4"/></dataFields>'
        '<pivotTableStyleInfo name="PivotStyleMedium2" showRowHeaders="1" showColHeaders="1" showRowStripes="0" '
        'showColStripes="0" showLastColumn="1"/></pivotTableDefinition>'
    )
    return cache, table


# ============================================================================== package surgery
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
CT = {
    "pivotCache": "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheDefinition+xml",
    "pivotTable": "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotTable+xml",
    "connections": "application/vnd.openxmlformats-officedocument.spreadsheetml.connections+xml",
    "queryTable": "application/vnd.openxmlformats-officedocument.spreadsheetml.queryTable+xml",
    "itemProps": "application/vnd.openxmlformats-officedocument.customXmlProperties+xml",
}


def add_rel(xml: str, rid: str, rtype: str, target: str) -> str:
    return xml.replace("</Relationships>", f'<Relationship Id="{rid}" Type="{REL}/{rtype}" Target="{target}"/></Relationships>')


def empty_rels() -> str:
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>'


def inject(path: Path, monthly, years) -> None:
    with zipfile.ZipFile(path) as z:
        files = {n: z.read(n) for n in z.namelist()}
    text = lambda n: files[n].decode("utf-8")

    # locate the Pivot sheet part and the tblPMPM table part
    wb_xml, wb_rels = text("xl/workbook.xml"), text("xl/_rels/workbook.xml.rels")
    pivot_rid = re.search(r'<sheet\b[^>]*\bname="Pivot"[^>]*\br:id="(rId\d+)"', wb_xml).group(1)
    rel_el = next(el for el in re.findall(r"<Relationship\b[^>]*>", wb_rels) if f'Id="{pivot_rid}"' in el)
    pivot_sheet = "xl/" + re.search(r'Target="/?(?:xl/)?([^"]+)"', rel_el).group(1)
    table_part = next(n for n in files if n.startswith("xl/tables/") and f'name="{TABLE}"' in text(n))

    # --- Power Query: customXml DataMashup + connection + query table
    mashup = base64.b64encode(data_mashup(len(monthly))).decode("ascii")
    files["customXml/item1.xml"] = ('<?xml version="1.0" encoding="utf-16"?><DataMashup xmlns="http://schemas.microsoft.com/DataMashup">'
                                    + mashup + "</DataMashup>").encode("utf-16")
    files["customXml/itemProps1.xml"] = (
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
        f'<ds:datastoreItem ds:itemID="{{{str(uuid.uuid5(NS, "datastore")).upper()}}}" '
        'xmlns:ds="http://schemas.openxmlformats.org/officeDocument/2006/customXml"><ds:schemaRefs>'
        '<ds:schemaRef ds:uri="http://schemas.microsoft.com/DataMashup"/></ds:schemaRefs></ds:datastoreItem>').encode("utf-8")
    files["customXml/_rels/item1.xml.rels"] = add_rel(empty_rels(), "rId1", "customXmlProps", "itemProps1.xml").encode("utf-8")
    files["xl/connections.xml"] = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<connections xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        f'<connection id="1" keepAlive="1" name="Query - {QUERY}" description={quoteattr(f"Connection to the {QUERY!r} query in the workbook.")} '
        'type="5" refreshedVersion="8" background="1" saveData="1">'
        f'<dbPr connection="Provider=Microsoft.Mashup.OleDb.1;Data Source=$Workbook$;Location={QUERY};Extended Properties=&quot;&quot;" '
        f'command="SELECT * FROM [{QUERY}]"/></connection></connections>').encode("utf-8")
    fields = "".join(f'<queryTableField id="{i}" name="{c}" tableColumnId="{i}"/>' for i, (c, _) in enumerate(COLUMNS, start=1))
    files["xl/queryTables/queryTable1.xml"] = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<queryTable xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" name="ExternalData_1" connectionId="1" '
        'autoFormatId="16" applyNumberFormats="0" applyBorderFormats="0" applyFontFormats="0" applyPatternFormats="0" '
        'applyAlignmentFormats="0" applyWidthHeightFormats="0">'
        f'<queryTableRefresh nextId="{len(COLUMNS) + 1}"><queryTableFields count="{len(COLUMNS)}">{fields}</queryTableFields>'
        '</queryTableRefresh></queryTable>').encode("utf-8")
    tbl = text(table_part)
    tbl = re.sub(r"<table ", '<table tableType="queryTable" ', tbl, count=1) if "tableType=" not in tbl else tbl
    for i, (c, _) in enumerate(COLUMNS, start=1):
        tbl = re.sub(rf'<tableColumn id="{i}" name="{c}"', f'<tableColumn id="{i}" uniqueName="{i}" name="{c}" queryTableFieldId="{i}"', tbl)
    files[table_part] = tbl.encode("utf-8")
    table_rels = table_part.replace("xl/tables/", "xl/tables/_rels/") + ".rels"
    files[table_rels] = add_rel(files.get(table_rels, empty_rels().encode()).decode(), "rIdQT1", "queryTable",
                                "../queryTables/queryTable1.xml").encode("utf-8")

    # --- PivotTable on the Pivot sheet
    cache_xml, pivot_xml = pivot_parts(monthly, years)
    files["xl/pivotCache/pivotCacheDefinition1.xml"] = cache_xml.encode("utf-8")
    files["xl/pivotTables/pivotTable1.xml"] = pivot_xml.encode("utf-8")
    files["xl/pivotTables/_rels/pivotTable1.xml.rels"] = add_rel(empty_rels(), "rId1", "pivotCacheDefinition",
                                                                 "../pivotCache/pivotCacheDefinition1.xml").encode("utf-8")
    sheet_rels = pivot_sheet.replace("xl/worksheets/", "xl/worksheets/_rels/") + ".rels"
    files[sheet_rels] = add_rel(files.get(sheet_rels, empty_rels().encode()).decode(), "rIdPT1", "pivotTable",
                                "../pivotTables/pivotTable1.xml").encode("utf-8")

    # --- workbook: relationships + pivotCaches
    wb_rels = add_rel(wb_rels, "rIdPC1", "pivotCacheDefinition", "pivotCache/pivotCacheDefinition1.xml")
    wb_rels = add_rel(wb_rels, "rIdCN1", "connections", "connections.xml")
    wb_rels = add_rel(wb_rels, "rIdCX1", "customXml", "../customXml/item1.xml")
    files["xl/_rels/workbook.xml.rels"] = wb_rels.encode("utf-8")
    pivot_caches = '<pivotCaches><pivotCache cacheId="1" r:id="rIdPC1"/></pivotCaches>'
    wb_xml = re.sub(r"(<calcPr[^>]*/>)", r"\1" + pivot_caches, wb_xml, count=1)
    files["xl/workbook.xml"] = wb_xml.encode("utf-8")

    # --- styles: openpyxl writes <font> children in its own order; put them in the schema order Excel writes.
    font_order = ["b", "i", "strike", "condense", "extend", "outline", "shadow", "u", "vertAlign", "sz", "color", "name", "family", "charset", "scheme"]

    def reorder_font(m: re.Match) -> str:
        kids = re.findall(r"<(\w+)\b[^>]*/>", m.group(2))
        tags = re.findall(r"<\w+\b[^>]*/>", m.group(2))
        ordered = [t for _, t in sorted(zip(kids, tags), key=lambda kt: font_order.index(kt[0]) if kt[0] in font_order else 99)]
        return m.group(1) + "".join(ordered) + m.group(3)

    files["xl/styles.xml"] = re.sub(r"(<font>)(.*?)(</font>)", reorder_font, text("xl/styles.xml"), flags=re.S).encode("utf-8")

    # --- workbook theme colors
    theme = text("xl/theme/theme1.xml")
    for slot, hex_ in THEME_COLORS.items():
        theme = re.sub(rf"<a:{slot}>.*?</a:{slot}>", f'<a:{slot}><a:srgbClr val="{hex_}"/></a:{slot}>', theme, count=1, flags=re.S)
    theme = re.sub(r'(<a:clrScheme name=")[^"]*"', r'\1HCareLedger"', theme, count=1)
    files["xl/theme/theme1.xml"] = theme.encode("utf-8")

    # --- content types
    ct = text("[Content_Types].xml")
    overrides = [("/xl/pivotCache/pivotCacheDefinition1.xml", CT["pivotCache"]), ("/xl/pivotTables/pivotTable1.xml", CT["pivotTable"]),
                 ("/xl/connections.xml", CT["connections"]), ("/xl/queryTables/queryTable1.xml", CT["queryTable"]),
                 ("/customXml/itemProps1.xml", CT["itemProps"])]
    ct = ct.replace("</Types>", "".join(f'<Override PartName="{p}" ContentType="{t}"/>' for p, t in overrides) + "</Types>")
    files["[Content_Types].xml"] = ct.encode("utf-8")

    order = ["[Content_Types].xml"] + [n for n in files if n != "[Content_Types].xml"]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for n in order:
            z.writestr(n, files[n])


def write_docs(monthly, budget, year=2022) -> None:
    """docs/excel.md: what the workbook contains, how it was built and checked, and the selected-year result."""
    bud = {k: v for k, _, _, _, _, v in budget}
    lines = []
    for s in MEDICAL + ["Total Medical", "Part D"]:
        if s == "Total Medical":
            mm = sum(r[7] for r in monthly if r[1] == year and r[4] == "Inpatient")
            paid = sum(float(r[8]) for r in monthly if r[1] == year and r[5] != "Part D")
            b = sum(bud[f"{year}|{x}"] for x in MEDICAL)
        else:
            mm = sum(r[7] for r in monthly if r[1] == year and r[4] == s)
            paid = sum(float(r[8]) for r in monthly if r[1] == year and r[4] == s)
            b = bud[f"{year}|{s}"]
        a = paid / mm
        usd = lambda x, d=2: f"{'+' if x >= 0 else '-'}${abs(x):,.{d}f}"
        lines.append(f"| {s} | ${a:,.2f} | ${b:,.2f} | {usd(a - b)} | {100 * (a - b) / b:+.1f}% | {usd(paid - b * mm, 0)} | "
                     f"{'Unfavorable' if a > b else 'Favorable'} |")
    text = "\n".join([
        "# Excel workbook for finance",
        "",
        "_Generated by `pipeline/excel.py`._",
        "",
        "`excel/HCareLedger_PMPM_Budget.xlsx`: monthly PMPM loaded by Power Query, a PivotTable by service type, and an",
        "XLOOKUP budget-vs-actual variance sheet. Synthetic data: the numbers demonstrate the method only.",
        "",
        "| Sheet | What it does |",
        "| --- | --- |",
        f"| Variance | Pick a year (C5). Actual PMPM by `SUMIFS` on `{TABLE}`, budget PMPM by `XLOOKUP(year & \"\\|\" & service type, tblBudget[key], ...)`, PMPM and $ variance, favorable/unfavorable flags, prior-year PMPM and YoY. |",
        f"| Pivot | PivotTable `ptPMPM` on `{TABLE}`: service type x year with a calculated field `paid_amount / member_months`, so PMPM is weighted correctly. Row grand total = full-window PMPM. Refreshes on open. |",
        "| Budget | Trend assumptions (editable inputs) and `tblBudget`: budget PMPM = prior-year actual PMPM x (1 + trend), the trend found with `XLOOKUP`. |",
        f"| PMPM_Data | `{TABLE}`, the output of the Power Query `{QUERY}` (768 rows: 96 months x 8 service types). |",
        "| Checks | Formulas that reconcile the workbook to the SQL pipeline; cell A2 says whether all pass. |",
        "",
        "## Power Query",
        "",
        f"`{QUERY}` reads `outputs/reports/pmpm_monthly.csv` from the folder in the text parameter `CsvFolder`, promotes",
        "headers and sets column types. To refresh on another machine: **Data > Queries & Connections**, edit `CsvFolder`,",
        "then **Refresh All**.",
        "",
        "```m",
        section_m().replace("\r\n", "\n"),
        "```",
        "",
        f"## Budget vs actual, {year}",
        "",
        "What the Variance sheet shows with the default year. Budget = prior-year actual PMPM x (1 + trend).",
        "",
        "| Service type | Actual PMPM | Budget PMPM | PMPM variance | Variance % | $ variance | Status |",
        "| --- | --- | --- | --- | --- | --- | --- |",
        *lines,
        "",
        "Trend assumptions: " + ", ".join(f"{s} {100 * t:.1f}%" for s, t in TREND.items()) + ".",
        "",
        "## Colors",
        "",
        "The workbook theme uses the same palette as the Power BI report (navy and teal chrome; accents 1-6 = the first six",
        "series colors from `pipeline/powerbi.py`), so built-in table and PivotTable styles and any chart you add match the",
        "report. Sheet tabs: navy = report sheets, teal = budget inputs, gray = data and checks. Yellow cells are inputs.",
        "",
        "## How the file is built and checked",
        "",
        "openpyxl writes the sheets, tables, formulas, validation and conditional formatting. openpyxl cannot create a",
        "Power Query or a PivotTable, so `pipeline/excel.py` adds those as Office Open XML parts:",
        "",
        "- **Power Query**: the query definition is a `DataMashup` blob in `customXml/item1.xml`, built to [MS-QDEFF]",
        "  (package parts, permissions, metadata, and a 1-byte permission binding, which the spec allows). A connection in",
        "  `xl/connections.xml` and a query table bound to `tblPMPM` make the table the query's load target.",
        "- **PivotTable**: a pivot cache over `tblPMPM` (refresh on load, no saved records) and the pivot definition.",
        "  The rendered values are also written to the sheet, so the pivot reads correctly in Protected View.",
        "",
        "The workbook passes the Open XML SDK validator (Office 2016 and Microsoft 365 rules) with zero errors, and the",
        "DataMashup decodes to the same structure as the example in the [MS-QDEFF] specification. Excel itself was not",
        "available when this file was built: open it once in Excel 365, confirm Checks!A2 reads \"All checks pass\", and",
        "try **Refresh All**.",
        "",
    ])
    (ROOT / "docs" / "excel.md").write_text(text, encoding="utf-8", newline="\n")


def main() -> None:
    con = duckdb.connect(str(DB_PATH), read_only=True)
    monthly, yearly = load(con)
    con.close()
    budget = budget_rows(yearly)

    wb = Workbook()
    sheet_readme(wb)
    sheet_budget(wb, budget)
    sheet_data(wb, monthly)
    sheet_variance(wb)            # inserted at position 1
    years = sheet_pivot(wb, monthly)  # inserted at position 2
    checks = sheet_checks(wb, monthly, yearly, budget)
    wb.calculation.fullCalcOnLoad = True
    for ws in wb.worksheets:      # exactly one selected tab, or Excel opens with sheets grouped
        ws.sheet_view.tabSelected = ws.title == "Variance"
        ws.sheet_properties.tabColor = TAB_COLORS[ws.title]
    wb.active = wb.sheetnames.index("Variance")
    OUT.parent.mkdir(exist_ok=True)
    wb.save(OUT)
    inject(OUT, monthly, years)
    write_docs(monthly, budget)

    # Python-side self-check: the expected values on the Checks sheet must match the workbook's own logic.
    for name, expected, _ in checks:
        m = re.match(r"Total medical PMPM (\d{4})", name)
        if m:
            y = int(m.group(1))
            calc = sum(float(r[8]) for r in monthly if r[1] == y and r[5] != "Part D") / sum(r[7] for r in monthly if r[1] == y and r[4] == "Inpatient")
            assert abs(calc - expected) < 0.01, (name, calc, expected)
    print(f"wrote {OUT.relative_to(ROOT)}: {len(monthly)} data rows, {len(budget)} budget rows, {len(checks)} checks, "
          f"pivot {len(SERVICE_TYPES)} x {len(years)}, Power Query {QUERY}")


if __name__ == "__main__":
    main()
