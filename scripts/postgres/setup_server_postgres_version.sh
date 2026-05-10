#!/bin/bash

. /home/build/postgres_baseline/env.sh # Setup the env vars

# Start the database server.
initdb -d $PGDATADIR
mkdir -p $PGLOGDIR
pg_ctl start -D $PGDATADIR -l $PGLOGDIR/postgres.log -o -i

# creating benchbase creds so the default config can be used
$POSTGRESQL/bin/psql postgres -c "CREATE DATABASE benchbase;"
$POSTGRESQL/bin/psql postgres -c "CREATE USER admin WITH ENCRYPTED PASSWORD 'password';"
$POSTGRESQL/bin/psql postgres -c "GRANT ALL PRIVILEGES ON DATABASE benchbase TO admin;"
$POSTGRESQL/bin/psql -d benchbase -c "GRANT EXECUTE ON FUNCTION pg_reload_conf() TO admin;"
$POSTGRESQL/bin/psql -d benchbase -c "ALTER SCHEMA public OWNER TO admin;"

$POSTGRESQL/bin/psql -d benchbase < /home/build/postgres/create_udf_funcs.sql

    # # Install python language directly into the template.
    # $POSTGRESQL/bin/psql -d template1 -c  "CREATE LANGUAGE plpython3u;"
    # $POSTGRESQL/bin/psql -d template1 -c "UPDATE pg_language SET lanpltrusted = true  WHERE lanname LIKE 'plpython3u';"

    # unzip data.zip
    # rm data.zip
    # # database test01
    # $POSTGRESQL/bin/psql postgres -c "create user test01 password 'test01';"
    # $POSTGRESQL/bin/psql postgres -c "create database test01 owner test01;"
    # $POSTGRESQL/bin/psql postgres -c "alter user test01 WITH SUPERUSER;"
    # $POSTGRESQL/bin/psql test01 -U test01 -c "create schema authorization test01;"
    # cd /home/build/postgres/data/test01/
    # ./load.sh

    # # database bixi
    # $POSTGRESQL/bin/psql postgres -c "create user bixi password 'bixi'"
    # $POSTGRESQL/bin/psql postgres -c "create database bixi owner bixi;"
    # $POSTGRESQL/bin/psql postgres -c "alter user bixi WITH SUPERUSER;"
    # $POSTGRESQL/bin/psql bixi -U bixi -c "create schema authorization bixi;"
    # cd /home/build/postgres/data/bixi/
    # ./load.sh

    # # database sf00 and sf01 for TPCH Benchmark
    # $POSTGRESQL/bin/psql postgres -c "create user sf00 password 'sf00'"
    # $POSTGRESQL/bin/psql postgres -c "create database sf00 owner sf00;"
    # $POSTGRESQL/bin/psql postgres -c "alter user sf00 WITH SUPERUSER;"
    # $POSTGRESQL/bin/psql sf00 -U sf00 -c "create schema authorization sf00;"
    # $POSTGRESQL/bin/psql postgres -c "create user sf01 password 'sf01'"
    # $POSTGRESQL/bin/psql postgres -c "create database sf01 owner sf01;"
    # $POSTGRESQL/bin/psql postgres -c "alter user sf01 WITH SUPERUSER;"
    # $POSTGRESQL/bin/psql sf01 -U sf01 -c "create schema authorization sf01;"

    # cd /home/build/postgres/data/tpch/scripts/
    # export TPCH=/home/build/postgres/data/tpch
    # ./c-tpch.sh 00
    # ./load-tpch.sh 00
    # ./c-tpch.sh 01
    # ./load-tpch.sh 01

    # # install packages
    # cd /home/build/AIDA/python_module/convert
    # python3 setup.py install --user

    # cd /home/build/multicorn
    # make && make install
    # cd /home/build/AIDA/python_module/virtual-table
    # python3 setup.py install --user

    # $POSTGRESQL/bin/psql test01 -U test01 -c "CREATE EXTENSION multicorn;"
    # $POSTGRESQL/bin/psql test01 -U test01 -c "CREATE SERVER IF NOT EXISTS vt_server1 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw1.FDW1');"
    # $POSTGRESQL/bin/psql test01 -U test01 -c "CREATE SERVER IF NOT EXISTS vt_server2 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw2.FDW2');"
    # $POSTGRESQL/bin/psql test01 -U test01 -c "CREATE SERVER IF NOT EXISTS vt_server3 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw3.FDW3');"
    # $POSTGRESQL/bin/psql bixi -U bixi -c "CREATE EXTENSION multicorn;"
    # $POSTGRESQL/bin/psql bixi -U bixi -c "CREATE SERVER IF NOT EXISTS vt_server1 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw1.FDW1');"
    # $POSTGRESQL/bin/psql bixi -U bixi -c "CREATE SERVER IF NOT EXISTS vt_server2 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw2.FDW2');"
    # $POSTGRESQL/bin/psql bixi -U bixi -c "CREATE SERVER IF NOT EXISTS vt_server3 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw3.FDW3');"
    # $POSTGRESQL/bin/psql sf00 -U sf00 -c "CREATE EXTENSION multicorn;"
    # $POSTGRESQL/bin/psql sf00 -U sf00 -c "CREATE SERVER IF NOT EXISTS vt_server1 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw1.FDW1');"
    # $POSTGRESQL/bin/psql sf00 -U sf00 -c "CREATE SERVER IF NOT EXISTS vt_server2 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw2.FDW2');"
    # $POSTGRESQL/bin/psql sf00 -U sf00 -c "CREATE SERVER IF NOT EXISTS vt_server3 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw3.FDW3');"
    # $POSTGRESQL/bin/psql sf01 -U sf01 -c "CREATE EXTENSION multicorn;"
    # $POSTGRESQL/bin/psql sf01 -U sf01 -c "CREATE SERVER IF NOT EXISTS vt_server1 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw1.FDW1');"
    # $POSTGRESQL/bin/psql sf01 -U sf01 -c "CREATE SERVER IF NOT EXISTS vt_server2 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw2.FDW2');"
    # $POSTGRESQL/bin/psql sf01 -U sf01 -c "CREATE SERVER IF NOT EXISTS vt_server3 FOREIGN DATA WRAPPER multicorn options ( wrapper 'vtlib.fdw3.FDW3');"

echo Setup done. Idling...

tail -f /dev/null # Force the container to stay up after running the script

