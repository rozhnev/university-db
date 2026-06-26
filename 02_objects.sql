-- ============================================================
--  University DB — Database Objects
--  Target : MariaDB 11.7+
--  Phase  : 2 / 5
--  Objects: 5 triggers, 7 views, 6 stored procedures
-- ============================================================

USE university;

DELIMITER $$

-- ============================================================
--  TRIGGERS  (created before views/procedures that reference audit_log)
-- ============================================================

-- ------------------------------------------------------------
--  trg_enrollment_capacity
--  Blocks INSERT into enrollments when the section is already full.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_enrollment_capacity$$
CREATE TRIGGER trg_enrollment_capacity
BEFORE INSERT ON enrollments
FOR EACH ROW
BEGIN
    DECLARE v_capacity  SMALLINT UNSIGNED;
    DECLARE v_enrolled  INT UNSIGNED;

    SELECT max_capacity INTO v_capacity
    FROM   sections
    WHERE  section_id = NEW.section_id;

    SELECT COUNT(*) INTO v_enrolled
    FROM   enrollments
    WHERE  section_id = NEW.section_id
      AND  status     = 'enrolled';

    IF v_enrolled >= v_capacity THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Section has reached maximum capacity';
    END IF;
END$$


-- ------------------------------------------------------------
--  trg_section_auto_close
--  Sets section status to 'closed' when it reaches capacity.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_section_auto_close$$
CREATE TRIGGER trg_section_auto_close
AFTER INSERT ON enrollments
FOR EACH ROW
BEGIN
    DECLARE v_capacity SMALLINT UNSIGNED;
    DECLARE v_enrolled INT UNSIGNED;

    SELECT max_capacity INTO v_capacity
    FROM   sections
    WHERE  section_id = NEW.section_id;

    SELECT COUNT(*) INTO v_enrolled
    FROM   enrollments
    WHERE  section_id = NEW.section_id
      AND  status     = 'enrolled';

    IF v_enrolled >= v_capacity THEN
        UPDATE sections
        SET    status = 'closed'
        WHERE  section_id = NEW.section_id
          AND  status     = 'open';
    END IF;
END$$


-- ------------------------------------------------------------
--  trg_enrollment_audit  (INSERT / UPDATE / DELETE)
--  Writes a JSON diff of every enrollment change to audit_log.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_enrollment_audit_insert$$
CREATE TRIGGER trg_enrollment_audit_insert
AFTER INSERT ON enrollments
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, changed_by, old_values, new_values)
    VALUES (
        'enrollments',
        NEW.enrollment_id,
        'INSERT',
        USER(),
        NULL,
        JSON_OBJECT(
            'student_id',  NEW.student_id,
            'section_id',  NEW.section_id,
            'status',      NEW.status,
            'enrolled_at', NEW.enrolled_at
        )
    );
END$$

DROP TRIGGER IF EXISTS trg_enrollment_audit_update$$
CREATE TRIGGER trg_enrollment_audit_update
AFTER UPDATE ON enrollments
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, changed_by, old_values, new_values)
    VALUES (
        'enrollments',
        NEW.enrollment_id,
        'UPDATE',
        USER(),
        JSON_OBJECT(
            'status',      OLD.status,
            'final_grade', OLD.final_grade,
            'final_score', OLD.final_score
        ),
        JSON_OBJECT(
            'status',      NEW.status,
            'final_grade', NEW.final_grade,
            'final_score', NEW.final_score
        )
    );
END$$

DROP TRIGGER IF EXISTS trg_enrollment_audit_delete$$
CREATE TRIGGER trg_enrollment_audit_delete
AFTER DELETE ON enrollments
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, changed_by, old_values, new_values)
    VALUES (
        'enrollments',
        OLD.enrollment_id,
        'DELETE',
        USER(),
        JSON_OBJECT(
            'student_id',  OLD.student_id,
            'section_id',  OLD.section_id,
            'status',      OLD.status
        ),
        NULL
    );
