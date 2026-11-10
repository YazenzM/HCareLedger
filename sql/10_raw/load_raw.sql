-- Raw layer: a lossless, all-VARCHAR copy of every source file.
-- Nothing is cast or cleaned here, so profiling can measure exactly what CMS shipped.
-- {{raw_dir}} is substituted by pipeline/build.py.

create schema if not exists raw;

create or replace table raw.beneficiary as
select * exclude (filename), regexp_extract(filename, 'beneficiary_(\d{4})', 1) as _file_year, filename as _source_file
from read_csv('{{raw_dir}}/beneficiary/beneficiary_*.csv', delim = '|', header = true, all_varchar = true, filename = true);

create or replace table raw.carrier as
select * from read_csv('{{raw_dir}}/carrier/carrier.csv', delim = '|', header = true, all_varchar = true);

create or replace table raw.dme as
select * from read_csv('{{raw_dir}}/dme/dme.csv', delim = '|', header = true, all_varchar = true);

create or replace table raw.inpatient as
select * from read_csv('{{raw_dir}}/inpatient/inpatient.csv', delim = '|', header = true, all_varchar = true);

create or replace table raw.outpatient as
select * from read_csv('{{raw_dir}}/outpatient/outpatient.csv', delim = '|', header = true, all_varchar = true);

create or replace table raw.snf as
select * from read_csv('{{raw_dir}}/snf/snf.csv', delim = '|', header = true, all_varchar = true);

create or replace table raw.hha as
select * from read_csv('{{raw_dir}}/hha/hha.csv', delim = '|', header = true, all_varchar = true);

create or replace table raw.hospice as
select * from read_csv('{{raw_dir}}/hospice/hospice.csv', delim = '|', header = true, all_varchar = true);

create or replace table raw.pde as
select * from read_csv('{{raw_dir}}/pde/pde.csv', delim = '|', header = true, all_varchar = true);

-- Reference: FY2023 ICD-10-CM order file (fixed width; parsed in staging).
create or replace table raw.icd10cm_order as
select line from read_csv('{{raw_dir}}/icd10cm/icd10cm-order-2023.txt',
    delim = '\t', quote = '', escape = '', header = false, columns = {'line': 'VARCHAR'}, encoding = 'latin-1');
