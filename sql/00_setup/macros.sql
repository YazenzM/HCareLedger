-- Shared macros and project constants. Every later step depends on these.

-- CMS synthetic files write dates as '14-May-2022'. try_strptime returns NULL instead of failing,
-- so unparseable values surface in profiling rather than aborting the load.
create or replace macro parse_dt(x) as try_strptime(x, '%d-%b-%Y')::date;

-- Money is held as DECIMAL(18,2) so sums are exact (no floating-point drift in finance outputs).
create or replace macro money(x) as try_cast(x as decimal(18, 2));

-- Integer surrogate for a date, e.g. 2022-05-14 -> 20220514. Used as the join key to dim_date.
create or replace macro date_key(d) as (year(d) * 10000 + month(d) * 100 + day(d))::integer;

-- Reporting window. Claims start 2015-03-06 and the last processed week is 2023-03-03,
-- so the first and last complete months of claims experience are Mar-2015 and Feb-2023.
-- Member months and claims outside this window are excluded from every rate.
create or replace macro window_start() as date '2015-03-01';
create or replace macro window_end() as date '2023-02-28';
