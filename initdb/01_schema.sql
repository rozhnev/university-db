-- ============================================================
--  University DB — Schema DDL
--  Target : MariaDB 11.7+
--  Phase  : 1 / 5
--  Tables : 16
-- ============================================================

SET NAMES utf8mb4;

CREATE DATABASE IF NOT EXISTS university
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE university;

-- ============================================================
--  LOOKUP / CONFIGURATION TABLES
-- ============================================================

-- ------------------------------------------------------------
--  semesters — academic terms
--  Datatypes: TINYINT, ENUM, YEAR, DATE, BOOLEAN
-- ------------------------------------------------------------
CREATE TABLE semesters (
    semester_id     TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    term            ENUM('Fall','Spring','Summer') NOT NULL,
    academic_year   YEAR                NOT NULL,
    name            VARCHAR(20)         NOT NULL,           -- e.g. 'Fall 2024'
    start_date      DATE                NOT NULL,
    end_date        DATE                NOT NULL,
    enroll_deadline DATE                NOT NULL,
    is_active       BOOLEAN             NOT NULL DEFAULT FALSE,
    PRIMARY KEY (semester_id),
    UNIQUE KEY uq_semester (term, academic_year)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  rooms — physical classrooms and online placeholders
--  Datatypes: SMALLINT, VARCHAR, ENUM, BOOLEAN
-- ------------------------------------------------------------
CREATE TABLE rooms (
    room_id       SMALLINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    building      VARCHAR(60)           NOT NULL,
    room_number   VARCHAR(10)           NOT NULL,
    capacity      SMALLINT UNSIGNED     NOT NULL,
    room_type     ENUM('lecture','seminar','lab','computer_lab','online')
                                        NOT NULL DEFAULT 'lecture',
    has_projector BOOLEAN               NOT NULL DEFAULT TRUE,
    has_video     BOOLEAN               NOT NULL DEFAULT FALSE,
    PRIMARY KEY (room_id),
    UNIQUE KEY uq_room (building, room_number)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  scholarships — available grants and awards
--  Datatypes: SMALLINT, VARCHAR, DECIMAL, ENUM, JSON, BOOLEAN
--  JSON example: {"min_gpa": 3.5, "need_based": true, "majors": ["CS","Math"], "max_year": 3}
-- ------------------------------------------------------------
CREATE TABLE scholarships (
    scholarship_id SMALLINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    name           VARCHAR(150)         NOT NULL,
    amount         DECIMAL(10,2)        NOT NULL,
    frequency      ENUM('one-time','annual','per-semester') NOT NULL DEFAULT 'annual',
    eligibility    JSON                 NULL,
    is_active      BOOLEAN              NOT NULL DEFAULT TRUE,
    PRIMARY KEY (scholarship_id)
) ENGINE = InnoDB;


-- ============================================================
--  CORE DOMAIN TABLES
-- ============================================================

-- ------------------------------------------------------------
--  departments — 3-level hierarchy: Faculty → Department → Sub-dept
--  Datatypes: TINYINT, CHAR, VARCHAR, YEAR, self-referencing FK
--  NOTE: head_faculty_id FK is added after faculty is created (ALTER below)
-- ------------------------------------------------------------
CREATE TABLE departments (
    department_id   TINYINT UNSIGNED    NOT NULL AUTO_INCREMENT,
    parent_id       TINYINT UNSIGNED    NULL,               -- NULL = top-level Faculty node
    code            CHAR(10)            NOT NULL,
    name            VARCHAR(100)        NOT NULL,
    level           TINYINT UNSIGNED    NOT NULL DEFAULT 1, -- 1=Faculty 2=Department 3=Sub-dept
    head_faculty_id SMALLINT UNSIGNED   NULL,               -- FK constraint added below
    established     YEAR                NULL,
    PRIMARY KEY (department_id),
    UNIQUE KEY uq_dept_code (code),
    KEY idx_dept_parent (parent_id),
    CONSTRAINT fk_dept_parent FOREIGN KEY (parent_id)
        REFERENCES departments (department_id)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  faculty — academic and administrative staff
--  Datatypes: SMALLINT, VARCHAR, ENUM, DATE, JSON, TEXT, BOOLEAN
--  JSON example: [{"day":"Mon","start":"10:00","end":"12:00"},{"day":"Wed","start":"14:00","end":"16:00"}]
-- ------------------------------------------------------------
CREATE TABLE faculty (
    faculty_id    SMALLINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    department_id TINYINT UNSIGNED      NOT NULL,
    first_name    VARCHAR(50)           NOT NULL,
    last_name     VARCHAR(50)           NOT NULL,
    email         VARCHAR(100)          NOT NULL,
    phone         VARCHAR(20)           NULL,
    rank          ENUM('Instructor','Assistant Professor','Associate Professor',
                       'Professor','Emeritus')    NOT NULL,
    hire_date     DATE                  NOT NULL,
    office        VARCHAR(50)           NULL,
    office_hours  JSON                  NULL,
    bio           TEXT                  NULL,
    is_active     BOOLEAN               NOT NULL DEFAULT TRUE,
    PRIMARY KEY (faculty_id),
    UNIQUE KEY uq_faculty_email (email),
    KEY idx_faculty_dept (department_id),
    CONSTRAINT fk_faculty_dept FOREIGN KEY (department_id)
        REFERENCES departments (department_id)
) ENGINE = InnoDB;

-- Resolve circular reference: departments ↔ faculty
ALTER TABLE departments
    ADD CONSTRAINT fk_dept_head FOREIGN KEY (head_faculty_id)
        REFERENCES faculty (faculty_id);


-- ------------------------------------------------------------
--  students — registered students
--  Datatypes: INT, CHAR, VARCHAR, DATE, ENUM, DECIMAL, JSON
--  JSON example: {"emergency":{"name":"Jane Doe","phone":"+1-555-0100"},"address":{"city":"Boston","state":"MA"}}
-- ------------------------------------------------------------
CREATE TABLE students (
    student_id       INT UNSIGNED       NOT NULL AUTO_INCREMENT,
    department_id    TINYINT UNSIGNED   NOT NULL,
    student_number   CHAR(10)           NOT NULL,           -- e.g. 'S000123'
    first_name       VARCHAR(50)        NOT NULL,
    last_name        VARCHAR(50)        NOT NULL,
    email            VARCHAR(100)       NOT NULL,
    date_of_birth    DATE               NOT NULL,
    gender           ENUM('M','F','NB','Other','Prefer not to say') NULL,
    enrollment_date  DATE               NOT NULL,
    expected_grad    YEAR               NULL,
    status           ENUM('active','inactive','graduated','suspended','withdrawn')
                                        NOT NULL DEFAULT 'active',
    gpa              DECIMAL(4,3)       NULL,               -- 0.000–4.000, maintained by trigger
    contacts         JSON               NULL,
    PRIMARY KEY (student_id),
    UNIQUE KEY uq_student_number (student_number),
    UNIQUE KEY uq_student_email  (email),
    KEY idx_student_dept   (department_id),
    KEY idx_student_status (status),
    CONSTRAINT fk_student_dept FOREIGN KEY (department_id)
        REFERENCES departments (department_id)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  courses — course catalog
--  Datatypes: SMALLINT, CHAR, VARCHAR, TINYINT, ENUM, TEXT, BOOLEAN, VECTOR
--  Special: FULLTEXT on (title, description), VECTOR(1536) embedding
-- ------------------------------------------------------------
CREATE TABLE courses (
    course_id     SMALLINT UNSIGNED     NOT NULL AUTO_INCREMENT,
    department_id TINYINT UNSIGNED      NOT NULL,
    code          CHAR(10)             NOT NULL,            -- e.g. 'CS101', 'MATH301'
    title         VARCHAR(150)         NOT NULL,
    credits       TINYINT UNSIGNED     NOT NULL DEFAULT 3,
    level         ENUM('undergraduate','graduate','doctoral') NOT NULL DEFAULT 'undergraduate',
    description   TEXT                 NULL,
    is_active     BOOLEAN              NOT NULL DEFAULT TRUE,
    embedding     VECTOR(1536)         NULL,                -- semantic embedding (MariaDB 11.7+)
    PRIMARY KEY (course_id),
    UNIQUE KEY uq_course_code (code),
    KEY idx_course_dept (department_id),
    FULLTEXT KEY ft_course (title, description),
    CONSTRAINT fk_course_dept FOREIGN KEY (department_id)
        REFERENCES departments (department_id)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  course_prerequisites — M:M self-referencing courses
--  Enables recursive CTE traversal of the full prerequisite tree
-- ------------------------------------------------------------
CREATE TABLE course_prerequisites (
    course_id       SMALLINT UNSIGNED   NOT NULL,
    prerequisite_id SMALLINT UNSIGNED   NOT NULL,
    is_mandatory    BOOLEAN             NOT NULL DEFAULT TRUE,
    PRIMARY KEY (course_id, prerequisite_id),
    CONSTRAINT chk_no_self_prereq CHECK (course_id <> prerequisite_id),
    CONSTRAINT fk_prereq_course FOREIGN KEY (course_id)
        REFERENCES courses (course_id),
    CONSTRAINT fk_prereq_prereq FOREIGN KEY (prerequisite_id)
        REFERENCES courses (course_id)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  sections — one offering of a course in a given semester
--  Datatypes: INT, SMALLINT, TINYINT, ENUM, JSON
--  JSON schedule example: [{"day":"Mon","start":"09:00","end":"10:30"},{"day":"Wed","start":"09:00","end":"10:30"}]
-- ------------------------------------------------------------
CREATE TABLE sections (
    section_id     INT UNSIGNED         NOT NULL AUTO_INCREMENT,
    course_id      SMALLINT UNSIGNED    NOT NULL,
    semester_id    TINYINT UNSIGNED     NOT NULL,
    faculty_id     SMALLINT UNSIGNED    NOT NULL,
    room_id        SMALLINT UNSIGNED    NULL,               -- NULL for fully online sections
    section_number TINYINT UNSIGNED     NOT NULL DEFAULT 1,
    delivery       ENUM('in-person','online','hybrid') NOT NULL DEFAULT 'in-person',
    max_capacity   SMALLINT UNSIGNED    NOT NULL DEFAULT 30,
    status         ENUM('open','closed','cancelled','completed') NOT NULL DEFAULT 'open',
    schedule       JSON                 NULL,
    PRIMARY KEY (section_id),
    UNIQUE KEY uq_section (course_id, semester_id, section_number),
    KEY idx_section_semester (semester_id),
    KEY idx_section_faculty  (faculty_id),
    KEY idx_section_room     (room_id),
    CONSTRAINT fk_section_course   FOREIGN KEY (course_id)   REFERENCES courses   (course_id),
    CONSTRAINT fk_section_semester FOREIGN KEY (semester_id) REFERENCES semesters (semester_id),
    CONSTRAINT fk_section_faculty  FOREIGN KEY (faculty_id)  REFERENCES faculty   (faculty_id),
    CONSTRAINT fk_section_room     FOREIGN KEY (room_id)     REFERENCES rooms     (room_id)
) ENGINE = InnoDB;


-- ============================================================
--  TRANSACTIONAL TABLES
-- ============================================================

-- ------------------------------------------------------------
--  enrollments — students enrolled in sections
--  Datatypes: INT, TIMESTAMP, ENUM, CHAR, DECIMAL
-- ------------------------------------------------------------
CREATE TABLE enrollments (
    enrollment_id INT UNSIGNED          NOT NULL AUTO_INCREMENT,
    student_id    INT UNSIGNED          NOT NULL,
    section_id    INT UNSIGNED          NOT NULL,
    enrolled_at   TIMESTAMP            NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status        ENUM('enrolled','dropped','completed','failed','incomplete')
                                        NOT NULL DEFAULT 'enrolled',
    final_grade   CHAR(2)              NULL,                -- 'A', 'A-', 'B+', 'B', …
    final_score   DECIMAL(5,2)         NULL,                -- 0.00–100.00
    PRIMARY KEY (enrollment_id),
    UNIQUE KEY uq_enrollment (student_id, section_id),
    KEY idx_enrollment_section (section_id),
    CONSTRAINT fk_enroll_student FOREIGN KEY (student_id) REFERENCES students (student_id),
    CONSTRAINT fk_enroll_section FOREIGN KEY (section_id) REFERENCES sections (section_id)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  student_scholarships — scholarship awards granted to students
--  Datatypes: INT, SMALLINT, DATE, DECIMAL, TEXT
-- ------------------------------------------------------------
CREATE TABLE student_scholarships (
    award_id       INT UNSIGNED         NOT NULL AUTO_INCREMENT,
    student_id     INT UNSIGNED         NOT NULL,
    scholarship_id SMALLINT UNSIGNED    NOT NULL,
    awarded_date   DATE                 NOT NULL,
    expires_date   DATE                 NULL,
    amount_awarded DECIMAL(10,2)        NOT NULL,
    notes          TEXT                 NULL,
    PRIMARY KEY (award_id),
    KEY idx_award_student     (student_id),
    KEY idx_award_scholarship (scholarship_id),
    CONSTRAINT fk_award_student     FOREIGN KEY (student_id)     REFERENCES students     (student_id),
    CONSTRAINT fk_award_scholarship FOREIGN KEY (scholarship_id) REFERENCES scholarships (scholarship_id)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  research_projects — faculty-led research initiatives
--  Datatypes: SMALLINT, VARCHAR, TEXT, DATE, ENUM, JSON
--  JSON funding example: [{"source":"NSF","amount":150000,"grant_id":"NSF-2024-001"}]
-- ------------------------------------------------------------
CREATE TABLE research_projects (
    project_id      SMALLINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    department_id   TINYINT UNSIGNED    NOT NULL,
    lead_faculty_id SMALLINT UNSIGNED   NOT NULL,
    title           VARCHAR(200)        NOT NULL,
    abstract        TEXT                NULL,
    start_date      DATE                NOT NULL,
    end_date        DATE                NULL,
    status          ENUM('proposed','active','completed','cancelled') NOT NULL DEFAULT 'proposed',
    funding         JSON                NULL,
    PRIMARY KEY (project_id),
    KEY idx_project_dept (department_id),
    KEY idx_project_lead (lead_faculty_id),
    CONSTRAINT fk_project_dept FOREIGN KEY (department_id)   REFERENCES departments (department_id),
    CONSTRAINT fk_project_lead FOREIGN KEY (lead_faculty_id) REFERENCES faculty     (faculty_id)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  publications — research papers and conference proceedings
--  Datatypes: INT, SMALLINT (nullable FK), VARCHAR, MEDIUMTEXT, YEAR, SET
--  Special: FULLTEXT on (title, abstract), SET for multi-value keyword tags
--  project_id is nullable — publications may exist independently of a project
-- ------------------------------------------------------------
CREATE TABLE publications (
    publication_id INT UNSIGNED         NOT NULL AUTO_INCREMENT,
    project_id     SMALLINT UNSIGNED    NULL,               -- optional link to research_projects
    title          VARCHAR(300)         NOT NULL,
    abstract       MEDIUMTEXT           NULL,
    pub_year       YEAR                 NOT NULL,
    venue          VARCHAR(200)         NULL,               -- journal name or conference
    doi            VARCHAR(100)         NULL,
    keywords       SET(
                       'AI','ML','Data Science','Networking','Security',
                       'Algorithms','Databases','HCI','Theory','Bioinformatics',
                       'Systems','Mathematics','Physics','Chemistry','Biology'
                   )                    NOT NULL DEFAULT '',
    citation_count INT UNSIGNED         NOT NULL DEFAULT 0,
    PRIMARY KEY (publication_id),
    UNIQUE KEY uq_doi (doi),
    KEY idx_pub_project (project_id),
    KEY idx_pub_year    (pub_year),
    FULLTEXT KEY ft_publication (title, abstract),
    CONSTRAINT fk_pub_project FOREIGN KEY (project_id)
        REFERENCES research_projects (project_id)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  project_members — faculty or student participation in research projects
--  Datatypes: INT, SMALLINT, ENUM, DATE
--  CHECK guarantees at least one of faculty_id / student_id is non-NULL
-- ------------------------------------------------------------
CREATE TABLE project_members (
    member_id   INT UNSIGNED            NOT NULL AUTO_INCREMENT,
    project_id  SMALLINT UNSIGNED       NOT NULL,
    faculty_id  SMALLINT UNSIGNED       NULL,
    student_id  INT UNSIGNED            NULL,
    role        ENUM('Principal Investigator','Co-Investigator','Research Assistant',
                     'Graduate Student','Undergraduate Student') NOT NULL,
    joined_date DATE                    NOT NULL,
    left_date   DATE                    NULL,
    PRIMARY KEY (member_id),
    CONSTRAINT chk_member_identity CHECK (faculty_id IS NOT NULL OR student_id IS NOT NULL),
    KEY idx_member_project (project_id),
    KEY idx_member_faculty (faculty_id),
    KEY idx_member_student (student_id),
    CONSTRAINT fk_member_project FOREIGN KEY (project_id)  REFERENCES research_projects (project_id),
    CONSTRAINT fk_member_faculty FOREIGN KEY (faculty_id)  REFERENCES faculty           (faculty_id),
    CONSTRAINT fk_member_student FOREIGN KEY (student_id)  REFERENCES students          (student_id)
) ENGINE = InnoDB;


-- ============================================================
--  BIG TABLES  (designed for analytical queries)
-- ============================================================

-- ------------------------------------------------------------
--  grade_events — individual scored items per enrollment  (~120 000 rows)
--  Primary playground for: window functions, running totals, ranking,
--  time-series analysis, per-student progress tracking
--  Datatypes: BIGINT, INT, VARCHAR, ENUM, DECIMAL, DATETIME, TEXT
-- ------------------------------------------------------------
CREATE TABLE grade_events (
    event_id      BIGINT UNSIGNED       NOT NULL AUTO_INCREMENT,
    enrollment_id INT UNSIGNED          NOT NULL,
    item_name     VARCHAR(100)          NOT NULL,           -- 'Assignment 1', 'Midterm Exam'
    item_type     ENUM('assignment','quiz','midterm','final','project','participation','lab')
                                        NOT NULL,
    score         DECIMAL(6,2)          NOT NULL,           -- achieved points
    max_score     DECIMAL(6,2)          NOT NULL DEFAULT 100.00,
    weight        DECIMAL(5,4)          NOT NULL,           -- fraction of final grade, e.g. 0.1500
    graded_at     DATETIME              NOT NULL,
    grader_id     SMALLINT UNSIGNED     NULL,               -- faculty member who graded
    feedback      TEXT                  NULL,
    PRIMARY KEY (event_id),
    KEY idx_ge_enrollment (enrollment_id),
    KEY idx_ge_graded_at  (graded_at),
    KEY idx_ge_item_type  (item_type),
    CONSTRAINT fk_ge_enrollment FOREIGN KEY (enrollment_id) REFERENCES enrollments (enrollment_id),
    CONSTRAINT fk_ge_grader     FOREIGN KEY (grader_id)     REFERENCES faculty     (faculty_id)
) ENGINE = InnoDB;


-- ------------------------------------------------------------
--  audit_log — row-level change history (~60 000 rows)
--  Populated automatically by triggers on enrollments, students, grade_events.
--  Great for: JSON functions, time-series queries, change detection.
--  Datatypes: BIGINT, VARCHAR, ENUM, TIMESTAMP, JSON
-- ------------------------------------------------------------
CREATE TABLE audit_log (
    log_id      BIGINT UNSIGNED         NOT NULL AUTO_INCREMENT,
    table_name  VARCHAR(64)             NOT NULL,
    record_id   BIGINT UNSIGNED         NOT NULL,
    action      ENUM('INSERT','UPDATE','DELETE') NOT NULL,
    changed_at  TIMESTAMP               NOT NULL DEFAULT CURRENT_TIMESTAMP,
    changed_by  VARCHAR(100)            NULL,               -- DB user or application context
    old_values  JSON                    NULL,               -- NULL for INSERT events
    new_values  JSON                    NULL,               -- NULL for DELETE events
    PRIMARY KEY (log_id),
    KEY idx_audit_table_record (table_name, record_id),
    KEY idx_audit_changed_at   (changed_at),
    KEY idx_audit_action       (action)
) ENGINE = InnoDB;
