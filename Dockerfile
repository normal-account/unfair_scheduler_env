FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV TZ=America/Montreal
ARG DEBIAN_FRONTEND=noninteractive
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt update
RUN apt upgrade -y 
RUN apt dist-upgrade -y
RUN apt install -y -qq  gcc                                     \
                        git                                     \
                        curl                                    \
                        locales                                 \
                        apt-utils                               \
                        vim                                     \
                        sudo                                    \
                        openjdk-21-jre # for benchbase          \
                        build-essential

RUN apt install -y -qq  libicu-dev                              \
                        pkg-config                              \
                        bison                                   \
                        flex                                    \
                        libreadline-dev                         \
                        zlib1g-dev                              \
                        cmake                                   \
                        automake                                \
                        libpq-dev                               \
                        cgroup-tools                            \
                        htop

# Set system locale (used by DB)
RUN locale-gen en_US.UTF-8   

# Build Postgres 17 from source
RUN git clone -b REL_17_STABLE https://github.com/postgres/postgres.git /home/build/postgres ### Takes some time
WORKDIR /home/build/postgres
RUN mkdir -p /home/build/postgres/installdir
RUN /home/build/postgres/configure --prefix=$PWD/installdir   \
    --exec-prefix=$PWD/installdir        \
    &&  make  \
    &&  make install

RUN mkdir -p /home/build/postgres/pg_storeddata

ENV PATH=/home/build/postgres/installdir/bin:$PATH

# Install benchbase
RUN git clone https://github.com/cmu-db/benchbase.git /home/build/benchbase
WORKDIR /home/build/benchbase
RUN git checkout 46fc66f
RUN ./mvnw clean package -P postgres
RUN tar xvzf target/benchbase-postgres.tgz

# Copy scripts to container
COPY scripts/benchbase/* /home/build/benchbase/
COPY scripts/benchbase/*.xml /home/build/benchbase/config/postgres/
COPY scripts/postgres/* /home/build/postgres/
COPY scripts/*.sh /home/build/
COPY *.c /home/build/
COPY Makefile /home/build/

# Setup user
RUN adduser --quiet --disabled-password --gecos ""  aida-user && chown -R aida-user /home/build \
    && echo "aida-user:aida" | chpasswd && usermod -aG sudo aida-user 
RUN chown aida-user -R /home/build
USER aida-user

RUN chmod +x /home/build/*.sh
RUN chmod +x /home/build/**/*.sh

# Append the env var script to .bashrc so env vars are set on login
RUN echo ". /home/build/postgres/env.sh" >> /home/aida-user/.bashrc

WORKDIR /home/build/

RUN make
