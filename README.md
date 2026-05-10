# Unfair Scheduler Environment

This repository provides a basic Dockerfile alongside the scripts necessary to test out the Unfair Scheduler.


## 1. Setting up the Docker container

### Creating the PostgreSQL container:

The container can be launched using the docker-compose.yml file. Simply run the following command:

```bash
docker compose up -d --build
```

Which will build and run the container (it might take a while).

Then, attach to the container :

```bash
docker container exec -it postgres_benchbase /bin/bash
```

### Container credentials 


**User**: `aida-user`


**Password**: `aida`


### Database credentials

**Database name**: `benchbase`


**Database user**: `admin`


**Database password**: `password`

### Restarting the PostgreSQL server

To restart the PostgreSQL server at any point (and kill any UDFs), you can run:

```
/home/build/postgres/start_db.sh
```


## 2. Running the Benchbase benchmarks

Travel to the Benchbase folder :

```bash
cd /home/build/benchbase
```

To run 4 clients of TPCC without competing UDFs, you can run:

```
./run_benchmark.sh tpcc
```

**Then**, if you want to start the 4 competing UDFs, you can run the following command from another terminal afterwards:

```
./startup_udf_burn_bench.sh --udf
```

The number of Benchbase clients is specified in the `config/postgres/sample_tpcc_config.xml` file.

The number of UDF clients is specified by the `CLIENTS` env var (default value is 4).

If you change the number of UDF clients, you'll also need to rerun the cgroup script:

```
./create_cgroups.sh # This will recreate the cgroups (and update cpuset.cpus)
```

You can then run this experiment while the Unfair Scheduler is running to compare performance to the EEVDF baseline. Note that you should run the Unfair Scheduler from the host machine, and not from the Docker container itself.
