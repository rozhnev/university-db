-- ============================================================
--  Level 2 — Intermediate SQL
--  Topics: multi-table JOINs, subqueries, HAVING,
--          FULLTEXT search, INSERT/UPDATE/DELETE
-- ============================================================
USE university;

-- 2.1  Full roster for a given section (replace 1 with any section_id)
SELECT s.student_number,
       CONCAT(s.first_name, ' ', s.last_name) AS student_name,
       s.email,
       e.status,
       e.final_grade
FROM   enrollments  e
JOIN   students     s   ON s.student_id  = e.student_id
WHERE  e.section_id = 1
ORDER  BY s.last_name, s.first_name;

-- 2.2  Courses taught by a specific faculty member across all semesters
SELECT c.code, c.title, sem.name AS semester, sec.delivery, sec.status
FROM   sections    sec
JOIN   courses     c   ON c.course_id    = sec.course_id
JOIN   semesters   sem ON sem.semester_id = sec.semester_id
WHERE  sec.faculty_id = 1
ORDER  BY sem.start_date DESC;

-- 2.3  Average final score per course (completed enrollments only)
SELECT c.code, c.title,
       COUNT(e.enrollment_id)   AS students_completed,
       ROUND(AVG(e.final_score), 2) AS avg_score,
       MIN(e.final_score)       AS min_score,
       MAX(e.final_score)       AS max_score
FROM   courses    c
JOIN   sections   sec ON sec.course_id  = c.course_id
JOIN   enrollments e  ON e.section_id   = sec.section_id
WHERE  e.status = 'completed'
GROUP  BY c.course_id, c.code, c.title
HAVING COUNT(e.enrollment_id) >= 5
ORDER  BY avg_score DESC;

-- 2.4  Students with GPA above the department average
SELECT s.student_number,
       CONCAT(s.first_name, ' ', s.last_name) AS student_name,
       d.name AS department,
       s.gpa
FROM   students    s
JOIN   departments d ON d.department_id = s.department_id
WHERE  s.gpa > (
    SELECT AVG(s2.gpa)
    FROM   students s2
    WHERE  s2.department_id = s.department_id
      AND  s2.gpa IS NOT NULL
)
ORDER  BY d.name, s.gpa DESC;

-- 2.5  Sections that are over 90% full
SELECT c.code, c.title, sem.name AS semester,
       sec.max_capacity,
       COUNT(e.enrollment_id)                            AS enrolled,
       ROUND(100.0 * COUNT(e.enrollment_id) / sec.max_capacity, 1) AS fill_pct
FROM   sections    sec
JOIN   courses     c   ON c.course_id    = sec.course_id
JOIN   semesters   sem ON sem.semester_id = sec.semester_id
LEFT JOIN enrollments e ON e.section_id  = sec.section_id
                       AND e.status      = 'enrolled'
WHERE  sec.status IN ('open','closed')
GROUP  BY sec.section_id, c.code, c.title, sem.name, sec.max_capacity
HAVING fill_pct >= 90
ORDER  BY fill_pct DESC;

-- 2.6  FULLTEXT search — courses matching 'machine learning'
SELECT code, title, credits, level,
       MATCH(title, description) AGAINST ('machine learning' IN NATURAL LANGUAGE MODE) AS relevance
FROM   courses
WHERE  MATCH(title, description) AGAINST ('machine learning' IN NATURAL LANGUAGE MODE)
ORDER  BY relevance DESC
LIMIT  10;

-- 2.7  FULLTEXT search — publications mentioning 'neural networks' (boolean mode)
SELECT pub_year, title, venue, citation_count
FROM   publications
WHERE  MATCH(title, abstract) AGAINST ('+"neural" "network"' IN BOOLEAN MODE)
ORDER  BY citation_count DESC
LIMIT  10;

-- 2.8  Students enrolled in more than 4 courses in the current semester
SELECT s.student_number,
       CONCAT(s.first_name, ' ', s.last_name) AS student_name,
       COUNT(e.enrollment_id) AS courses_this_semester
FROM   students    s
JOIN   enrollments e   ON e.student_id  = s.student_id
JOIN   sections    sec ON sec.section_id = e.section_id
JOIN   semesters   sem ON sem.semester_id = sec.semester_id
WHERE  sem.is_active = TRUE
  AND  e.status      = 'enrolled'
GROUP  BY s.student_id, s.student_number, student_name
HAVING courses_this_semester > 4
ORDER  BY courses_this_semester DESC;

-- 2.9  JSON — extract emergency contact name and phone for all students
SELECT student_number,
       CONCAT(first_name, ' ', last_name)               AS student_name,
       JSON_VALUE(contacts, '$.emergency.name')          AS emergency_contact,
       JSON_VALUE(contacts, '$.emergency.phone')         AS emergency_phone,
       JSON_VALUE(contacts, '$.address.city')            AS city
FROM   students
WHERE  contacts IS NOT NULL
LIMIT  20;

-- 2.10  Update: mark all students who have graduated (expected_grad < current year)
UPDATE students
SET    status = 'graduated'
WHERE  expected_grad < YEAR(CURDATE())
  AND  status        = 'active'
  AND  gpa           >= 2.0;

-- 2.11  Delete dropped enrollments older than 3 years (demonstrate DELETE)
-- (Wrapped in a transaction so you can roll back in practice)
START TRANSACTION;
DELETE FROM enrollments
WHERE  status     = 'dropped'
  AND  enrolled_at < DATE_SUB(NOW(), INTERVAL 3 YEAR);
ROLLBACK;  -- change to COMMIT to apply
