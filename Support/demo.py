"""Выдуманный календарь для скриншотов README: лето 2035 года, день того, кто делает людям удобно.

`python3 Support/demo.py <папка> [sounds]` кладёт в папку config.json и state.json так, как они лежат в домашней
папке. Без `sounds` звуки и автооткрытие выключены: снимок напоминания не должен звенеть и открывать встречу.
Настоящих данных не читает. Запускается из `make screens`.
"""

import json
import random
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

ME = "happy@example.com"
LINK = "https://my.mts-link.ru/j/1"

VERA = "Улыбкина Вера Сергеевна"
ILYA = "Добров Илья Андреевич"
ANNA = "Радостева Анна Игоревна"
GLEB = "Удобнов Глеб Петрович"
MARIA = "Заботина Мария Олеговна"
ARTEM = "Светлов Артём Денисович"
TIMUR = "Весёлкин Тимур Русланович"
POLINA = "Ласкова Полина Юрьевна"
PEOPLE = [ANNA, GLEB, MARIA, ARTEM, TIMUR, POLINA]

TODAY = "2035-07-17"
EVERYDAY = [
    "Как сделать ещё проще", "Разбор писем благодарности", "Кнопка, которую приятно нажимать", "Один экран вместо пяти",
    "Почему пользователь улыбнулся", "Убираем лишний клик", "Тексты, которые понимают с первого раза",
    "Праздник закрытых обращений", "Кофе с поддержкой",
]
IMPORTANT = ["Стратегия счастья на квартал", "Индекс улыбок: итоги", "Совет директоров: где ещё порадовать людей"]


def at(day: str, time: str) -> str:
    local = datetime.fromisoformat(f"{day}T{time}").astimezone()
    return local.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def event(number: int, day: str, start: str, end: str, subject: str, organizer: str = "", response: str = "Accept",
          series: bool = False, link: bool = True, people=(), description: str = "", all_day: bool = False, free: bool = False):
    name = organizer or "Счастливый Пользователь"
    address = f"{name.split()[0].lower()}@example.com" if organizer else ME
    finish = (datetime.fromisoformat(day) + timedelta(days=1)).strftime("%Y-%m-%d") if all_day else day
    return {
        "id": f"demo-{number}", "changeKey": "1", "uid": f"series-{subject}" if series else None, "subject": subject,
        "start": at(day, start), "end": at(finish, end), "isAllDay": all_day, "organizerName": name, "organizerAddress": address,
        "attendees": [{"name": p, "address": f"{p.split()[0].lower()}@example.com"} for p in people],
        "response": "Organizer" if not organizer else response, "isFree": free, "isCancelled": False,
        "joinURL": LINK if link else None, "description": description or None,
    }


def today() -> list:
    """Плотный день: все виды встреч, наложения и два перерыва — обед и окно после полудня."""
    rows = [
        ("00:00", "00:00", "День рождения продукта: нам девять лет!", {"organizer": ANNA, "all_day": True, "free": True, "link": False}),
        ("10:00", "10:30", "Утренний заряд улыбок", {"series": True, "people": [ANNA, GLEB, MARIA]}),
        ("10:30", "11:00", "Стендап: кого мы порадовали вчера", {"organizer": GLEB, "series": True, "people": PEOPLE[:4]}),
        ("11:00", "12:00", "Стратегия счастья", {"organizer": VERA, "people": [ILYA, ANNA, GLEB]}),
        ("11:30", "12:00", "Отзывы: «Спасибо!»", {"organizer": MARIA, "response": "Tentative", "people": [POLINA]}),
        ("12:00", "12:30", "Кнопка, которую приятно нажимать", {"organizer": ARTEM, "people": [TIMUR, POLINA]}),
        ("12:30", "13:00", "Один экран вместо пяти", {"people": [ARTEM, TIMUR]}),
        ("14:00", "14:45", "Бабушка разобралась с первого раза: интервью", {"people": [POLINA, MARIA], "description": "Записываем, чему она обрадовалась."}),
        ("14:45", "15:15", "Ретро радостей", {"organizer": ANNA, "series": True, "people": PEOPLE}),
        ("15:00", "16:00", "Где ещё проще?", {"organizer": ILYA, "people": [VERA, ANNA, GLEB, MARIA, ARTEM]}),
        ("16:30", "17:00", "Совещание о сокращении совещаний", {"organizer": TIMUR, "series": True, "people": PEOPLE}),
        ("17:00", "18:00", "Убираем лишний клик: финал", {"organizer": POLINA, "response": "NoResponseReceived", "people": [GLEB, ARTEM]}),
        ("18:00", "18:30", "Пятиминутка благодарности", {"organizer": MARIA, "series": True, "people": PEOPLE[:3]}),
        ("18:30", "19:00", "Кофе с поддержкой: кому мы помогли", {"link": False, "people": [POLINA]}),
    ]
    return [event(number, TODAY, start, end, subject, **options) for number, (start, end, subject, options) in enumerate(rows)]


def month() -> list:
    """Остальные рабочие дни вокруг июля: обычные встречи и случайные важные — точки в календаре."""
    random.seed(2035)
    events, number = [], 100
    day = datetime(2035, 6, 25)
    while day < datetime(2035, 8, 6):
        name = day.strftime("%Y-%m-%d")
        if day.weekday() < 5 and name != TODAY:
            for hour in range(10, 18):
                if random.random() < 0.55:
                    number += 1
                    events.append(event(number, name, f"{hour}:00", f"{hour}:30", random.choice(EVERYDAY), organizer=random.choice(PEOPLE)))
            for hour in random.sample(range(10, 18), random.choice([0, 1, 1, 2, 3])):
                number += 1
                events.append(event(number, name, f"{hour}:30", f"{hour + 1}:00", random.choice(IMPORTANT), organizer=random.choice([VERA, ILYA])))
        day += timedelta(days=1)
    return events


def main(home: Path, sounds: bool) -> None:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    config = {
        "mailboxes": [{"address": ME, "login": "SMILE\\happy", "server": "https://mail.example.com/EWS/Exchange.asmx", "password": "demo"}],
        "vipOrganizers": ["Улыбкина Вера", "Добров Илья"],
        "markedDays": ["2035-07-05", "2035-07-13", TODAY, "2035-07-26"],
        "hidden": {"series-Совещание ради совещания": {"subject": "Совещание ради совещания", "series": True}},
        "showHomeTime": True, "homeTimeZone": "Asia/Makassar",
        "playAtDesk": sounds, "playAway": sounds, "playInCall": sounds, "autoOpenMTSLink": sounds,
    }
    box = {"events": today() + month(), "window": [TODAY, "2035-07-24"], "windowAt": now, "success": now, "failures": 0}
    state = {"calendar": {ME: box}, "decisions": {"demo-10": {"kind": "skipped", "day": TODAY}}}

    (home / ".config/butler").mkdir(parents=True, exist_ok=True)
    (home / ".config/butler/config.json").write_text(json.dumps(config, ensure_ascii=False, indent=2))
    (home / "Library/Application Support/Butler").mkdir(parents=True, exist_ok=True)
    (home / "Library/Application Support/Butler/state.json").write_text(json.dumps(state, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main(Path(sys.argv[1]), sounds=sys.argv[2:] == ["sounds"])
