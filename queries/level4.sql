-- ============================================================
--  Level 4 — DBA / Developer SQL
--  Topics: EXPLAIN ANALYZE, index strategy, stored procedure
--          authoring, trigger inspection, transaction isolation,
--          complex multi-CTE analytical queries
-- ============================================================
USE university;

-- ============================================================
--  QUERY PLAN ANALYSIS
-- ============================================================

-- 4.1  Explain a full analytical query — check index usage
EXPLAIN ANALYZE
SELECT d.name AS department,
       ROUND(AVG(e.final_score), 2) AS avg_score,
       COUNT(e.enrollment_id)       AS total_completed
FROM   enrollments  e
JOIN   sections     sec ON sec.section_id  = e.section_id
JOIN   courses      c   ON c.course_id     = sec.course_id
JOIN   departments  d   ON d.department_id = c.department_id
WHERE  e.status = 'completed'
GROUP  BY d.department_id, d.name
ORDER  BY avg_score DESC;

-- 4.2  Show index usage on the big table
SHOW INDEX FROM grade_events;

-- 4.3  Analyze table statistics (useful before EXPLAIN)
ANALYZE TABLE grade_events, enrollments, sections;

-- 4.4  Compare with and without index hint on grade_events
--      (Observe difference in rows examined)
EXPLAIN
SELECT enrollment_id, COUNT(*) AS events
FROM   grade_events FORCE INDEX (idx_ge_item_type)
WHERE  item_type = 'final'
GROUP  BY enrollment_id;


-- ============================================================
--  COMPLEX MULTI-CTE ANALYTICAL QUERIES  (grade_events focus)
-- ============================================================

-- 4.5  Student performance dashboard — weighted score, rank, trend
--      Uses: multiple CTEs, window functions, JOIN
WITH weighted AS (
    SELECT ge.enrollment_id,
           SUM((ge.score / ge.max_score) * ge.weight * 100) AS weighted_pct
    FROM   grade_events ge
    GROUP  BY ge.enrollment_id
),
enrollment_info AS (
    SELECT e.enrollment_id,
           e.student_id,
           e.section_id,
           e.status,
           e.final_grade,
           w.weighted_pct
    FROM   enrollments e
    JOIN   weighted    w ON w.enrollment_id = e.enrollment_id
),
course_rank AS (
    SELECT ei.*,
           sec.course_id,
           RANK() OVER (PARTITION BY sec.course_id ORDER BY ei.weighted_pct DESC) AS rank_in_course,
           ROUND(AVG(ei.weighted_pct) OVER (PARTITION BY sec.course_id), 2)       AS course_avg
    FROM   enrollment_info ei
    JOIN   sections        sec ON sec.section_id = ei.section_id
)
SELECT c.code, c.title,
       CONCAT(s.first_name, ' ', s.last_name) AS student_name,
       cr.weighted_pct,
       cr.course_avg,
       cr.rank_in_course,
       cr.final_grade
FROM   course_rank cr
JOIN   students    s ON s.student_id = cr.student_id
JOIN   courses     c ON c.course_id  = cr.course_id
WHERE  cr.rank_in_course <= 5
ORDER  BY c.code, cr.rank_in_course;

-- 4.6  Grade distribution histogram per course (A/B/C/D/F buckets)
SELECT c.code, c.title,
       SUM(CASE WHEN e.final_grade IN ('A','A-')       THEN 1 ELSE 0 END) AS grade_A,
       SUM(CASE WHEN e.final_grade IN ('B+','B','B-')  THEN 1 ELSE 0 END) AS grade_B,
       SUM(CASE WHEN e.final_grade IN ('C+','C','C-')  THEN 1 ELSE 0 END) AS grade_C,
       SUM(CASE WHEN e.final_grade = 'D'               THEN 1 ELSE 0 END) AS grade_D,
       SUM(CASE WHEN e.final_grade = 'F'               THEN 1 ELSE 0 END) AS grade_F,
       COUNT(e.enrollment_id)                                             AS total
FROM   courses    c
JOIN   sections   sec ON sec.course_id  = c.course_id
JOIN   enrollments e  ON e.section_id   = sec.section_id
WHERE  e.status = 'completed'
GROUP  BY c.course_id, c.code, c.title
HAVING total >= 10
ORDER  BY c.code;

-- 4.7  Semester-over-semester GPA trend per student (LAG)
WITH sem_gpa AS (
    SELECT e.student_id,
           sem.semester_id,
           sem.name AS semester,
           sem.academic_year,
           sem.term,
           ROUND(SUM(
               CASE e.final_grade
                   WHEN 'A'  THEN 4.0 WHEN 'A-' THEN 3.7
                   WHEN 'B+' THEN 3.3 WHEN 'B'  THEN 3.0 WHEN 'B-' THEN 2.7
                   WHEN 'C+' THEN 2.3 WHEN 'C'  THEN 2.0 WHEN 'C-' THEN 1.7
                   WHEN 'D'  THEN 1.0 ELSE 0.0
               END * c.credits
           ) / NULLIF(SUM(c.credits), 0), 3) AS sem_gpa
    FROM   enrollments e
    JOIN   sections    sec ON sec.section_id = e.section_id
    JOIN   courses     c   ON c.course_id    = sec.course_id
    JOIN   semesters   sem ON sem.semester_id = sec.semester_id
    WHERE  e.status = 'completed'
    GROUP  BY e.student_id, sem.semester_id, sem.name, sem.academic_year, sem.term
)
SELECT student_id, semester,
       sem_gpa,
       LAG(sem_gpa) OVER (PARTITION BY student_id ORDER BY semester_id) AS prev_sem_gpa,
       sem_gpa - LAG(sem_gpa) OVER (PARTITION BY student_id ORDER BY semester_id) AS delta_gpa
