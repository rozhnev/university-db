FROM mariadb:11.7

# ── MariaDB configuration ──────────────────────────────────────────────────
COPY conf/university.cnf /etc/mysql/conf.d/university.cnf

# ── Initialization scripts (executed alphabetically on first start) ────────
#    01 → schema DDL (tables, indexes, FKs)
#    02 → objects   (triggers, views, stored procedures)
#    03 → seed data (semesters, rooms, scholarships, departments)
COPY 01_schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY 02_objects.sql /docker-entrypoint-initdb.d/02_objects.sql
COPY 03_seed_small.sql /docker-entrypoint-initdb.d/03_seed_small.sql

EXPOSE 3306