END$$


-- ------------------------------------------------------------
--  trg_student_audit  (UPDATE only — INSERT/DELETE via procedures)
--  Logs GPA and status changes on the students table.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_student_audit_update$$
CREATE TRIGGER trg_student_audit_update
AFTER UPDATE ON students
FOR EACH ROW
BEGIN
    IF OLD.gpa <> NEW.gpa OR OLD.status <> NEW.status THEN
        INSERT INTO audit_log (table_name, record_id, action, changed_by, old_values, new_values)
        VALUES (
            'students',
            NEW.student_id,
            'UPDATE',
            USER(),
            JSON_OBJECT('gpa', OLD.gpa, 'status', OLD.status),
            JSON_OBJECT('gpa', NEW.gpa, 'status', NEW.status)
        );
    END IF;
END$$


-- ------------------------------------------------------------
--  trg_grade_audit  (INSERT — scores are never updated, only added)
--  Logs every new grade event for change-tracking exercises.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_grade_audit_insert$$
CREATE TRIGGER trg_grade_audit_insert
AFTER INSERT ON grade_events
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, changed_by, old_values, new_values)
    VALUES (
        'grade_events',
        NEW.event_id,
        'INSERT',
        USER(),
        NULL,
        JSON_OBJECT(
            'enrollment_id', NEW.enrollment_id,
            'item_name',     NEW.item_name,
            'item_type',     NEW.item_type,
            'score',         NEW.score,
            'max_score',     NEW.max_score,
            'weight',        NEW.weight
        )
    );
END$$


-- ============================================================
--  VIEWS
-- ============================================================

-- ------------------------------------------------------------
--  v_student_gpa
--  Weighted GPA per student per semester, plus cumulative GPA.
--  Demonstrates: aggregation, conditional logic, multi-table JOIN.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_student_gpa$$
CREATE VIEW v_student_gpa AS
SELECT
    s.student_id,
    s.student_number,
    CONCAT(s.first_name, ' ', s.last_name)           AS student_name,
    sem.semester_id,
    sem.name                                          AS semester,
    COUNT(e.enrollment_id)                            AS courses_taken,
    ROUND(AVG(e.final_score), 2)                      AS avg_score,
    ROUND(SUM(
        CASE e.final_grade
            WHEN 'A'  THEN 4.0 * c.credits
            WHEN 'A-' THEN 3.7 * c.credits
            WHEN 'B+' THEN 3.3 * c.credits
            WHEN 'B'  THEN 3.0 * c.credits
            WHEN 'B-' THEN 2.7 * c.credits
            WHEN 'C+' THEN 2.3 * c.credits
            WHEN 'C'  THEN 2.0 * c.credits
            WHEN 'C-' THEN 1.7 * c.credits
            WHEN 'D'  THEN 1.0 * c.credits
            ELSE           0.0 * c.credits
        END
    ) / NULLIF(SUM(c.credits), 0), 3)                AS semester_gpa
FROM       students   s
JOIN       enrollments e  ON e.student_id  = s.student_id
                         AND e.status      = 'completed'
JOIN       sections   sec ON sec.section_id = e.section_id
JOIN       semesters  sem ON sem.semester_id = sec.semester_id
JOIN       courses    c   ON c.course_id    = sec.course_id
GROUP BY   s.student_id, s.student_number, student_name, sem.semester_id, sem.name$$


-- ------------------------------------------------------------
--  v_section_roster
--  All enrolled students per section with contact info.
--  Demonstrates: 5-table JOIN, string concatenation.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_section_roster$$
CREATE VIEW v_section_roster AS
SELECT
    sec.section_id,
    c.code                                            AS course_code,
    c.title                                           AS course_title,
    sem.name                                          AS semester,
    CONCAT(f.first_name, ' ', f.last_name)            AS instructor,
    s.student_number,
    CONCAT(s.first_name, ' ', s.last_name)            AS student_name,
    s.email                                           AS student_email,
    e.enrollment_id,
    e.status                                          AS enrollment_status,
    e.final_grade
FROM       sections   sec
JOIN       courses    c   ON c.course_id    = sec.course_id
JOIN       semesters  sem ON sem.semester_id = sec.semester_id
JOIN       faculty    f   ON f.faculty_id   = sec.faculty_id
JOIN       enrollments e  ON e.section_id   = sec.section_id
JOIN       students   s   ON s.student_id   = e.student_id$$


-- ------------------------------------------------------------
--  v_course_pass_rate
--  Historical pass/fail percentage per course.
--  Demonstrates: conditional aggregation, CASE.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_course_pass_rate$$
CREATE VIEW v_course_pass_rate AS
SELECT
    c.course_id,
    c.code,
    c.title,
    d.name                                            AS department,
    COUNT(e.enrollment_id)                            AS total_enrollments,
    SUM(CASE WHEN e.status = 'completed' THEN 1 ELSE 0 END) AS completed,
    SUM(CASE WHEN e.status = 'failed'    THEN 1 ELSE 0 END) AS failed,
    SUM(CASE WHEN e.status = 'dropped'   THEN 1 ELSE 0 END) AS dropped,
    ROUND(
        100.0 * SUM(CASE WHEN e.status = 'completed' THEN 1 ELSE 0 END)
              / NULLIF(COUNT(e.enrollment_id), 0),
        1
    )                                                 AS pass_rate_pct,
    ROUND(AVG(e.final_score), 2)                      AS avg_final_score
FROM       courses    c
JOIN       departments d   ON d.department_id = c.department_id
LEFT JOIN  sections   sec  ON sec.course_id   = c.course_id
LEFT JOIN  enrollments e   ON e.section_id    = sec.section_id
GROUP BY   c.course_id, c.code, c.title, d.name$$


-- ------------------------------------------------------------
--  v_faculty_workload
--  Sections taught, total students, and average section fill rate per faculty.
--  Demonstrates: aggregation, ROUND, subquery-free multi-table join.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_faculty_workload$$
CREATE VIEW v_faculty_workload AS
SELECT
    f.faculty_id,
    CONCAT(f.first_name, ' ', f.last_name)            AS faculty_name,
    f.rank,
    d.name                                            AS department,
    COUNT(DISTINCT sec.section_id)                    AS sections_taught,
    SUM(sec.max_capacity)                             AS total_capacity,
    COUNT(e.enrollment_id)                            AS total_students_enrolled,
    ROUND(
        100.0 * COUNT(e.enrollment_id)
              / NULLIF(SUM(sec.max_capacity), 0),
        1
    )                                                 AS avg_fill_rate_pct
FROM       faculty    f
JOIN       departments d   ON d.department_id = f.department_id
LEFT JOIN  sections   sec  ON sec.faculty_id  = f.faculty_id
LEFT JOIN  enrollments e   ON e.section_id    = sec.section_id
                          AND e.status        IN ('enrolled', 'completed', 'failed')
GROUP BY   f.faculty_id, faculty_name, f.rank, d.name$$


-- ------------------------------------------------------------
--  v_top_scholars
--  Students ranked by total scholarship funding received.
--  Demonstrates: GROUP BY with SUM, ORDER BY on aggregate.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_top_scholars$$
CREATE VIEW v_top_scholars AS
SELECT
    s.student_id,
    s.student_number,
    CONCAT(s.first_name, ' ', s.last_name)            AS student_name,
    d.name                                            AS department,
    COUNT(ss.award_id)                                AS scholarship_count,
    SUM(ss.amount_awarded)                            AS total_awarded,
    GROUP_CONCAT(sc.name ORDER BY ss.awarded_date SEPARATOR '; ') AS scholarships
FROM       students           s
JOIN       departments        d  ON d.department_id  = s.department_id
JOIN       student_scholarships ss ON ss.student_id  = s.student_id
JOIN       scholarships        sc ON sc.scholarship_id = ss.scholarship_id
GROUP BY   s.student_id, s.student_number, student_name, d.name
ORDER BY   total_awarded DESC$$


-- ------------------------------------------------------------
--  v_publication_stats
--  Publication count and total citations per department per year.
--  Demonstrates: multi-table join, GROUP BY two dimensions.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_publication_stats$$
CREATE VIEW v_publication_stats AS
SELECT
    d.name                                            AS department,
    p.pub_year,
    COUNT(p.publication_id)                           AS paper_count,
    SUM(p.citation_count)                             AS total_citations,
    ROUND(AVG(p.citation_count), 1)                   AS avg_citations
FROM       publications       p
LEFT JOIN  research_projects  rp ON rp.project_id    = p.project_id
LEFT JOIN  departments        d  ON d.department_id  = rp.department_id
GROUP BY   d.name, p.pub_year
ORDER BY   d.name, p.pub_year$$


-- ------------------------------------------------------------
--  v_prerequisite_tree
--  Direct prerequisites only (use sp_get_prerequisite_chain for full depth).
--  Demonstrates: self-join on courses.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_prerequisite_tree$$
CREATE VIEW v_prerequisite_tree AS
SELECT
    c.code                                            AS course_code,
    c.title                                           AS course_title,
    p.code                                            AS prerequisite_code,
    p.title                                           AS prerequisite_title,
    cp.is_mandatory
FROM       course_prerequisites cp
JOIN       courses c ON c.course_id = cp.course_id
JOIN       courses p ON p.course_id = cp.prerequisite_id$$


-- ============================================================
--  STORED PROCEDURES
-- ============================================================

-- ------------------------------------------------------------
--  sp_enroll_student
--  Enrolls a student in a section after checking:
--    1. Section is open
--    2. Student is not already enrolled
--    3. Required prerequisites are met
--  Demonstrates: multi-step validation, conditional SIGNAL, INSERT.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_enroll_student$$
CREATE PROCEDURE sp_enroll_student(
    IN  p_student_id INT UNSIGNED,
    IN  p_section_id INT UNSIGNED,
    OUT p_enrollment_id INT UNSIGNED
)
BEGIN
    DECLARE v_status      VARCHAR(20);
    DECLARE v_course_id   SMALLINT UNSIGNED;
    DECLARE v_missing_prereq VARCHAR(150) DEFAULT NULL;

    -- Check section is open
    SELECT status, course_id
    INTO   v_status, v_course_id
    FROM   sections
    WHERE  section_id = p_section_id;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Section not found';
    END IF;

    IF v_status <> 'open' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Section is not open for enrollment';
    END IF;

    -- Check not already enrolled
    IF EXISTS (
        SELECT 1 FROM enrollments
        WHERE  student_id = p_student_id
          AND  section_id = p_section_id
          AND  status NOT IN ('dropped')
    ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Student is already enrolled in this section';
    END IF;

    -- Check mandatory prerequisites
    SELECT c.title INTO v_missing_prereq
    FROM   course_prerequisites cp
    JOIN   courses c ON c.course_id = cp.prerequisite_id
    WHERE  cp.course_id    = v_course_id
      AND  cp.is_mandatory = TRUE
      AND  NOT EXISTS (
               SELECT 1
               FROM   enrollments e2
               JOIN   sections    s2 ON s2.section_id = e2.section_id
               WHERE  e2.student_id = p_student_id
                 AND  s2.course_id  = cp.prerequisite_id
                 AND  e2.status     = 'completed'
           )
    LIMIT 1;

    IF v_missing_prereq IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = CONCAT('Missing prerequisite: ', v_missing_prereq);
    END IF;

    -- Insert enrollment (capacity check is handled by trigger)
    INSERT INTO enrollments (student_id, section_id, status)
    VALUES (p_student_id, p_section_id, 'enrolled');

    SET p_enrollment_id = LAST_INSERT_ID();
END$$


-- ------------------------------------------------------------
--  sp_drop_enrollment
--  Changes enrollment status to 'dropped'.
--  Re-opens the section if it was closed due to capacity.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_drop_enrollment$$
CREATE PROCEDURE sp_drop_enrollment(
    IN p_enrollment_id INT UNSIGNED
)
BEGIN
    DECLARE v_section_id INT UNSIGNED;
    DECLARE v_current_status VARCHAR(20);

    SELECT section_id, status
    INTO   v_section_id, v_current_status
    FROM   enrollments
    WHERE  enrollment_id = p_enrollment_id;

    IF v_current_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Enrollment not found';
    END IF;

    IF v_current_status <> 'enrolled' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only active enrollments can be dropped';
    END IF;

    UPDATE enrollments
    SET    status = 'dropped'
    WHERE  enrollment_id = p_enrollment_id;

    -- Re-open section if it was closed due to capacity
    UPDATE sections sec
    JOIN (
        SELECT COUNT(*) AS enrolled_count
        FROM   enrollments
        WHERE  section_id = v_section_id
          AND  status     = 'enrolled'
    ) cnt ON TRUE
    SET    sec.status = 'open'
    WHERE  sec.section_id = v_section_id
      AND  sec.status     = 'closed'
      AND  cnt.enrolled_count < sec.max_capacity;
END$$


-- ------------------------------------------------------------
--  sp_submit_grade
--  Inserts a grade_event and recalculates the enrollment final_score.
--  Also updates final_grade letter and enrollment status on final exam.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_submit_grade$$
CREATE PROCEDURE sp_submit_grade(
    IN p_enrollment_id INT UNSIGNED,
    IN p_item_name     VARCHAR(100),
    IN p_item_type     ENUM('assignment','quiz','midterm','final','project','participation','lab'),
    IN p_score         DECIMAL(6,2),
    IN p_max_score     DECIMAL(6,2),
    IN p_weight        DECIMAL(5,4),
    IN p_grader_id     SMALLINT UNSIGNED
)
BEGIN
    DECLARE v_weighted_score DECIMAL(8,4);

    -- Insert grade event
    INSERT INTO grade_events
        (enrollment_id, item_name, item_type, score, max_score, weight, graded_at, grader_id)
    VALUES
        (p_enrollment_id, p_item_name, p_item_type, p_score, p_max_score, p_weight, NOW(), p_grader_id);

    -- Recalculate weighted final score for this enrollment
    SELECT SUM((score / max_score) * weight * 100)
    INTO   v_weighted_score
    FROM   grade_events
    WHERE  enrollment_id = p_enrollment_id;

    -- Derive letter grade from weighted score
    UPDATE enrollments
    SET    final_score = ROUND(v_weighted_score, 2),
           final_grade = CASE
               WHEN v_weighted_score >= 93 THEN 'A'
               WHEN v_weighted_score >= 90 THEN 'A-'
               WHEN v_weighted_score >= 87 THEN 'B+'
               WHEN v_weighted_score >= 83 THEN 'B'
               WHEN v_weighted_score >= 80 THEN 'B-'
               WHEN v_weighted_score >= 77 THEN 'C+'
               WHEN v_weighted_score >= 73 THEN 'C'
               WHEN v_weighted_score >= 70 THEN 'C-'
               WHEN v_weighted_score >= 60 THEN 'D'
               ELSE                             'F'
           END,
           -- Mark as completed or failed when a 'final' item is submitted
           status = CASE
               WHEN p_item_type = 'final' AND v_weighted_score >= 60 THEN 'completed'
               WHEN p_item_type = 'final' AND v_weighted_score <  60 THEN 'failed'
               ELSE status
           END
    WHERE  enrollment_id = p_enrollment_id;
END$$


-- ------------------------------------------------------------
--  sp_calculate_gpa
--  Returns the cumulative GPA for a student and updates students.gpa.
--  Demonstrates: OUT parameter, computed aggregation.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_calculate_gpa$$
CREATE PROCEDURE sp_calculate_gpa(
    IN  p_student_id INT UNSIGNED,
    OUT p_gpa        DECIMAL(4,3)
)
BEGIN
    SELECT ROUND(
        SUM(
            CASE e.final_grade
                WHEN 'A'  THEN 4.0 WHEN 'A-' THEN 3.7
                WHEN 'B+' THEN 3.3 WHEN 'B'  THEN 3.0 WHEN 'B-' THEN 2.7
                WHEN 'C+' THEN 2.3 WHEN 'C'  THEN 2.0 WHEN 'C-' THEN 1.7
                WHEN 'D'  THEN 1.0 ELSE 0.0
            END * c.credits
        ) / NULLIF(SUM(c.credits), 0),
    3)
    INTO p_gpa
    FROM       enrollments e
    JOIN       sections    sec ON sec.section_id = e.section_id
    JOIN       courses     c   ON c.course_id    = sec.course_id
    WHERE      e.student_id = p_student_id
      AND      e.status     = 'completed';

    UPDATE students
    SET    gpa = p_gpa
    WHERE  student_id = p_student_id;
END$$


-- ------------------------------------------------------------
--  sp_get_prerequisite_chain
--  Returns the full recursive prerequisite tree for a given course.
--  Demonstrates: recursive CTE in a stored procedure.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_get_prerequisite_chain$$
CREATE PROCEDURE sp_get_prerequisite_chain(
    IN p_course_id SMALLINT UNSIGNED
)
BEGIN
    WITH RECURSIVE prereq_tree AS (
        -- Anchor: direct prerequisites
        SELECT
            cp.course_id,
            cp.prerequisite_id,
            c.code            AS course_code,
            p.code            AS prereq_code,
            p.title           AS prereq_title,
            cp.is_mandatory,
            1                 AS depth
        FROM   course_prerequisites cp
        JOIN   courses c ON c.course_id = cp.course_id
        JOIN   courses p ON p.course_id = cp.prerequisite_id
        WHERE  cp.course_id = p_course_id

        UNION ALL

        -- Recursive: prerequisites of prerequisites
        SELECT
            cp2.course_id,
            cp2.prerequisite_id,
            c2.code,
            p2.code,
            p2.title,
            cp2.is_mandatory,
            pt.depth + 1
        FROM   course_prerequisites cp2
        JOIN   prereq_tree          pt ON pt.prerequisite_id = cp2.course_id
        JOIN   courses              c2 ON c2.course_id       = cp2.course_id
        JOIN   courses              p2 ON p2.course_id       = cp2.prerequisite_id
        WHERE  pt.depth < 10  -- safety guard against circular data
    )
    SELECT DISTINCT
        depth,
        prereq_code,
        prereq_title,
        is_mandatory
    FROM  prereq_tree
    ORDER BY depth, prereq_code;
END$$


-- ------------------------------------------------------------
--  sp_search_courses_semantic
--  Nearest-neighbour vector search over courses.embedding.
--  Demonstrates: VECTOR type, VEC_Distance (MariaDB 11.7+).
--  p_embedding must be a valid VECTOR(1536) value.
-- ------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_search_courses_semantic$$
CREATE PROCEDURE sp_search_courses_semantic(
    IN p_embedding VECTOR(1536),
    IN p_limit     INT UNSIGNED
)
BEGIN
    SELECT
        c.course_id,
        c.code,
        c.title,
        c.credits,
        d.name                                        AS department,
        VEC_Distance(c.embedding, p_embedding)        AS distance
    FROM   courses      c
    JOIN   departments  d ON d.department_id = c.department_id
    WHERE  c.embedding IS NOT NULL
      AND  c.is_active  = TRUE
    ORDER BY distance
    LIMIT p_limit;
END$$

DELIMITER ;
