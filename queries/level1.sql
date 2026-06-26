-- ============================================================
--  Level 1 — Basic SQL
--  Topics: SELECT, WHERE, ORDER BY, LIMIT, basic aggregation
-- ============================================================
USE university;

-- 1.1  List all active departments sorted by name
SELECT code, name, level
FROM   departments
WHERE  level = 2
ORDER  BY name;

-- 1.2  Show the 10 most recent student registrations
SELECT student_number, first_name, last_name, email, enrollment_date
FROM   students
ORDER  BY enrollment_date DESC
LIMIT  10;

-- 1.3  Count students by status
SELECT status, COUNT(*) AS total
FROM   students
GROUP  BY status
ORDER  BY total DESC;

-- 1.4  Find all courses worth more than 3 credits
SELECT code, title, credits, level
FROM   courses
WHERE  credits > 3
ORDER  BY credits DESC, title;

-- 1.5  List professors (rank = 'Professor') ordered by hire date
SELECT first_name, last_name, rank, hire_date, office
FROM   faculty
WHERE  rank = 'Professor'
ORDER  BY hire_date;

-- 1.6  How many rooms does each building have, and what is the total capacity?
SELECT building,
       COUNT(*)       AS room_count,
       SUM(capacity)  AS total_capacity,
       MAX(capacity)  AS largest_room
FROM   rooms
WHERE  room_type <> 'online'
GROUP  BY building
ORDER  BY total_capacity DESC;

-- 1.7  Show the current active semester
SELECT semester_id, name, start_date, end_date, enroll_deadline
FROM   semesters
WHERE  is_active = TRUE;

-- 1.8  Count courses per department (level 2 departments only)
SELECT d.name AS department, COUNT(c.course_id) AS course_count
FROM   departments d
LEFT JOIN courses c ON c.department_id = d.department_id
WHERE  d.level = 2
GROUP  BY d.department_id, d.name
ORDER  BY course_count DESC;

-- 1.9  Find students born in the 1990s
SELECT student_number, first_name, last_name, date_of_birth
FROM   students
WHERE  date_of_birth BETWEEN '1990-01-01' AND '1999-12-31'
ORDER  BY date_of_birth;

-- 1.10  Scholarships offering more than $5 000 per year
SELECT name, amount, frequency
FROM   scholarships
WHERE  frequency = 'annual'
  AND  amount    > 5000
  AND  is_active = TRUE
ORDER  BY amount DESC;
