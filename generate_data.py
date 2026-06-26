#!/usr/bin/env python3
"""
University DB — Data Generator
Phase 4 / 5

Generates realistic data for:
  - faculty         (~250 rows)
  - students        (~2 000 rows)
  - courses         (~200 rows, with synthetic VECTOR(1536) embeddings)
  - course_prerequisites
  - sections        (~800 rows)
  - enrollments     (~8 000 rows)
  - grade_events    (~120 000 rows)  ← big analytic table
  - research_projects, publications, project_members
  - student_scholarships

Requirements:
    pip install faker mysql-connector-python numpy

Usage:
    python generate_data.py --host 127.0.0.1 --port 3306 \
                            --user root --password secret \
                            [--database university] [--seed 42]
"""

import argparse
import json
import math
import random
import struct
from datetime import date, datetime, timedelta

import numpy as np
import mysql.connector
from faker import Faker

# ---------------------------------------------------------------------------
#  CLI
# ---------------------------------------------------------------------------
parser = argparse.ArgumentParser(description="Generate University DB sample data")
parser.add_argument("--host",     default="127.0.0.1")
parser.add_argument("--port",     type=int, default=3306)
parser.add_argument("--user",     default="root")
parser.add_argument("--password", default="")
parser.add_argument("--database", default="university")
parser.add_argument("--seed",     type=int, default=42, help="Random seed for reproducibility")
args = parser.parse_args()

SEED = args.seed
random.seed(SEED)
np.random.seed(SEED)
fake = Faker("en_US")
fake.seed_instance(SEED)

# ---------------------------------------------------------------------------
#  DB connection
# ---------------------------------------------------------------------------
conn = mysql.connector.connect(
    host=args.host,
    port=args.port,
    user=args.user,
    password=args.password,
    database=args.database,
    charset="utf8mb4",
)
cur = conn.cursor()


# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------
def rand_date(start: date, end: date) -> date:
    delta = (end - start).days
    return start + timedelta(days=random.randint(0, delta))


def normal_score(mean=75.0, std=12.0, low=20.0, high=100.0) -> float:
    """Clipped normal distribution for grade scores."""
    return float(np.clip(np.random.normal(mean, std), low, high))


def synthetic_unit_vector(dims: int = 1536) -> bytes:
    """
    Returns a random unit vector as MariaDB VECTOR binary format.
    MariaDB stores VECTOR(N) as N * 4 bytes of IEEE 754 float32 (little-endian).
    """
    v = np.random.randn(dims).astype(np.float32)
    v /= np.linalg.norm(v)
    return struct.pack(f"<{dims}f", *v)


def batch_insert(table: str, columns: list[str], rows: list[tuple], batch: int = 500) -> None:
    if not rows:
        return
    placeholders = ", ".join(["%s"] * len(columns))
    sql = f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({placeholders})"
    for i in range(0, len(rows), batch):
        cur.executemany(sql, rows[i : i + batch])
    conn.commit()
    print(f"  ✓  {table}: {len(rows):,} rows")


# ---------------------------------------------------------------------------
#  Load reference data already in DB
# ---------------------------------------------------------------------------
cur.execute("SELECT department_id, level FROM departments")
departments = cur.fetchall()
dept_ids_l2 = [d[0] for d in departments if d[1] == 2]   # level-2 for faculty/students
dept_ids_all = [d[0] for d in departments]

cur.execute("SELECT semester_id, start_date, end_date FROM semesters ORDER BY start_date")
semesters = [(r[0], r[1], r[2]) for r in cur.fetchall()]

cur.execute("SELECT room_id, capacity, room_type FROM rooms")
rooms = cur.fetchall()
rooms_physical = [(r[0], r[1]) for r in rooms if r[2] != "online"]

cur.execute("SELECT scholarship_id FROM scholarships WHERE is_active = 1")
scholarship_ids = [r[0] for r in cur.fetchall()]

