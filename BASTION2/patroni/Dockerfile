# ~/Bastion/BASTION2/patroni/Dockerfile
FROM postgres:16

RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/patroni-venv && \
    /opt/patroni-venv/bin/pip install --no-cache-dir \
    patroni[etcd3] \
    psycopg2-binary

ENV PATH="/opt/patroni-venv/bin:$PATH"

RUN mkdir -p /home/postgres/pgdata && \
    chown -R postgres:postgres /home/postgres

USER postgres

ENTRYPOINT ["patroni"]
CMD ["/config/patroni.yml"]
