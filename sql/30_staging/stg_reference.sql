-- Staging: reference data.
create schema if not exists stg;

-- FY2023 ICD-10-CM order file. Fixed width per CMS/NCHS layout:
--   1-5 order number | 7-13 code | 15 billable flag (1 = valid for claims) | 17-76 short desc | 78+ long desc
-- Includes non-billable headers (3-character categories and subcategories), which lets diagnosis codes
-- that are truncated in the synthetic data still roll up to a described category.
create or replace table stg.icd10cm as
select trim(substr(line, 7, 7))       as icd10_code,
       substr(line, 15, 1) = '1'      as is_billable,
       trim(substr(line, 17, 60))     as short_description,
       trim(substr(line, 78))         as long_description
from raw.icd10cm_order
where length(line) > 16;

-- ICD-10-CM chapters (FY2023), compared on the 3-character category.
create or replace table stg.icd10cm_chapter as
select * from (values
    (1,  'A00', 'B99', 'Certain infectious and parasitic diseases'),
    (2,  'C00', 'D49', 'Neoplasms'),
    (3,  'D50', 'D89', 'Diseases of the blood and immune mechanism'),
    (4,  'E00', 'E89', 'Endocrine, nutritional and metabolic diseases'),
    (5,  'F01', 'F99', 'Mental, behavioral and neurodevelopmental disorders'),
    (6,  'G00', 'G99', 'Diseases of the nervous system'),
    (7,  'H00', 'H59', 'Diseases of the eye and adnexa'),
    (8,  'H60', 'H95', 'Diseases of the ear and mastoid process'),
    (9,  'I00', 'I99', 'Diseases of the circulatory system'),
    (10, 'J00', 'J99', 'Diseases of the respiratory system'),
    (11, 'K00', 'K95', 'Diseases of the digestive system'),
    (12, 'L00', 'L99', 'Diseases of the skin and subcutaneous tissue'),
    (13, 'M00', 'M99', 'Diseases of the musculoskeletal system and connective tissue'),
    (14, 'N00', 'N99', 'Diseases of the genitourinary system'),
    (15, 'O00', 'O9A', 'Pregnancy, childbirth and the puerperium'),
    (16, 'P00', 'P96', 'Certain conditions originating in the perinatal period'),
    (17, 'Q00', 'Q99', 'Congenital malformations and chromosomal abnormalities'),
    (18, 'R00', 'R99', 'Symptoms, signs and abnormal findings, not elsewhere classified'),
    (19, 'S00', 'T88', 'Injury, poisoning and other consequences of external causes'),
    (20, 'V00', 'Y99', 'External causes of morbidity'),
    (21, 'Z00', 'Z99', 'Factors influencing health status and contact with health services'),
    (22, 'U00', 'U85', 'Codes for special purposes')
) as t(chapter_number, range_start, range_end, chapter_description);