# ---------------------------------------------------------------------------
#  faculty  (~250 rows)
# ---------------------------------------------------------------------------
print("\n[1/9] Generating faculty …")
RANKS = ["Instructor", "Assistant Professor", "Associate Professor", "Professor", "Emeritus"]
RANK_WEIGHTS = [0.15, 0.30, 0.25, 0.25, 0.05]

faculty_rows = []
used_emails: set[str] = set()

for _ in range(250):
    first = fake.first_name()
    last  = fake.last_name()
    email_base = f"{first.lower()}.{last.lower()}@university.edu"
    email = email_base
    suffix = 1
    while email in used_emails:
        email = f"{first.lower()}.{last.lower()}{suffix}@university.edu"
        suffix += 1
    used_emails.add(email)

    rank      = random.choices(RANKS, RANK_WEIGHTS)[0]
    hire_date = rand_date(date(1990, 1, 1), date(2024, 8, 1))
    dept_id   = random.choice(dept_ids_l2)
    office    = f"{random.choice(['HH','MS','BC','EH','WB','PM'])}-{random.randint(100,399)}"

    days = random.sample(["Mon","Tue","Wed","Thu","Fri"], k=random.randint(1, 3))
    office_hours = [
        {"day": d, "start": f"{random.randint(8,15):02d}:00", "end": f"{random.randint(9,16):02d}:00"}
        for d in days
    ]

    faculty_rows.append((
        dept_id, first, last, email,
        fake.phone_number()[:20],
        rank, hire_date, office,
        json.dumps(office_hours),
        fake.text(max_nb_chars=300),
        True,
    ))

batch_insert(
    "faculty",
    ["department_id","first_name","last_name","email","phone",
     "rank","hire_date","office","office_hours","bio","is_active"],
    faculty_rows,
)

cur.execute("SELECT faculty_id, department_id FROM faculty")
faculty_db = cur.fetchall()   # [(faculty_id, department_id), …]
faculty_ids = [f[0] for f in faculty_db]

# Assign department heads
cur.execute("SELECT department_id FROM departments")
all_dept_ids = [r[0] for r in cur.fetchall()]
for dept_id in all_dept_ids:
    candidates = [f[0] for f in faculty_db if f[1] == dept_id]
    if not candidates:
        candidates = faculty_ids          # fallback: any faculty
    cur.execute(
        "UPDATE departments SET head_faculty_id = %s WHERE department_id = %s",
        (random.choice(candidates), dept_id),
    )
conn.commit()
print("  ✓  departments.head_faculty_id assigned")


# ---------------------------------------------------------------------------
#  students  (~2 000 rows)
# ---------------------------------------------------------------------------
print("\n[2/9] Generating students …")
GENDERS = ["M", "F", "NB", "Other", "Prefer not to say"]
GENDER_W = [0.46, 0.46, 0.04, 0.02, 0.02]

student_rows = []
used_student_emails: set[str] = set()

for i in range(2000):
    first  = fake.first_name()
    last   = fake.last_name()
    number = f"S{i+1:06d}"
    email  = f"{number}@students.university.edu"
    dob    = rand_date(date(1995, 1, 1), date(2007, 12, 31))
    enroll = rand_date(date(2020, 8, 1), date(2025, 8, 31))
    exp_grad_year = enroll.year + random.choice([2, 3, 4])

    contacts = {
        "emergency": {
            "name":  fake.name(),
            "phone": fake.phone_number()[:20],
            "relation": random.choice(["Parent", "Sibling", "Spouse", "Friend"]),
        },
        "address": {
            "city":  fake.city(),
            "state": fake.state_abbr(),
            "zip":   fake.zipcode(),
        },
    }

    student_rows.append((
        random.choice(dept_ids_l2),
        number, first, last, email, dob,
        random.choices(GENDERS, GENDER_W)[0],
        enroll,
        exp_grad_year if exp_grad_year <= 2030 else 2030,
        "active",
        None,                           # gpa — computed later
        json.dumps(contacts),
    ))

batch_insert(
    "students",
    ["department_id","student_number","first_name","last_name","email",
     "date_of_birth","gender","enrollment_date","expected_grad",
     "status","gpa","contacts"],
    student_rows,
)

cur.execute("SELECT student_id, department_id, enrollment_date FROM students")
students_db = cur.fetchall()   # [(student_id, department_id, enrollment_date), …]
student_ids = [s[0] for s in students_db]


# ---------------------------------------------------------------------------
#  courses  (~200 rows, with synthetic VECTOR(1536) embeddings)
# ---------------------------------------------------------------------------
print("\n[3/9] Generating courses …")

COURSE_TEMPLATES = [
    # (dept_code, prefix, titles)
    ("CS",   "CS",   ["Introduction to Programming","Data Structures & Algorithms","Operating Systems",
                       "Computer Networks","Database Systems","Machine Learning","Deep Learning",
                       "Computer Vision","Natural Language Processing","Cybersecurity Fundamentals",
                       "Distributed Systems","Software Engineering","Compiler Design",
                       "Parallel Computing","Cloud Computing","Web Development","Mobile Computing",
                       "Human-Computer Interaction","Computer Graphics","Theory of Computation"]),
    ("MATH", "MATH", ["Calculus I","Calculus II","Linear Algebra","Discrete Mathematics",
                       "Probability Theory","Mathematical Statistics","Numerical Methods",
                       "Abstract Algebra","Real Analysis","Complex Analysis",
                       "Differential Equations","Topology","Graph Theory","Number Theory",
                       "Mathematical Logic","Combinatorics","Optimization Theory"]),
    ("PHYS", "PHYS", ["Classical Mechanics","Electromagnetism","Quantum Mechanics",
                       "Thermodynamics","Optics","Astrophysics","Condensed Matter Physics",
                       "Nuclear Physics","Particle Physics","Computational Physics"]),
    ("CHEM", "CHEM", ["General Chemistry","Organic Chemistry","Biochemistry","Analytical Chemistry",
                       "Physical Chemistry","Inorganic Chemistry","Polymer Chemistry"]),
    ("BIO",  "BIO",  ["Cell Biology","Genetics","Ecology","Evolutionary Biology",
                       "Molecular Biology","Microbiology","Neuroscience","Bioinformatics",
                       "Developmental Biology","Immunology"]),
    ("ENGL", "ENGL", ["Academic Writing","World Literature","Modern Poetry",
                       "Creative Writing","Literary Theory","Technical Writing"]),
    ("HIST", "HIST", ["World History","American History","European History",
                       "History of Science","Contemporary History"]),
    ("ECON", "ECON", ["Microeconomics","Macroeconomics","Econometrics",
                       "Game Theory","International Economics","Behavioral Economics"]),
    ("FINC", "FINC", ["Corporate Finance","Investment Analysis","Financial Modeling",
                       "Risk Management","Portfolio Theory"]),
    ("MKTG", "MKTG", ["Marketing Principles","Consumer Behavior","Digital Marketing",
                       "Brand Management","Market Research"]),
    ("PSY",  "PSY",  ["Introduction to Psychology","Cognitive Psychology","Social Psychology",
                       "Developmental Psychology","Abnormal Psychology","Research Methods in Psychology"]),
    ("SOC",  "SOC",  ["Introduction to Sociology","Social Theory","Research Methods",
                       "Urban Sociology","Cultural Anthropology"]),
    ("MED",  "MED",  ["Human Anatomy","Medical Ethics","Pathology","Pharmacology","Epidemiology"]),
    ("NURS", "NURS", ["Fundamentals of Nursing","Patient Care","Clinical Practice","Healthcare Management"]),
    ("MATH-STAT", "STAT", ["Applied Statistics","Regression Analysis","Bayesian Statistics",
                            "Time Series Analysis","Data Visualization"]),
]

# Build department code → id map
cur.execute("SELECT department_id, code FROM departments")
dept_code_to_id = {row[1]: row[0] for row in cur.fetchall()}

LEVELS = ["undergraduate", "undergraduate", "undergraduate", "graduate", "doctoral"]

course_rows = []
course_meta = []  # (course_id placeholder index, dept_id)
code_counter: dict[str, int] = {}

for dept_code, prefix, titles in COURSE_TEMPLATES:
    dept_id = dept_code_to_id.get(dept_code)
    if dept_id is None:
        continue
    for i, title in enumerate(titles):
        code_num = code_counter.get(prefix, 100) + (i * 100 if i == 0 else 1)
        code_counter[prefix] = code_num + 1
        code = f"{prefix}{100 + i}"
        level = random.choices(LEVELS)[0]
        credits = 3 if level == "undergraduate" else 4 if level == "graduate" else 5
        description = fake.paragraph(nb_sentences=random.randint(3, 6))
        embedding = synthetic_unit_vector(1536)

        course_rows.append((dept_id, code, title, credits, level, description, True, embedding))

# Deduplicate codes just in case
seen_codes: set[str] = set()
unique_course_rows = []
for row in course_rows:
    code = row[1]
    suffix = 0
    original = code
    while code in seen_codes:
        suffix += 1
        code = f"{original}_{suffix}"
    seen_codes.add(code)
    unique_course_rows.append((row[0], code) + row[2:])

batch_insert(
    "courses",
    ["department_id","code","title","credits","level","description","is_active","embedding"],
    unique_course_rows,
)

cur.execute("SELECT course_id, department_id, level FROM courses")
courses_db = cur.fetchall()   # [(course_id, dept_id, level), …]
course_ids  = [c[0] for c in courses_db]
ug_courses  = [c[0] for c in courses_db if c[2] == "undergraduate"]


# ---------------------------------------------------------------------------
#  course_prerequisites  (each course has 0–3 prerequisites from its dept)
# ---------------------------------------------------------------------------
print("\n[4/9] Generating course prerequisites …")
prereq_rows: list[tuple] = []
seen_prereqs: set[tuple] = set()

for course_id, dept_id, level in courses_db:
    if level == "undergraduate" and random.random() < 0.4:
        # up to 2 UG prerequisites from the same department
        candidates = [c[0] for c in courses_db
                      if c[1] == dept_id and c[0] != course_id and c[2] == "undergraduate"]
        for prereq_id in random.sample(candidates, min(random.randint(1, 2), len(candidates))):
            key = (course_id, prereq_id)
            if key not in seen_prereqs and (prereq_id, course_id) not in seen_prereqs:
                seen_prereqs.add(key)
                prereq_rows.append((course_id, prereq_id, True))
    elif level == "graduate" and random.random() < 0.7:
        # graduate courses require 1–2 undergraduate prerequisites
        candidates = [c[0] for c in courses_db
                      if c[1] == dept_id and c[0] != course_id and c[2] == "undergraduate"]
        for prereq_id in random.sample(candidates, min(2, len(candidates))):
            key = (course_id, prereq_id)
            if key not in seen_prereqs:
                seen_prereqs.add(key)
                prereq_rows.append((course_id, prereq_id, True))

batch_insert("course_prerequisites", ["course_id","prerequisite_id","is_mandatory"], prereq_rows)


# ---------------------------------------------------------------------------
#  sections  (~800 rows — each semester gets a subset of courses)
# ---------------------------------------------------------------------------
print("\n[5/9] Generating sections …")
DELIVERY_OPTIONS = ["in-person", "in-person", "in-person", "online", "hybrid"]
SCHEDULE_TEMPLATES = [
    [{"day": "Mon", "start": "09:00", "end": "10:30"},{"day": "Wed", "start": "09:00", "end": "10:30"}],
    [{"day": "Tue", "start": "11:00", "end": "12:30"},{"day": "Thu", "start": "11:00", "end": "12:30"}],
    [{"day": "Mon", "start": "14:00", "end": "15:30"},{"day": "Wed", "start": "14:00", "end": "15:30"}],
    [{"day": "Tue", "start": "09:00", "end": "10:30"},{"day": "Thu", "start": "09:00", "end": "10:30"}],
    [{"day": "Fri",  "start": "10:00", "end": "13:00"}],
    [{"day": "Mon", "start": "17:00", "end": "20:00"}],
]

online_room_id = next(r[0] for r in rooms if r[2] == "online" if True else None
                      for r in rooms if r[2] == "online")

section_rows: list[tuple] = []
section_meta: list[dict] = []  # for later enrollment generation

for sem_id, sem_start, sem_end in semesters:
    n_courses = random.randint(35, 55)
    chosen_courses = random.sample(course_ids, min(n_courses, len(course_ids)))
    for course_id in chosen_courses:
        n_sections = random.randint(1, 3)
        for sec_num in range(1, n_sections + 1):
            delivery = random.choice(DELIVERY_OPTIONS)
            if delivery == "online":
                room_id = online_room_id
                capacity = random.randint(40, 80)
            else:
                room_id, cap = random.choice(rooms_physical)
                capacity = min(cap, random.randint(20, 50))

            faculty_id = random.choice(faculty_ids)
            schedule = random.choice(SCHEDULE_TEMPLATES)

            # Completed sections in past semesters, open/closed in recent ones
            if sem_end < date(2026, 1, 1):
                status = "completed"
            elif sem_end < date.today():
                status = random.choices(["completed", "closed"], [0.8, 0.2])[0]
            else:
                status = random.choices(["open", "closed"], [0.7, 0.3])[0]

            section_rows.append((
                course_id, sem_id, faculty_id, room_id, sec_num,
                delivery, capacity, status,
                json.dumps(schedule),
            ))
            section_meta.append({
                "course_id": course_id, "sem_id": sem_id,
                "capacity": capacity, "status": status,
                "sem_start": sem_start, "sem_end": sem_end,
            })

batch_insert(
    "sections",
    ["course_id","semester_id","faculty_id","room_id","section_number",
     "delivery","max_capacity","status","schedule"],
    section_rows,
)

cur.execute("SELECT section_id, course_id, semester_id, max_capacity, status FROM sections")
sections_db = cur.fetchall()

# Map semester → sections
sem_to_sections: dict[int, list] = {}
for s in sections_db:
    sem_id = s[2]
    sem_to_sections.setdefault(sem_id, []).append(s)

# Map section → semester start date
cur.execute("SELECT s.section_id, sem.start_date, sem.end_date FROM sections s JOIN semesters sem ON sem.semester_id = s.semester_id")
section_dates = {r[0]: (r[1], r[2]) for r in cur.fetchall()}


# ---------------------------------------------------------------------------
#  enrollments  (~8 000 rows)
# ---------------------------------------------------------------------------
print("\n[6/9] Generating enrollments …")
enrollment_rows: list[tuple] = []
enrolled_pairs: set[tuple] = set()  # (student_id, section_id)

# Distribute students across semesters based on their enrollment_date
student_map = {s[0]: s[2] for s in students_db}  # student_id → enrollment_date

for student_id, dept_id, enroll_date in students_db:
    # Pick 3–6 semesters the student could be enrolled in
    eligible_sems = [(sem_id, s, e) for sem_id, s, e in semesters if s >= enroll_date]
    if not eligible_sems:
        continue
    n_sems = random.randint(2, min(6, len(eligible_sems)))
    chosen_sems = random.sample(eligible_sems, n_sems)

    for sem_id, sem_start, sem_end in chosen_sems:
        available = sem_to_sections.get(sem_id, [])
        if not available:
            continue
        # 2–5 courses per semester
        n_courses = random.randint(2, 5)
        for _ in range(n_courses):
            section = random.choice(available)
            sec_id, course_id, _, capacity, sec_status = section
            if (student_id, sec_id) in enrolled_pairs:
                continue
            enrolled_pairs.add((student_id, sec_id))

            enrolled_at = rand_date(sem_start - timedelta(days=14), sem_start + timedelta(days=7))

            if sec_status == "completed":
                score = normal_score(75, 12)
                grade = (
                    "A"  if score >= 93 else "A-" if score >= 90 else
                    "B+" if score >= 87 else "B"  if score >= 83 else "B-" if score >= 80 else
                    "C+" if score >= 77 else "C"  if score >= 73 else "C-" if score >= 70 else
                    "D"  if score >= 60 else "F"
                )
                status = "completed" if score >= 60 else "failed"
                enrollment_rows.append((student_id, sec_id, enrolled_at, status,
                                        grade, round(score, 2)))
            elif sec_status == "cancelled":
                enrollment_rows.append((student_id, sec_id, enrolled_at, "dropped", None, None))
            else:
                enrollment_rows.append((student_id, sec_id, enrolled_at, "enrolled", None, None))

batch_insert(
    "enrollments",
    ["student_id","section_id","enrolled_at","status","final_grade","final_score"],
    enrollment_rows,
)

cur.execute("SELECT enrollment_id, section_id, status, final_score FROM enrollments")
enrollments_db = cur.fetchall()
completed_enrollments = [(r[0], r[1]) for r in enrollments_db if r[2] in ("completed", "failed")]
active_enrollments    = [(r[0], r[1]) for r in enrollments_db if r[2] == "enrolled"]


# ---------------------------------------------------------------------------
#  grade_events  (~120 000 rows)  — BIG TABLE
# ---------------------------------------------------------------------------
print("\n[7/9] Generating grade_events (big table) …")

GRADE_ITEMS = [
    # (item_name, item_type, weight, recur_times)
    ("Assignment",   "assignment",   0.0500, 6),
    ("Quiz",         "quiz",         0.0250, 4),
    ("Lab Report",   "lab",          0.0500, 3),
    ("Midterm Exam", "midterm",      0.2000, 1),
    ("Final Exam",   "final",        0.3000, 1),
    ("Project",      "project",      0.1500, 1),
    ("Participation","participation", 0.0500, 1),
]

grade_event_rows: list[tuple] = []

def gen_grade_events_for_enrollment(enrollment_id: int, section_id: int, base_score: float):
    """Generate a realistic set of grade events for one enrollment."""
    sec_start, sec_end = section_dates.get(section_id, (date(2023, 1, 1), date(2023, 5, 1)))
    grader_id = random.choice(faculty_ids)
    for item_name, item_type, weight, n in GRADE_ITEMS:
        for k in range(1, n + 1):
            label = f"{item_name} {k}" if n > 1 else item_name
            score = float(np.clip(np.random.normal(base_score, 8), 0, 100))
            days_in = random.randint(7, max(8, (sec_end - sec_start).days - 7))
            graded = datetime.combine(sec_start + timedelta(days=days_in), datetime.min.time())
            grade_event_rows.append((
                enrollment_id, label, item_type,
                round(score, 2), 100.00, weight,
                graded, grader_id, None,
            ))

for enr_id, sec_id in completed_enrollments:
    # Pull final score from enrollments to keep grades consistent
    pass

cur.execute("SELECT enrollment_id, section_id, final_score FROM enrollments WHERE status IN ('completed','failed')")
for enr_id, sec_id, final_score in cur.fetchall():
    base = final_score if final_score is not None else normal_score()
    gen_grade_events_for_enrollment(enr_id, sec_id, base)

# Also add partial grade events for currently active enrollments (no final yet)
ACTIVE_ITEMS = [i for i in GRADE_ITEMS if i[1] not in ("final",)]
for enr_id, sec_id in active_enrollments[:500]:   # sample for performance
    sec_start, sec_end = section_dates.get(sec_id, (date(2026, 1, 1), date(2026, 5, 1)))
    grader_id = random.choice(faculty_ids)
    for item_name, item_type, weight, n in ACTIVE_ITEMS:
        for k in range(1, n + 1):
            label = f"{item_name} {k}" if n > 1 else item_name
            score = normal_score(72, 14)
            graded = datetime.combine(
                sec_start + timedelta(days=random.randint(7, 60)),
                datetime.min.time(),
            )
            grade_event_rows.append((
                enr_id, label, item_type,
                round(score, 2), 100.00, weight,
                graded, grader_id, None,
            ))

batch_insert(
    "grade_events",
    ["enrollment_id","item_name","item_type","score","max_score","weight",
     "graded_at","grader_id","feedback"],
    grade_event_rows,
)


# ---------------------------------------------------------------------------
#  research_projects  (~200 rows)
# ---------------------------------------------------------------------------
print("\n[8/9] Generating research projects & publications …")

FUNDING_SOURCES = ["NSF", "NIH", "DARPA", "DOE", "NASA", "Private Foundation",
                   "Industry Partner", "European Research Council", "Internal Grant"]
project_rows: list[tuple] = []

for _ in range(200):
    dept_id = random.choice(dept_ids_l2)
    lead_id = random.choice(faculty_ids)
    start   = rand_date(date(2018, 1, 1), date(2025, 6, 1))
    end_d   = None if random.random() < 0.3 else rand_date(start + timedelta(days=180), date(2028, 12, 31))
    status  = "active" if end_d is None or end_d > date.today() else "completed"

    n_grants = random.randint(0, 3)
    funding = [
        {
            "source": random.choice(FUNDING_SOURCES),
            "amount": round(random.uniform(20000, 800000), 2),
            "grant_id": fake.bothify("??-####-###").upper(),
            "year": random.randint(start.year, start.year + 2),
        }
        for _ in range(n_grants)
    ]

    project_rows.append((
        dept_id, lead_id,
        fake.catch_phrase() + " Research",
        fake.paragraph(nb_sentences=4),
        start, end_d, status,
        json.dumps(funding),
    ))

batch_insert(
    "research_projects",
    ["department_id","lead_faculty_id","title","abstract",
     "start_date","end_date","status","funding"],
    project_rows,
)

cur.execute("SELECT project_id, lead_faculty_id FROM research_projects")
projects_db = cur.fetchall()
project_ids = [p[0] for p in projects_db]

# project_members
ROLES = ["Principal Investigator","Co-Investigator","Research Assistant",
         "Graduate Student","Undergraduate Student"]
member_rows: list[tuple] = []
for project_id, lead_id in projects_db:
    # Lead faculty is always PI
    member_rows.append((project_id, lead_id, None, "Principal Investigator",
                        rand_date(date(2018,1,1), date(2023,1,1)), None))
    # 1–3 additional faculty
    for _ in range(random.randint(0, 2)):
        fid = random.choice(faculty_ids)
        member_rows.append((project_id, fid, None,
                            random.choice(["Co-Investigator","Research Assistant"]),
                            rand_date(date(2018,1,1), date(2023,1,1)), None))
    # 1–4 students
    for _ in range(random.randint(1, 4)):
        sid = random.choice(student_ids)
        member_rows.append((project_id, None, sid,
                            random.choice(["Graduate Student","Undergraduate Student"]),
                            rand_date(date(2020,1,1), date(2025,1,1)), None))

batch_insert(
    "project_members",
    ["project_id","faculty_id","student_id","role","joined_date","left_date"],
    member_rows,
)

# publications
KEYWORDS_POOL = ["AI","ML","Data Science","Networking","Security","Algorithms",
                 "Databases","HCI","Theory","Bioinformatics","Systems",
                 "Mathematics","Physics","Chemistry","Biology"]