FROM   sem_gpa
ORDER  BY student_id, semester_id;

-- 4.8  Faculty publication productivity vs teaching load (cross-domain join)
WITH teaching AS (
    SELECT faculty_id,
           COUNT(DISTINCT section_id)    AS sections_taught,
           COUNT(DISTINCT semester_id)   AS semesters_active
    FROM   sections
    GROUP  BY faculty_id
),
research AS (
    SELECT pm.faculty_id,
           COUNT(DISTINCT pm.project_id) AS projects,
           COUNT(DISTINCT p.publication_id) AS publications,
           SUM(p.citation_count)          AS total_citations
    FROM   project_members pm
    LEFT JOIN publications  p  ON p.project_id = pm.project_id
    WHERE  pm.faculty_id IS NOT NULL
    GROUP  BY pm.faculty_id
)
SELECT CONCAT(f.first_name, ' ', f.last_name) AS faculty_name,
       f.rank,
       d.name                                  AS department,
       COALESCE(t.sections_taught, 0)          AS sections_taught,
       COALESCE(r.projects, 0)                 AS research_projects,
       COALESCE(r.publications, 0)             AS publications,
       COALESCE(r.total_citations, 0)          AS total_citations
FROM   faculty     f
JOIN   departments d ON d.department_id = f.department_id
LEFT JOIN teaching   t ON t.faculty_id = f.faculty_id
LEFT JOIN research   r ON r.faculty_id = f.faculty_id
ORDER  BY publications DESC, total_citations DESC;


-- ============================================================
--  TRANSACTION CONTROL & ISOLATION LEVELS
-- ============================================================

-- 4.9  Enroll a student safely inside an explicit transaction
START TRANSACTION;

CALL sp_enroll_student(1, 1, @new_enrollment_id);
SELECT @new_enrollment_id AS enrollment_id;

-- Verify the trigger wrote to audit_log
SELECT * FROM audit_log
WHERE  table_name = 'enrollments'
  AND  record_id  = @new_enrollment_id;

ROLLBACK;   -- or COMMIT to keep

-- 4.10  Observe REPEATABLE READ vs READ COMMITTED
--       (run this in two sessions simultaneously to observe phantom reads)
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION;
SELECT COUNT(*) FROM enrollments WHERE status = 'enrolled';
-- (in another session: INSERT or UPDATE an enrollment)
SELECT COUNT(*) FROM enrollments WHERE status = 'enrolled';  -- same count under RR
COMMIT;


-- ============================================================
--  STORED PROCEDURE CALL EXAMPLES
-- ============================================================

-- 4.11  Get the full prerequisite chain for a course
CALL sp_get_prerequisite_chain(1);

-- 4.12  Calculate and store a student's GPA
CALL sp_calculate_gpa(1, @gpa);
SELECT @gpa AS student_gpa;

-- 4.13  Submit a grade event
CALL sp_submit_grade(
    1,              -- enrollment_id
    'Midterm Exam', -- item_name
    'midterm',      -- item_type
    82.50,          -- score
    100.00,         -- max_score
    0.2000,         -- weight (20% of final grade)
    1               -- grader_id (faculty)
);

-- 4.14  Vector semantic search — top 10 courses most similar to course #1
CALL sp_search_courses_semantic(
    (SELECT embedding FROM courses WHERE course_id = 1 LIMIT 1),
    10
);


-- ============================================================
--  AUDIT LOG FORENSICS
-- ============================================================

-- 4.15  Detect students whose GPA dropped between audit entries
SELECT al.record_id AS student_id,
       al.changed_at,
       CAST(JSON_VALUE(al.old_values, '$.gpa') AS DECIMAL(4,3)) AS gpa_before,
       CAST(JSON_VALUE(al.new_values, '$.gpa') AS DECIMAL(4,3)) AS gpa_after,
       CAST(JSON_VALUE(al.new_values, '$.gpa') AS DECIMAL(4,3))
       - CAST(JSON_VALUE(al.old_values, '$.gpa') AS DECIMAL(4,3))   AS gpa_change
FROM   audit_log al
WHERE  al.table_name = 'students'
  AND  al.action     = 'UPDATE'
  AND  JSON_VALUE(al.old_values, '$.gpa') IS NOT NULL
  AND  CAST(JSON_VALUE(al.new_values, '$.gpa') AS DECIMAL(4,3))
     < CAST(JSON_VALUE(al.old_values, '$.gpa') AS DECIMAL(4,3))
ORDER  BY gpa_change
LIMIT  20;

-- 4.16  Audit log activity heatmap — changes by hour of day and day of week
SELECT DAYNAME(changed_at)  AS day_of_week,
       HOUR(changed_at)     AS hour_of_day,
       COUNT(*)             AS change_count
FROM   audit_log
GROUP  BY day_of_week, hour_of_day
ORDER  BY DAYOFWEEK(changed_at), hour_of_day;
