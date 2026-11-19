#!/bin/bash
set -euo pipefail

# Install pg_textsearch extension from apt (if available) or build from source
# Timescale provides apt repos for pg_textsearch

echo "deb https://packagecloud.io/timescale/timescaledb/debian/ bookworm main" | sudo tee /etc/apt/sources.list.d/timescaledb.list
curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/timescaledb.gpg
sudo apt-get update
sudo apt-get install -y postgresql-18-pg-textsearch

# Configure PostgreSQL to load pg_textsearch
echo "shared_preload_libraries = 'pg_textsearch'" | sudo tee -a /etc/postgresql/18/main/postgresql.conf
sudo systemctl restart postgresql

# Create extension and test database
sleep 3
sudo -u postgres psql -c "CREATE EXTENSION pg_textsearch;"
sudo -u postgres psql -c "CREATE DATABASE pg_textsearch_test;"

# Install Ruby dependencies
bundle install

echo "Dev container setup complete!"
echo "Run tests with: bundle exec rake test"