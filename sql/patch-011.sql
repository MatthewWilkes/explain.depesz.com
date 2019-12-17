BEGIN;
--- This patch migrates explain.depesz.com plans database to native partitions with hash partitioning (available since Pg 11).

-- Move old data aside
ALTER TABLE plans RENAME TO old_plans;
ALTER SCHEMA plans rename to old_plans;

-- Make new master TABLE
CREATE TABLE public.plans (
    like old_plans including all
) PARTITION BY HASH (id);
CREATE SCHEMA plans;

-- Make new partitions
do $$
declare
    v_i INT4;
    v_sql TEXT;
BEGIN
    for v_i in 0..49 LOOP
        v_sql := format('CREATE TABLE plans.%I partition OF public.plans FOR VALUES WITH (MODULUS 50, REMAINDER %s);', 'part_' || v_i, v_i);
        raise notice '%', v_sql;
        execute v_sql;
    END loop;
END;
$$ language plpgsql;

-- Copy data FROM old partitions to new
do $$
declare
    v_source TEXT;
    v_sql TEXT;
    v_start timestamptz;
    v_count INT4;
    v_i INT4 := 0;
BEGIN
    SELECT count(*) INTO v_count FROM pg_class  WHERE relnamespace = 'old_plans'::regnamespace AND relkind = 'r' AND relname ~ '^part_.$';
    for v_source IN SELECT relname FROM pg_class  WHERE relnamespace = 'old_plans'::regnamespace AND relkind = 'r' AND relname ~ '^part_.$' ORDER BY relname LOOP
        v_i := v_i + 1;
        raise notice 'Starting transfer from % (% of %).', v_source, v_i, v_count;
        v_sql := format('INSERT INTO plans SELECT * FROM old_plans.%I', v_source);
        v_start := clock_timestamp();
        execute v_sql;
        raise notice 'Transfer from % finished in % seconds.', v_source, extract(epoch FROM (clock_timestamp() - v_start))::numeric(5,2);
    END loop;
END;
$$ language plpgsql;

-- Simplify register_plan that is not optiomization.
DROP function public.register_plan(in_title text, in_plan text, in_is_public boolean, in_is_anonymized boolean, in_username text);
CREATE OR REPLACE FUNCTION public.register_plan(in_title text, in_plan text, in_is_public boolean, in_is_anonymized boolean, in_username text)
 RETURNS register_plan_return
 LANGUAGE sql
AS $function$
SELECT public.register_plan(in_title, in_plan, in_is_public, in_is_anonymized, in_username, NULL);
$function$;

-- Make new register_plan, so that it doesn't touch partitions.
CREATE OR REPLACE FUNCTION public.register_plan(in_title text, in_plan text, in_is_public boolean, in_is_anonymized boolean, in_username text, in_optimization_for text)
 RETURNS register_plan_return
 LANGUAGE plpgsql
AS $function$
DECLARE
    use_hash_length int4 := 2;
    reply register_plan_return;
    insert_sql TEXT;
BEGIN
    insert_sql := 'INSERT INTO public.plans (id, title, plan, is_public, entered_on, is_anonymized, delete_key, added_by, optimization_for) VALUES ($1, $2, $3, $4, now(), $5, $6, $7, $8 )';
    reply.delete_key := get_random_string( 50 );
    LOOP
        reply.id := get_random_string(use_hash_length);
        BEGIN
            execute insert_sql using reply.id, in_title, in_plan, in_is_public, in_is_anonymized, reply.delete_key, in_username, in_optimization_for;
            RETURN reply;
        EXCEPTION WHEN unique_violation THEN
            -- do nothing
        END;
        use_hash_length := use_hash_length + 1;
        IF use_hash_length >= 30 THEN
            raise exception 'Random string of length == 30 requested. something''s wrong.';
        END IF;
    END LOOP;
END;
$function$;

commit;

\echo Vacuuming new plans...

vacuum analyze plans;

\echo Re-creating views

\i patch-008.sql

\echo Remember to remove old_plans schema, and public.old_plans table.
\echo To do it, you can run:
\echo DROP SCHEMA old_plans CASCADE;
\echo DROP TABLE public.old_plans;

--- vim: set filetype=sql textwidth=132:
