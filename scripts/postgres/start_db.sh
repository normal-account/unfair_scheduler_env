# Start the Postgres SQL server
if [[ -z "$PGDATADIR" ]]
then
  echo "Error: variable PGDATADIR is not set. run the env file in the current directory first ('. env.sh')"
  exit 1
fi

pg_ctl stop -D $PGDATADIR -m immediate

echo > $(pwd)/pg_log/postgres.log

rm $(pwd)/pg_storeddata/postmaster.pid || true 2> /dev/null

pg_ctl start -D $PGDATADIR -l $PGLOGDIR/postgres.log -o -i
