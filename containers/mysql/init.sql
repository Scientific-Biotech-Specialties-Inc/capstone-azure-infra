-- Boot-time init: ensure the capstone_auth database exists alongside the
-- auto-created `serms` database. All services connect as the MySQL root user
-- (matching the existing docker-compose behaviour), so no extra users needed.
CREATE DATABASE IF NOT EXISTS `capstone_auth`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;