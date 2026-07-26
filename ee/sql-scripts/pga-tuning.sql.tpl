-- pga-tuning.sql.tpl
-- OPTIONAL. Not run automatically by run-ee.sh or the full-cycle test.
--
-- Explicit PGA/SGA tuning — only useful once/if the DOCKER_IMAGE has been
-- swapped to Enterprise Edition (see ee/.env.sample). Plain Database Free's
-- 2GB combined SGA+PGA cap is a hard vendor limit that ALTER SYSTEM cannot
-- raise; running this against Free will simply hit ORA-02097/ORA-00384 or
-- silently be capped back down.
--
-- Run manually as SYS/SYSDBA if load testing (see the ee POC plan's
-- Validation section) shows PGA pressure is still a problem on EE with its
-- own default AUTO_MEM_CALCULATION sizing:
--   sqlplus -s "sys/<ORACLE_PWD>@//localhost:1521/<ORACLE_PDB> as sysdba" @pga-tuning.sql
--
-- Substitution tokens (replaced by hand, or by run-ee.sh if invoked with -v):
--   __PGA_AGGREGATE_LIMIT__ — e.g. 0 (disables the hard cap) or a size like 8G
--   __SGA_TARGET__          — e.g. 4G

SET SERVEROUTPUT ON;

ALTER SYSTEM SET PGA_AGGREGATE_LIMIT=__PGA_AGGREGATE_LIMIT__ SCOPE=BOTH;
ALTER SYSTEM SET SGA_TARGET=__SGA_TARGET__ SCOPE=BOTH;

PROMPT PGA/SGA tuning applied. Current values:
SHOW PARAMETER pga_aggregate_limit;
SHOW PARAMETER sga_target;
exit;
