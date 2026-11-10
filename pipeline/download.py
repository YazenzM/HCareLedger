"""Download the CMS Synthetic Medicare Claims PUFs (May 2023 release) into data/raw/.

Source: https://data.cms.gov/collection/synthetic-medicare-enrollment-fee-for-service-claims-and-prescription-drug-event
The files are synthetic. CMS states that payment amounts and other values do not match
real Medicare data, so everything built on them demonstrates a method, not facts about Medicare.

Usage:  .venv\\Scripts\\python.exe -I pipeline\\download.py [--force]
"""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw"
CMS = "https://data.cms.gov/sites/default/files/2023-04"
CDC = "https://ftp.cdc.gov/pub/health_statistics/nchs/publications/ICD10CM/2023"

# name -> (URL, kind). Zips are extracted into data/raw/<name>/.
FILES: dict[str, tuple[str, str]] = {
    "carrier": (f"{CMS}/b6fe03a8-82e2-49b7-a9fe-9eb68c8ac4d0/Carrier.zip", "zip"),
    "outpatient": (f"{CMS}/c3d8a962-c6b8-4a59-adb5-f0495cc81fda/Outpatient.zip", "zip"),
    "inpatient": (f"{CMS}/67157de9-d962-4af0-bf0e-3578b3afec58/inpatient.csv", "csv"),
    "snf": (f"{CMS}/1138e453-f79d-4bd9-8561-26a7d7a7cc36/snf.csv", "csv"),
    "hha": (f"{CMS}/cf87867a-c878-4709-84f4-29be1b07ae5b/hha.csv", "csv"),
    "hospice": (f"{CMS}/72c61730-dcb4-4246-af69-f573c997e5dd/hospice.csv", "csv"),
    "dme": (f"{CMS}/647931dd-f8ea-423a-98a3-655e586a7c1f/dme.csv", "csv"),
    "pde": (f"{CMS}/a3969dcf-0799-49fe-8380-9eef788d5ac4/pde.csv", "csv"),
    "beneficiary": (f"{CMS}/250e6ca0-3515-4767-957c-5528bfcee75c/All%20Beneficiary%20Years.zip", "zip"),
    # Reference: FY2023 ICD-10-CM order file (all codes incl. 3-char category headers, with billable flag).
    "icd10cm": (f"{CDC}/icd10-Order-CodeFiles2023.zip", "zip"),
}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url: str, dest: Path) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "hcareledger-downloader/1.0"})
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(req, timeout=300) as resp, tmp.open("wb") as out:
        shutil.copyfileobj(resp, out, length=1 << 20)
    tmp.replace(dest)


def safe_extract(zip_path: Path, target: Path) -> list[str]:
    """Extract a zip, refusing any member that would land outside `target` (zip-slip guard)."""
    target.mkdir(parents=True, exist_ok=True)
    root = target.resolve()
    names = []
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.infolist():
            if member.is_dir():
                continue
            dest = (target / member.filename).resolve()
            if root not in dest.parents:
                raise RuntimeError(f"Refusing unsafe zip member: {member.filename!r}")
            dest.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(member) as src, dest.open("wb") as out:
                shutil.copyfileobj(src, out, length=1 << 20)
            names.append(str(dest.relative_to(RAW)))
    return names


def main(force: bool = False) -> None:
    RAW.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for name, (url, kind) in FILES.items():
        fname = url.rsplit("/", 1)[1].replace("%20", "_")
        dest = RAW / "_downloads" / fname
        dest.parent.mkdir(parents=True, exist_ok=True)
        if force or not dest.exists():
            print(f"downloading {name:12s} {url}")
            fetch(url, dest)
        else:
            print(f"cached      {name:12s} {dest.name}")
        entry = {"url": url, "file": str(dest.relative_to(RAW)), "bytes": dest.stat().st_size, "sha256": sha256(dest)}
        if kind == "zip":
            entry["extracted"] = safe_extract(dest, RAW / name)
        else:
            out = RAW / name / fname
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(dest, out)
            entry["extracted"] = [str(out.relative_to(RAW))]
        manifest[name] = entry
    (RAW / "manifest.json").write_text(json.dumps(manifest, indent=2))
    for name, e in manifest.items():
        print(f"{name:12s} {e['bytes'] / 1e6:8.1f} MB -> {', '.join(e['extracted'])}")


if __name__ == "__main__":
    main(force="--force" in sys.argv)
