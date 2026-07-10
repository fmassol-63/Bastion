#!/bin/bash
# ~/Bastion/BASTION1/patroni/config/create_admin.sh
set -e
psql -U postgres -c "CREATE ROLE admin WITH LOGIN CREATEROLE CREATEDB PASSWORD '${PATRONI_admin_PASSWORD}';"
