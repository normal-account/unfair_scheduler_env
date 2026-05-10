CREATE UNLOGGED TABLE IF NOT EXISTS udf_runs (
    worker_id       text PRIMARY KEY,
    completed_runs  bigint NOT NULL DEFAULT 0,
    started_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_completed  timestamptz
);

GRANT USAGE ON SCHEMA public TO "aida-user";
GRANT SELECT ON TABLE public.udf_runs TO "aida-user";

CREATE OR REPLACE PROCEDURE tpch_q17_worker(
    p_worker_id text,
    p_flush_every integer DEFAULT 1
)
LANGUAGE plpgsql
AS $$
DECLARE
    result numeric;
    v_local_completed bigint := 0;
BEGIN
    INSERT INTO udf_runs(worker_id, completed_runs, started_at, last_completed)
    VALUES (p_worker_id, 0, clock_timestamp(), NULL)
    ON CONFLICT (worker_id) DO NOTHING;

    COMMIT;

    LOOP
        SELECT SUM(l_extendedprice) / 7.0
        INTO result
        FROM lineitem
        JOIN part ON p_partkey = l_partkey
        WHERE p_brand = 'Brand#23'
          AND p_container = 'MED BOX'
          AND l_quantity < (
              SELECT 0.2 * AVG(l_quantity)
              FROM lineitem
              WHERE l_partkey = p_partkey
          );

        v_local_completed := v_local_completed + 1;

        IF v_local_completed >= p_flush_every THEN
            UPDATE udf_runs
            SET completed_runs = completed_runs + v_local_completed,
                last_completed = clock_timestamp()
            WHERE worker_id = p_worker_id;

            v_local_completed := 0;
            COMMIT;
        END IF;

        result := NULL;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION continuous_ycsb(start_id BIGINT DEFAULT 0, end_id BIGINT DEFAULT 100000)
RETURNS void AS $$
DECLARE
    i BIGINT;
    result RECORD;
BEGIN
    LOOP
      i := start_id;
      WHILE i < end_id LOOP
          -- Run the YCSB-style SELECT
          SELECT * INTO result FROM usertable WHERE ycsb_key = i;
          result := NULL;

          i := i + 1;
      END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION iterative_ycsb_udf(
  start_id BIGINT DEFAULT 0,
  end_id   BIGINT DEFAULT 100000
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    i BIGINT;
    iters_in_window BIGINT := 0;
    next_tick timestamptz;
BEGIN
    -- first tick one second from now
    next_tick := clock_timestamp() + interval '1 second';

    LOOP
        i := start_id;
        WHILE i < end_id LOOP
            -- YCSB-style lookup (no need to fetch a row into a RECORD)
            PERFORM 1 FROM usertable WHERE ycsb_key = i;

            i := i + 1;
            iters_in_window := iters_in_window + 1;

            -- once per second: report and reset
            IF clock_timestamp() >= next_tick THEN
                RAISE NOTICE 'iterations in last second: % * 10⁴', iters_in_window / 10000;
                iters_in_window := 0;

                -- advance the tick without drift; catch up if we’re late
                LOOP
                    next_tick := next_tick + interval '1 second';
                    EXIT WHEN clock_timestamp() < next_tick;
                END LOOP;
            END IF;
        END LOOP;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION cpu_spin_continuous(iterations_per_burst BIGINT DEFAULT 1000000,
                                               seed BIGINT DEFAULT 1)
RETURNS void
LANGUAGE plpgsql
PARALLEL SAFE
AS $$
DECLARE
    i   BIGINT;
    a   double precision := GREATEST(1e-6, seed::double precision);
BEGIN
    LOOP
        i := 0;
        WHILE i < iterations_per_burst LOOP
            -- Pure CPU math; keeps values bounded to avoid overflow/NaNs.
            a := ln(a) + sqrt(a * a + 3.141592653589793);
            a := a - floor(a);        -- keep 0 <= a < 1
            a := a + 1e-6;            -- avoid ln(0)
            i := i + 1;
        END loop;

        -- continue forever; no RAISE/NOTICE to avoid I/O
    END LOOP;
END;
$$;
