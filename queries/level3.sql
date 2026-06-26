-- ============================================================
--  Level 3 — Advanced SQL
--  Topics: window functions, CTEs, recursive CTEs,
--          JSON_TABLE, SET operations, VECTOR search
-- ============================================================
USE university;

-- ============================================================
--  WINDOW FUNCTIONS
-- ============================================================

-- 3.1  Rank students within each department by GPA
SELECT d.name AS department,
       s.student_number,
       CONCAT(s.first_name, ' ', s.last_name) AS student_name,
       s.gpa,
       RANK()        OVER w AS rank_in_dept,
       DENSE_RANK()  OVER w AS dense_rank,
       PERCENT_RANK() OVER w AS pct_rank
FROM   students    s
JOIN   departments d ON d.department_id = s.department_id
WHERE  s.gpa IS NOT NULL
WINDOW w AS (PARTITION BY s.department_id ORDER BY s.gpa DESC);

-- 3.2  Running total of grade_event scores per enrollment (time-ordered)
SELECT e.enrollment_id,
       ge.graded_at,
       ge.item_name,
       ge.item_type,
       ge.score,
       SUM(ge.score)  OVER (PARTITION BY ge.enrollment_id
                            ORDER BY ge.graded_at
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                              AS running_total,
       AVG(ge.score)  OVER (PARTITION BY ge.enrollment_id
                            ORDER BY ge.graded_at
                            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
                                              AS moving_avg_3
FROM   grade_events ge
JOIN   enrollments  e ON e.enrollment_id = ge.enrollment_id
ORDER  BY ge.enrollment_id, ge.graded_at
LIMIT  100;

-- 3.3  Score difference vs previous grade event (LAG / LEAD)
SELECT ge.enrollment_id,
       ge.item_name,
       ge.graded_at,
       ge.score,
       LAG(ge.score)  OVER (PARTITION BY ge.enrollment_id ORDER BY ge.graded_at) AS prev_score,
       ge.score
       - LAG(ge.score) OVER (PARTITION BY ge.enrollment_id ORDER BY ge.graded_at) AS delta,
       LEAD(ge.score) OVER (PARTITION BY ge.enrollment_id ORDER BY ge.graded_at) AS next_score
FROM   grade_events ge
ORDER  BY ge.enrollment_id, ge.graded_at
LIMIT  100;

-- 3.4  Top-3 students per course by final score (ROW_NUMBER)
SELECT *
FROM (
    SELECT c.code,
           c.title,
           CONCAT(s.first_name, ' ', s.last_name) AS student_name,
           e.final_score,
           e.final_grade,
           ROW_NUMBER() OVER (PARTITION BY c.course_id ORDER BY e.final_score DESC) AS rn
    FROM   enrollments e
    JOIN   sections    sec ON sec.section_id = e.section_id
    JOIN   courses     c   ON c.course_id    = sec.course_id
    JOIN   students    s   ON s.student_id   = e.student_id
    WHERE  e.status = 'completed'
) ranked
WHERE rn <= 3
ORDER BY code, rn;

-- 3.5  Monthly enrollment trend (window frame over the audit_log)
SELECT DATE_FORMAT(changed_at, '%Y-%m') AS month,
       COUNT(*)                          AS new_enrollments,
       SUM(COUNT(*)) OVER (ORDER BY DATE_FORMAT(changed_at, '%Y-%m')
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                         AS cumulative_enrollments
FROM   audit_log
WHERE  table_name = 'enrollments'
  AND  action     = 'INSERT'
GROUP  BY month
ORDER  BY month;


-- ============================================================
--  CTEs  (non-recursive)
-- ============================================================

-- 3.6  Students above average — CTE version
WITH dept_avg AS (
    SELECT department_id,
           AVG(gpa) AS avg_gpa
    FROM   students
    WHERE  gpa IS NOT NULL
    GROUP  BY department_id
)
SELECT s.student_number,
       CONCAT(s.first_name, ' ', s.last_name) AS student_name,
       d.name                                  AS department,
       s.gpa,
       ROUND(s.gpa - da.avg_gpa, 3)           AS above_dept_avg
FROM   students    s
JOIN   departments d  ON d.department_id  = s.department_id
JOIN   dept_avg    da ON da.department_id = s.department_id
WHERE  s.gpa > da.avg_gpa
ORDER  BY above_dept_avg DESC
LIMIT  30;

-- 3.7  Course completion funnel (CTE chaining)
WITH enrolled AS (
    SELECT sec.course_id, COUNT(*) AS total_enrolled
    FROM   enrollments e
    JOIN   sections    sec ON sec.section_id = e.section_id
    GROUP  BY sec.course_id
),
completed AS (
    SELECT sec.course_id, COUNT(*) AS total_completed
    FROM   enrollments e
    JOIN   sections    sec ON sec.section_id = e.section_id
    WHERE  e.status = 'completed'
    GROUP  BY sec.course_id
),
failed AS (
    SELECT sec.course_id, COUNT(*) AS total_failed
    FROM   enrollments e
    JOIN   sections    sec ON sec.section_id = e.section_id
    WHERE  e.status = 'failed'
    GROUP  BY sec.course_id
)
SELECT c.code, c.title,
       COALESCE(en.total_enrolled,  0) AS enrolled,
       COALESCE(co.total_completed, 0) AS completed,
       COALESCE(fa.total_failed,    0) AS failed,
       ROUND(100.0 * COALESCE(co.total_completed, 0)
                   / NULLIF(en.total_enrolled, 0), 1)  AS completion_pct
FROM   courses   c
LEFT JOIN enrolled  en ON en.course_id = c.course_id
LEFT JOIN completed co ON co.course_id = c.course_id
LEFT JOIN failed    fa ON fa.course_id = c.course_id
WHERE  en.total_enrolled > 0
ORDER  BY completion_pct DESC;


-- ============================================================
--  RECURSIVE CTEs
-- ============================================================

-- 3.8  Full department hierarchy (all 3 levels)
WITH RECURSIVE dept_tree AS (
    -- Anchor: top-level faculties
    SELECT department_id, parent_id, code, name, level,
           name                AS path,
           CAST(code AS CHAR(300)) AS code_path
    FROM   departments
    WHERE  parent_id IS NULL

    UNION ALL

    -- Recursive: sub-departments
    SELECT d.department_id, d.parent_id, d.code, d.name, d.level,
           CONCAT(dt.path, ' > ', d.name),
           CONCAT(dt.code_path, ' / ', d.code)
    FROM   departments d
    JOIN   dept_tree   dt ON dt.department_id = d.parent_id
)
SELECT level, code, name, path
FROM   dept_tree
ORDER  BY code_path;

-- 3.9  Full prerequisite chain for a course (replace CS100 with any code)
WITH RECURSIVE prereq_chain AS (
    SELECT cp.course_id,
           cp.prerequisite_id,
           c.code   AS course_code,
           p.code   AS prereq_code,
           p.title  AS prereq_title,
           1        AS depth
    FROM   course_prerequisites cp
    JOIN   courses c ON c.course_id = cp.course_id
    JOIN   courses p ON p.course_id = cp.prerequisite_id
    WHERE  c.code = 'CS100'

    UNION ALL

    SELECT cp2.course_id,
           cp2.prerequisite_id,
           pc.course_code,
           p2.code,
           p2.title,
           pc.depth + 1
    FROM   course_prerequisites cp2
    JOIN   prereq_chain         pc ON pc.prerequisite_id = cp2.course_id
    JOIN   courses              p2 ON p2.course_id       = cp2.prerequisite_id
    WHERE  pc.depth < 10
)
SELECT DISTINCT depth, prereq_code, prereq_title
FROM   prereq_chain
ORDER  BY depth, prereq_code;


-- ============================================================
--  JSON functions
-- ============================================================

-- 3.10  Expand faculty office hours with JSON_TABLE
SELECT f.first_name, f.last_name,
       oh.day, oh.start, oh.end
FROM   faculty f,
       JSON_TABLE(
           f.office_hours,
           '$[*]' COLUMNS (
               day   VARCHAR(10) PATH '$.day',
               start VARCHAR(5)  PATH '$.start',
               `end` VARCHAR(5)  PATH '$.end'
           )
       ) AS oh
WHERE  f.office_hours IS NOT NULL
ORDER  BY f.last_name, FIELD(oh.day,'Mon','Tue','Wed','Thu','Fri');

-- 3.11  Scholarship eligibility — extract JSON fields for filtering
SELECT name, amount,
       JSON_VALUE(eligibility, '$.min_gpa')         AS min_gpa,
       JSON_VALUE(eligibility, '$.need_based')      AS need_based,
       JSON_VALUE(eligibility, '$.max_family_income') AS max_income
FROM   scholarships
WHERE  JSON_VALUE(eligibility, '$.need_based') = 'true'
  AND  CAST(JSON_VALUE(eligibility, '$.min_gpa') AS DECIMAL(3,1)) <= 3.0
ORDER  BY amount DESC;

-- 3.12  Audit log — compare old vs new values with JSON_VALUE
SELECT table_name,
       record_id,
       changed_at,
       JSON_VALUE(old_values, '$.status')      AS old_status,
       JSON_VALUE(new_values, '$.status')      AS new_status,
       JSON_VALUE(old_values, '$.final_grade') AS old_grade,
       JSON_VALUE(new_values, '$.final_grade') AS new_grade
FROM   audit_log
WHERE  table_name = 'enrollments'
  AND  action     = 'UPDATE'
  AND  JSON_VALUE(old_values, '$.status') <> JSON_VALUE(new_values, '$.status')
ORDER  BY changed_at DESC
LIMIT  20;


-- ============================================================
--  SET type queries
-- ============================================================

-- 3.13  Publications tagged with both 'AI' and 'Databases'
SELECT pub_year, title, keywords, citation_count
FROM   publications
WHERE  FIND_IN_SET('AI',        keywords) > 0
  AND  FIND_IN_SET('Databases', keywords) > 0
ORDER  BY citation_count DESC;

-- 3.14  Count publications per keyword tag
SELECT 'AI'          AS keyword, COUNT(*) AS count FROM publications WHERE FIND_IN_SET('AI',          keywords) UNION ALL
SELECT 'ML',                     COUNT(*) FROM publications WHERE FIND_IN_SET('ML',          keywords) UNION ALL
SELECT 'Databases',              COUNT(*) FROM publications WHERE FIND_IN_SET('Databases',   keywords) UNION ALL
SELECT 'Security',               COUNT(*) FROM publications WHERE FIND_IN_SET('Security',    keywords) UNION ALL
SELECT 'Networking',             COUNT(*) FROM publications WHERE FIND_IN_SET('Networking',  keywords)
ORDER  BY count DESC;


-- ============================================================
--  VECTOR similarity search (MariaDB 11.7+)
-- ============================================================

-- 3.15  Find the 5 courses most similar to CS100 (by embedding distance)
--       Uses VEC_Distance — lower = more similar (Euclidean by default)
SELECT target.code AS reference_course,
       c.code      AS similar_course,
       c.title,
       VEC_Distance(target.embedding, c.embedding) AS distance
FROM   courses target
JOIN   courses c ON c.course_id <> target.course_id
                AND c.embedding IS NOT NULL
WHERE  target.code      = 'CS100'
  AND  target.embedding IS NOT NULL
ORDER  BY distance
LIMIT  5;