pub_rows: list[tuple] = []
for _ in range(500):
    project_id = random.choice(project_ids) if random.random() < 0.65 else None
    kws = ",".join(random.sample(KEYWORDS_POOL, random.randint(1, 4)))
    pub_year = random.randint(2015, 2026)
    pub_rows.append((
        project_id,
        fake.catch_phrase() + ": " + fake.bs().title(),
        fake.paragraph(nb_sentences=8),
        pub_year,
        random.choice(["IEEE Transactions","Nature","Science","ACM SIGMOD",
                       "NeurIPS","ICLR","ICML","VLDB","USENIX","OSDI",
                       "Journal of Applied Mathematics","PLOS ONE", None]),
        fake.bothify("10.####/???.####.######") if random.random() < 0.7 else None,
        kws,
        random.randint(0, 500),
    ))

batch_insert(
    "publications",
    ["project_id","title","abstract","pub_year","venue","doi","keywords","citation_count"],
    pub_rows,
)


# ---------------------------------------------------------------------------
#  student_scholarships  (~500 awards)
# ---------------------------------------------------------------------------
print("\n[9/9] Generating student scholarships …")

award_rows: list[tuple] = []
awarded_pairs: set[tuple] = set()
sample_students = random.sample(student_ids, min(400, len(student_ids)))

for student_id in sample_students:
    n = random.randint(1, 3)
    for _ in range(n):
        sc_id = random.choice(scholarship_ids)
        if (student_id, sc_id) in awarded_pairs:
            continue
        awarded_pairs.add((student_id, sc_id))
        awarded = rand_date(date(2020, 9, 1), date(2025, 9, 1))
        expires = None if random.random() < 0.3 else (awarded + timedelta(days=365))
        award_rows.append((
            student_id, sc_id, awarded, expires,
            round(random.uniform(500, 8000), 2),
            None,
        ))

batch_insert(
    "student_scholarships",
    ["student_id","scholarship_id","awarded_date","expires_date","amount_awarded","notes"],
    award_rows,
)


# ---------------------------------------------------------------------------
#  Recalculate GPA for completed students
# ---------------------------------------------------------------------------
print("\n[+] Recalculating student GPAs …")
cur.execute("""
    UPDATE students s
    JOIN (
        SELECT
            e.student_id,
            ROUND(SUM(
                CASE e.final_grade
                    WHEN 'A'  THEN 4.0 WHEN 'A-' THEN 3.7
                    WHEN 'B+' THEN 3.3 WHEN 'B'  THEN 3.0 WHEN 'B-' THEN 2.7
                    WHEN 'C+' THEN 2.3 WHEN 'C'  THEN 2.0 WHEN 'C-' THEN 1.7
                    WHEN 'D'  THEN 1.0 ELSE 0.0
                END * c.credits
            ) / NULLIF(SUM(c.credits), 0), 3) AS gpa
        FROM       enrollments e
        JOIN       sections    sec ON sec.section_id = e.section_id
        JOIN       courses     c   ON c.course_id    = sec.course_id
        WHERE      e.status = 'completed'
        GROUP BY   e.student_id
    ) g ON g.student_id = s.student_id
    SET s.gpa = g.gpa
""")
conn.commit()
print("  ✓  students.gpa updated")

# ---------------------------------------------------------------------------
#  Summary
# ---------------------------------------------------------------------------
print("\n" + "=" * 50)
print("  Data generation complete!")
print("=" * 50)
for table in ["semesters","rooms","scholarships","departments","faculty","students",
              "courses","course_prerequisites","sections","enrollments",
              "grade_events","research_projects","publications",
              "project_members","student_scholarships","audit_log"]:
    cur.execute(f"SELECT COUNT(*) FROM {table}")
    count = cur.fetchone()[0]
    print(f"  {table:<28} {count:>8,} rows")

cur.close()
conn.close()
