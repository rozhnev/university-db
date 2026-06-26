# University DB

A modern **MariaDB 11.7+** sample database for learning SQL — designed to replace the outdated Sakila database.

It covers all significant MariaDB datatypes (including `VECTOR` and `JSON`), is fully normalized to 3NF, and ships with enough data for both beginner exercises and complex analytical queries.

---

## Why not Sakila?

| | Sakila | University DB |
|--|--------|---------------|
| Designed for | MySQL 5.x | MariaDB 11.7+ |
| `JSON` support | ✗ | ✓ (5 columns) |
| `VECTOR` support | ✗ | ✓ `VECTOR(1536)` |
| `FULLTEXT` indexes | ✗ | ✓ (2 indexes) |
| `SET` type | ✗ | ✓ |
| Analytical big table | ✗ | ✓ 120 000 rows |
| Recursive CTEs demo | ✗ | ✓ (prerequisites, dept hierarchy) |
| Stored procedures | 3 | 6 |
| Triggers | 6 | 7 |
| Views | 7 | 7 |

---

## Features

- **16 tables** — lookup, domain, transactional, and two big analytic tables
- **All major MariaDB datatypes** — `INT`/`BIGINT`/`TINYINT`, `CHAR`/`VARCHAR`, `TEXT`/`MEDIUMTEXT`, `DECIMAL`, `DATE`/`DATETIME`/`TIMESTAMP`/`TIME`/`YEAR`, `ENUM`, `SET`, `BOOLEAN`, `JSON`, `VECTOR(1536)`
- **Full-text search** on `courses` and `publications`
- **Vector similarity search** via `VEC_Distance` on course embeddings
- **3-level department hierarchy** — Faculty → Department → Sub-department (recursive CTE playground)
- **7 views**, **6 stored procedures**, **7 triggers**
- **4 levels of example queries** — from basic `SELECT` to `EXPLAIN ANALYZE` and window functions
- **Docker-first setup** — one command to get a running database

---

## Quick Start (Docker)

**Prerequisites:** Docker and Docker Compose.

```bash
# 1. Clone the repository
git clone <repo-url>
cd university-db

# 2. Set your passwords
cp .env.example .env
# edit .env — change MARIADB_ROOT_PASSWORD and MARIADB_PASSWORD

# 3. Build and start (schema + seed data load on first boot)
docker compose up --build

# 4. Wait for the generator to finish (~2–3 min), then connect
mysql -h 127.0.0.1 -P 3306 -u university_user -p university
```

`docker compose up` runs two services in sequence:

1. **`db`** — builds the MariaDB 11.7 image, loads schema, triggers/views/procedures, and seed data automatically on first start.
2. **`generator`** — waits for the DB to be healthy, then runs the Python data generator to fill faculty, students, courses, enrollments, and the big `grade_events` table. Exits when done.

Data is persisted in a named Docker volume (`university_data`), so restarting the container does not re-run initialization.

---

## Manual Setup (no Docker)

**Prerequisites:** MariaDB 11.7+, Python 3.10+.

```bash
# Load schema and static data
mysql -u root -p < 01_schema.sql
mysql -u root -p < 02_objects.sql
mysql -u root -p < 03_seed_small.sql

# Install Python dependencies
pip install faker mysql-connector-python numpy

# Generate dynamic data (~3–5 min)
python generate_data.py \
    --host 127.0.0.1 \
    --user root \
    --password your_password \
    --database university \
    --seed 42
```

---

## Schema

### 16 Tables

```
departments ◄──(parent_id, self-join)
     │
     └──► faculty ──────────────────► sections ──► courses
               │                           │            │
               │                    enrollments      course_prerequisites
               │                        │  │              (self-ref)
               └──► research_projects   │  └──► grade_events  ← BIG TABLE (~120k)
                         │              │
                    publications    student_scholarships
                    project_members
                                              audit_log  ← BIG TABLE (~60k, via triggers)
```

