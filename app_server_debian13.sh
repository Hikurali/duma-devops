
#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Ошибка установки, строка $LINENO" >&2' ERR

if [[ "$EUID" -ne 0 ]]; then
    echo "Запусти через sudo bash app.sh"
    exit 1
fi

. /etc/os-release
if [[ "$ID" != "debian" || "$VERSION_ID" != "13" ]]; then
    echo "Требуется Debian 13"
    exit 1
fi

DB_HOST="192.168.56.20"
DB_PORT="5432"
DB_NAME="gorod_duma"
DB_USER="duma_app"

read -rsp "Пароль PostgreSQL duma_app: " DB_PASS
echo
read -rsp "Новый пароль администратора сайта: " ADMIN_PASS
echo

if [[ ${#ADMIN_PASS} -lt 10 ]]; then
    echo "Пароль администратора должен содержать минимум 10 символов"
    exit 1
fi

echo "[1/6] Установка пакетов..."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    python3 python3-venv python3-pip \
    postgresql-client openssl ca-certificates curl

echo "[2/6] Проверка подключения к DB-SERVER..."

if ! PGPASSWORD="$DB_PASS" psql \
    -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 -Atqc "SELECT 1" | grep -qx 1; then
    echo "Не удалось подключиться к PostgreSQL"
    exit 1
fi

echo "[3/6] Создание приложения..."

id dumaapp &>/dev/null || \
    useradd --system --shell /usr/sbin/nologin dumaapp

mkdir -p /opt/gorod-duma

cat > /opt/gorod-duma/main.py <<'PYTHON_APP'
import os
import hmac
import hashlib
import logging
from datetime import date
from contextlib import asynccontextmanager

import psycopg
from psycopg.rows import dict_row
from fastapi import FastAPI, Depends, HTTPException
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("gorod-duma")
security = HTTPBasic()


def connect():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=5432,
        dbname="gorod_duma",
        user="duma_app",
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
        row_factory=dict_row
    )


def init_db():
    queries = [
        """CREATE TABLE IF NOT EXISTS deputies (
            id SERIAL PRIMARY KEY,
            name TEXT NOT NULL,
            district TEXT NOT NULL DEFAULT ''
        )""",
        """CREATE TABLE IF NOT EXISTS commissions (
            id SERIAL PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            chair_id INTEGER REFERENCES deputies(id)
                ON DELETE SET NULL
        )""",
        """CREATE TABLE IF NOT EXISTS memberships (
            commission_id INTEGER REFERENCES commissions(id)
                ON DELETE CASCADE,
            deputy_id INTEGER REFERENCES deputies(id)
                ON DELETE CASCADE,
            PRIMARY KEY (commission_id, deputy_id)
        )""",
        """CREATE TABLE IF NOT EXISTS meetings (
            id SERIAL PRIMARY KEY,
            commission_id INTEGER NOT NULL
                REFERENCES commissions(id) ON DELETE CASCADE,
            held_on DATE NOT NULL,
            topic TEXT NOT NULL
        )""",
        """CREATE TABLE IF NOT EXISTS attendance (
            meeting_id INTEGER REFERENCES meetings(id)
                ON DELETE CASCADE,
            deputy_id INTEGER REFERENCES deputies(id)
                ON DELETE CASCADE,
            present BOOLEAN NOT NULL,
            PRIMARY KEY (meeting_id, deputy_id)
        )"""
    ]
    with connect() as conn:
        for query in queries:
            conn.execute(query)


@asynccontextmanager
async def lifespan(app):
    init_db()
    log.info("Database initialized")
    yield


app = FastAPI(
    title="Городская Дума",
    version="0.1.0",
    lifespan=lifespan
)


def authorize(c: HTTPBasicCredentials = Depends(security)):
    expected = os.environ["ADMIN_HASH"]
    salt = bytes.fromhex(os.environ["ADMIN_SALT"])
    actual = hashlib.pbkdf2_hmac(
        "sha256", c.password.encode(), salt, 260000
    ).hex()

    if not (
        hmac.compare_digest(c.username, "admin")
        and hmac.compare_digest(actual, expected)
    ):
        raise HTTPException(
            401,
            "Неверный логин или пароль",
            headers={"WWW-Authenticate": "Basic"}
        )
    return c.username


def query(sql, params=(), mode="all"):
    try:
        with connect() as conn:
            result = conn.execute(sql, params)
            if mode == "one":
                return result.fetchone()
            if mode == "all":
                return result.fetchall()
    except (
        psycopg.errors.UniqueViolation,
        psycopg.errors.ForeignKeyViolation
    ):
        log.warning("Database integrity violation")
        raise HTTPException(409, "Нарушена связь или уникальность данных")


def require(sql, params=()):
    if not query(sql, params, "one"):
        raise HTTPException(404, "Запись не найдена")


class Deputy(BaseModel):
    name: str = Field(min_length=2)
    district: str = ""


class Commission(BaseModel):
    name: str = Field(min_length=2)


class Member(BaseModel):
    deputy_id: int = Field(gt=0)


class Meeting(BaseModel):
    commission_id: int = Field(gt=0)
    held_on: date
    topic: str = Field(min_length=2)


class Attendance(BaseModel):
    deputy_id: int = Field(gt=0)
    present: bool


@app.get("/healthz")
def health():
    try:
        with connect() as conn:
            conn.execute("SELECT 1")
        return {"status": "ok", "database": "ok"}
    except Exception:
        log.exception("Healthcheck failed")
        raise HTTPException(503, "Database unavailable")


@app.get("/api/deputies", dependencies=[Depends(authorize)])
def list_deputies():
    return query("SELECT * FROM deputies ORDER BY id")


@app.post("/api/deputies", dependencies=[Depends(authorize)])
def create_deputy(d: Deputy):
    return query(
        "INSERT INTO deputies(name,district) VALUES(%s,%s) RETURNING *",
        (d.name, d.district),
        "one"
    )


@app.put("/api/deputies/{id}", dependencies=[Depends(authorize)])
def update_deputy(id: int, d: Deputy):
    require("SELECT id FROM deputies WHERE id=%s", (id,))
    return query(
        "UPDATE deputies SET name=%s,district=%s WHERE id=%s RETURNING *",
        (d.name, d.district, id),
        "one"
    )


@app.delete("/api/deputies/{id}", dependencies=[Depends(authorize)])
def delete_deputy(id: int):
    require("SELECT id FROM deputies WHERE id=%s", (id,))
    query("DELETE FROM deputies WHERE id=%s", (id,), None)
    return {"deleted": id}


@app.get("/api/commissions", dependencies=[Depends(authorize)])
def list_commissions():
    return query("SELECT * FROM commissions ORDER BY id")


@app.post("/api/commissions", dependencies=[Depends(authorize)])
def create_commission(c: Commission):
    return query(
        "INSERT INTO commissions(name) VALUES(%s) RETURNING *",
        (c.name,),
        "one"
    )


@app.put("/api/commissions/{id}", dependencies=[Depends(authorize)])
def update_commission(id: int, c: Commission):
    require("SELECT id FROM commissions WHERE id=%s", (id,))
    return query(
        "UPDATE commissions SET name=%s WHERE id=%s RETURNING *",
        (c.name, id),
        "one"
    )


@app.delete("/api/commissions/{id}", dependencies=[Depends(authorize)])
def delete_commission(id: int):
    require("SELECT id FROM commissions WHERE id=%s", (id,))
    query("DELETE FROM commissions WHERE id=%s", (id,), None)
    return {"deleted": id}


@app.post("/api/commissions/{id}/members",
          dependencies=[Depends(authorize)])
def add_member(id: int, m: Member):
    require("SELECT id FROM commissions WHERE id=%s", (id,))
    require("SELECT id FROM deputies WHERE id=%s", (m.deputy_id,))
    query(
        "INSERT INTO memberships VALUES(%s,%s) ON CONFLICT DO NOTHING",
        (id, m.deputy_id),
        None
    )
    return {"commission_id": id, "deputy_id": m.deputy_id}


@app.patch("/api/commissions/{id}/chair",
           dependencies=[Depends(authorize)])
def set_chair(id: int, m: Member):
    require(
        "SELECT 1 FROM memberships "
        "WHERE commission_id=%s AND deputy_id=%s",
        (id, m.deputy_id)
    )
    return query(
        "UPDATE commissions SET chair_id=%s WHERE id=%s RETURNING *",
        (m.deputy_id, id),
        "one"
    )


@app.get("/api/meetings", dependencies=[Depends(authorize)])
def list_meetings():
    return query("SELECT * FROM meetings ORDER BY held_on DESC, id DESC")


@app.post("/api/meetings", dependencies=[Depends(authorize)])
def create_meeting(m: Meeting):
    require(
        "SELECT id FROM commissions WHERE id=%s",
        (m.commission_id,)
    )
    return query(
        "INSERT INTO meetings(commission_id,held_on,topic) "
        "VALUES(%s,%s,%s) RETURNING *",
        (m.commission_id, m.held_on, m.topic),
        "one"
    )


@app.delete("/api/meetings/{id}", dependencies=[Depends(authorize)])
def delete_meeting(id: int):
    require("SELECT id FROM meetings WHERE id=%s", (id,))
    query("DELETE FROM meetings WHERE id=%s", (id,), None)
    return {"deleted": id}


@app.post("/api/meetings/{id}/attendance",
          dependencies=[Depends(authorize)])
def mark_attendance(id: int, a: Attendance):
    require(
        "SELECT 1 FROM meetings t "
        "JOIN memberships m ON m.commission_id=t.commission_id "
        "WHERE t.id=%s AND m.deputy_id=%s",
        (id, a.deputy_id)
    )
    query(
        "INSERT INTO attendance VALUES(%s,%s,%s) "
        "ON CONFLICT(meeting_id,deputy_id) "
        "DO UPDATE SET present=EXCLUDED.present",
        (id, a.deputy_id, a.present),
        None
    )
    return {"meeting_id": id, "deputy_id": a.deputy_id}


@app.get("/api/report", dependencies=[Depends(authorize)])
def report(start: date, end: date):
    if start > end:
        raise HTTPException(422, "Некорректный период")

    return query(
        """SELECT d.id,d.name,
        COUNT(t.id) AS recorded,
        COUNT(t.id) FILTER(WHERE a.present) AS attended
        FROM deputies d
        LEFT JOIN attendance a ON a.deputy_id=d.id
        LEFT JOIN meetings t ON t.id=a.meeting_id
            AND t.held_on BETWEEN %s AND %s
        GROUP BY d.id,d.name ORDER BY d.id""",
        (start, end)
    )


HTML = """
<!doctype html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<title>Городская Дума</title>
<style>
body {
    font-family: Arial;
    max-width: 1000px;
    margin: 30px auto;
    background: #f3f6fa;
}
section {
    background: white;
    padding: 20px;
    margin: 15px 0;
    border-radius: 10px;
}
input, button, select {
    padding: 9px;
    margin: 5px;
}
button {
    background: #245edb;
    color: white;
    border: 0;
    cursor: pointer;
}
pre {
    background: #edf1f7;
    padding: 10px;
    overflow: auto;
}
</style>
</head>
<body>
<h1>Городская Дума</h1>
<p>Система управления депутатами, комиссиями и заседаниями</p>
<p><a href="/docs">Документация HTTP API</a></p>

<section>
<h2>Авторизация</h2>
<input id="username" value="admin" placeholder="Логин">
<input id="password" type="password" placeholder="Пароль">
<button onclick="load()">Войти</button>
<p id="message"></p>
</section>

<section>
<h2>Депутаты</h2>
<input id="deputy_name" placeholder="ФИО">
<input id="district" placeholder="Округ">
<button onclick="addDeputy()">Добавить депутата</button>
<pre id="deputies"></pre>
</section>

<section>
<h2>Комиссии</h2>
<input id="commission_name" placeholder="Название">
<button onclick="addCommission()">Добавить комиссию</button>
<pre id="commissions"></pre>
</section>

<section>
<h2>Состав комиссии</h2>
<input id="commission_id" type="number" placeholder="ID комиссии">
<input id="member_id" type="number" placeholder="ID депутата">
<button onclick="addMember()">Включить депутата</button>
<button onclick="setChair()">Назначить председателем</button>
</section>

<section>
<h2>Заседания</h2>
<input id="meeting_commission" type="number" placeholder="ID комиссии">
<input id="meeting_date" type="date">
<input id="meeting_topic" placeholder="Тема">
<button onclick="addMeeting()">Создать заседание</button>
<pre id="meetings"></pre>
</section>

<section>
<h2>Посещаемость</h2>
<input id="meeting_id" type="number" placeholder="ID заседания">
<input id="attendee_id" type="number" placeholder="ID депутата">
<select id="present">
<option value="true">Присутствовал</option>
<option value="false">Отсутствовал</option>
</select>
<button onclick="markAttendance()">Сохранить</button>
</section>

<section>
<h2>Отчёт по посещаемости</h2>
<input id="start" type="date">
<input id="end" type="date">
<button onclick="getReport()">Сформировать</button>
<pre id="report"></pre>
</section>

<script>
let credentials = "";

function value(id) {
    return document.getElementById(id).value;
}

function output(id, data) {
    document.getElementById(id).textContent =
        JSON.stringify(data, null, 2);
}

async function api(path, method = "GET", body = null) {
    const response = await fetch(path, {
        method: method,
        headers: {
            "Authorization": "Basic " + credentials,
            "Content-Type": "application/json"
        },
        body: body ? JSON.stringify(body) : null
    });

    const data = await response.json();
    if (!response.ok) {
        throw Error(JSON.stringify(data));
    }
    return data;
}

async function load() {
    credentials = btoa(unescape(encodeURIComponent(
        value("username") + ":" + value("password")
    )));
    try {
        output("deputies", await api("/api/deputies"));
        output("commissions", await api("/api/commissions"));
        output("meetings", await api("/api/meetings"));
        document.getElementById("message").textContent =
            "Подключение работает";
    } catch (e) {
        alert(e.message);
    }
}

async function send(path, body, method = "POST") {
    try {
        await api(path, method, body);
        await load();
    } catch (e) {
        alert(e.message);
    }
}

function addDeputy() {
    send("/api/deputies", {
        name: value("deputy_name"),
        district: value("district")
    });
}

function addCommission() {
    send("/api/commissions", {
        name: value("commission_name")
    });
}

function addMember() {
    send("/api/commissions/" + value("commission_id") + "/members", {
        deputy_id: Number(value("member_id"))
    });
}

function setChair() {
    send("/api/commissions/" + value("commission_id") + "/chair", {
        deputy_id: Number(value("member_id"))
    }, "PATCH");
}

function addMeeting() {
    send("/api/meetings", {
        commission_id: Number(value("meeting_commission")),
        held_on: value("meeting_date"),
        topic: value("meeting_topic")
    });
}

function markAttendance() {
    send("/api/meetings/" + value("meeting_id") + "/attendance", {
        deputy_id: Number(value("attendee_id")),
        present: value("present") === "true"
    });
}

async function getReport() {
    try {
        output("report", await api(
            "/api/report?start=" + value("start") +
            "&end=" + value("end")
        ));
    } catch (e) {
        alert(e.message);
    }
}
</script>
</body>
</html>
"""

@app.get("/", response_class=HTMLResponse)
def index():
    return HTML
PYTHON_APP

echo "[4/6] Установка Python-зависимостей..."

python3 -m py_compile /opt/gorod-duma/main.py
python3 -m venv /opt/gorod-duma/venv

/opt/gorod-duma/venv/bin/pip install \
    'fastapi>=0.115,<1' \
    'uvicorn>=0.30,<1' \
    'psycopg[binary]>=3.2,<4'

echo "[5/6] Настройка авторизации..."

SALT=$(openssl rand -hex 16)

HASH=$(printf "%s" "$ADMIN_PASS" | python3 -c '
import hashlib, sys
salt = bytes.fromhex(sys.argv[1])
password = sys.stdin.buffer.read()
print(hashlib.pbkdf2_hmac(
    "sha256", password, salt, 260000
).hex())
' "$SALT")

umask 027

cat > /etc/gorod-duma.env <<EOF
DB_HOST=$DB_HOST
DB_PASSWORD=$DB_PASS
ADMIN_SALT=$SALT
ADMIN_HASH=$HASH
EOF

chown root:dumaapp /etc/gorod-duma.env
chmod 640 /etc/gorod-duma.env

chown -R root:root /opt/gorod-duma
chmod 755 /opt/gorod-duma

echo "[6/6] Настройка systemd..."

cat > /etc/systemd/system/gorod-duma.service <<'SYSTEMD_UNIT'
[Unit]
Description=Gorod Duma FastAPI Application
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=dumaapp
Group=dumaapp
WorkingDirectory=/opt/gorod-duma
EnvironmentFile=/etc/gorod-duma.env
ExecStart=/opt/gorod-duma/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SYSTEMD_UNIT

unset DB_PASS ADMIN_PASS

systemctl daemon-reload
systemctl enable gorod-duma
systemctl restart gorod-duma

sleep 3

echo "Проверка службы..."
systemctl --no-pager status gorod-duma || true

echo "Проверка API..."
curl -fsS http://127.0.0.1:8000/healthz

echo
echo "======================================"
echo "Установка завершена"
echo "Приложение: http://192.168.56.10:8000"
echo "API Docs:    http://192.168.56.10:8000/docs"
echo "Логин:       admin"
echo "======================================"
# END_OF_GOROD_DUMA_APP_SCRIPT