| # | Table | ~Rows | Notable datatypes |
|---|-------|------:|-------------------|
| 1 | `semesters` | 20 | `ENUM`, `YEAR`, `DATE`, `BOOLEAN` |
| 2 | `rooms` | 72 | `SMALLINT`, `ENUM`, `BOOLEAN` |
| 3 | `scholarships` | 20 | `DECIMAL`, `ENUM`, `JSON` |
| 4 | `departments` | 25 | `TINYINT`, self-ref FK |
| 5 | `faculty` | 250 | `ENUM`, `DATE`, `JSON`, `TEXT` |
| 6 | `students` | 2 000 | `CHAR`, `DATE`, `ENUM`, `DECIMAL`, `JSON` |
| 7 | `courses` | 200 | `TEXT`, `BOOLEAN`, **`VECTOR(1536)`**, `FULLTEXT` |
| 8 | `course_prerequisites` | 300 | M:M self-ref |
| 9 | `sections` | 800 | `ENUM`, `JSON` (schedule) |
| 10 | `enrollments` | 8 000 | `TIMESTAMP`, `ENUM`, `CHAR`, `DECIMAL` |
| 11 | `student_scholarships` | 500 | `DATE`, `DECIMAL` |
| 12 | `research_projects` | 200 | `TEXT`, `DATE`, `ENUM`, `JSON` |
| 13 | `publications` | 500 | `MEDIUMTEXT`, `YEAR`, **`SET`**, `FULLTEXT` |
| 14 | `project_members` | 900 | `ENUM`, `DATE`, nullable FK |
| 15 | `grade_events` | ~120 000 | `BIGINT`, `DECIMAL`, `DATETIME` |
| 16 | `audit_log` | ~60 000 | `BIGINT`, `ENUM`, `TIMESTAMP`, `JSON` |

### JSON columns

| Table | Column | Example value |
|-------|--------|---------------|
| `scholarships` | `eligibility` | `{"min_gpa": 3.5, "need_based": true, "majors": ["CS","Math"]}` |
| `faculty` | `office_hours` | `[{"day":"Mon","start":"10:00","end":"12:00"}]` |
| `students` | `contacts` | `{"emergency":{"name":"Jane Doe","phone":"..."},"address":{...}}` |
| `sections` | `schedule` | `[{"day":"Mon","start":"09:00","end":"10:30"},...]` |
| `research_projects` | `funding` | `[{"source":"NSF","amount":150000,"grant_id":"NSF-2024-001"}]` |
| `audit_log` | `old_values` / `new_values` | `{"status":"enrolled","final_grade":null}` |

---

## Database Objects

### Views

| View | What it shows |
|------|--------------|
| `v_student_gpa` | Weighted GPA per student per semester |
| `v_section_roster` | Enrolled students with contact info per section |
| `v_course_pass_rate` | Historical pass/fail % and average score per course |
| `v_faculty_workload` | Sections taught and fill rate per faculty member |
| `v_top_scholars` | Students ranked by total scholarship funding |
| `v_publication_stats` | Paper count and citations per department per year |
| `v_prerequisite_tree` | Direct prerequisites for every course |

### Stored Procedures

| Procedure | Signature |
|-----------|-----------|
| `sp_enroll_student` | `(student_id, section_id) → enrollment_id` — validates capacity, prerequisites, duplicates |
| `sp_drop_enrollment` | `(enrollment_id)` — enforces status rules, re-opens section if needed |
| `sp_submit_grade` | `(enrollment_id, item_name, type, score, max, weight, grader_id)` — inserts event, recalculates final |
| `sp_calculate_gpa` | `(student_id) → gpa` — computes cumulative GPA and updates `students.gpa` |
| `sp_get_prerequisite_chain` | `(course_id)` — recursive CTE returning full prerequisite tree |
| `sp_search_courses_semantic` | `(embedding VECTOR(1536), limit)` — nearest-neighbour vector search |

### Triggers

| Trigger | Event | Purpose |
|---------|-------|---------|
| `trg_enrollment_capacity` | BEFORE INSERT on `enrollments` | Blocks enrollment when section is full |
| `trg_section_auto_close` | AFTER INSERT on `enrollments` | Closes section when capacity is reached |
| `trg_enrollment_audit_insert/update/delete` | AFTER on `enrollments` | Writes JSON diff to `audit_log` |
| `trg_student_audit_update` | AFTER UPDATE on `students` | Logs GPA and status changes |
| `trg_grade_audit_insert` | AFTER INSERT on `grade_events` | Logs every new scored item |

---

## Learning Path

Work through the query files in order:

### [queries/level1.sql](queries/level1.sql) — Basics
`SELECT`, `WHERE`, `ORDER BY`, `LIMIT`, single-table `GROUP BY`, `COUNT`/`AVG`/`SUM`

### [queries/level2.sql](queries/level2.sql) — Intermediate
Multi-table `JOIN` (up to 5 tables), correlated subqueries, `HAVING`, `FULLTEXT` search (`MATCH … AGAINST`), `JSON_VALUE`, `INSERT`/`UPDATE`/`DELETE`

### [queries/level3.sql](queries/level3.sql) — Advanced
Window functions (`RANK`, `DENSE_RANK`, `ROW_NUMBER`, `LAG`, `LEAD`, running `SUM`), CTEs, **recursive CTEs** (prerequisite chain, department hierarchy), `JSON_TABLE`, `SET`/`FIND_IN_SET`, **`VEC_Distance`** similarity search

### [queries/level4.sql](queries/level4.sql) — DBA / Developer
`EXPLAIN ANALYZE`, index strategy (`SHOW INDEX`, `FORCE INDEX`), transaction isolation levels, stored procedure authoring, audit log forensics with `JSON_VALUE`

---

## Project Structure

```
university-db/
├── Dockerfile              # MariaDB 11.7 image with SQL init files
├── Dockerfile.generator    # Python data generator image
├── docker-compose.yml      # Orchestrates db + generator services
├── .env.example            # Environment variable template
├── conf/
│   └── university.cnf      # MariaDB configuration (charset, packet size, slow log)
├── 01_schema.sql           # DDL — 16 tables, indexes, FK constraints
├── 02_objects.sql          # Triggers, views, stored procedures
├── 03_seed_small.sql       # Static seed data (semesters, rooms, scholarships, departments)
├── generate_data.py        # Python/Faker script — generates ~130 000 rows
└── queries/
    ├── level1.sql          # Basic SQL
    ├── level2.sql          # Intermediate SQL
    ├── level3.sql          # Advanced SQL
    └── level4.sql          # DBA / Developer SQL
```

---

## Useful Commands

```bash
# Rebuild and restart from scratch (drops volume data)
docker compose down -v && docker compose up --build

# Re-run the data generator with a different seed
docker compose run --rm generator \
    --host db --user university_user --password your_password \
    --database university --seed 99

# Open a MySQL shell inside the running container
docker exec -it university-db mariadb -u university_user -p university

# Check row counts across all tables
docker exec -it university-db mariadb -u university_user -p university -e "
  SELECT table_name, table_rows
  FROM   information_schema.tables
  WHERE  table_schema = 'university'
  ORDER  BY table_rows DESC;"

# View slow query log
docker exec -it university-db tail -f /var/log/mysql/slow.log
```

---

## Requirements

| Component | Version |
|-----------|---------|
| MariaDB | **11.7+** (required for `VECTOR` type) |
| Docker Engine | 24+ |
| Docker Compose | 2.x |
| Python (manual setup) | 3.10+ |
| Python packages | `faker`, `mysql-connector-python`, `numpy` |

---

## License

MIT License — see [LICENSE](LICENSE) for the full text.

You are free to use, copy, modify, and distribute this project — including in courses, books, and tutorials — with no restrictions beyond keeping the copyright notice.
