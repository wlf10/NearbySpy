#!/usr/bin/env python3
"""Замер разовой миграции v2 → v3 на реальном масштабе.

Зачем: миграция перекладывает ВСЕ записи при первом входе в игру, и делает это
в момент загрузки аддона. 55 тысяч записей × 21 поле — это заметная работа, и
если она занимает секунды, игрок увидит подвисание при входе. Замер на lupa
(Lua 5.1) даёт верхнюю оценку: в клиенте тот же интерпретатор.

Запуск: python3 tests/bench_migrate.py [N]
"""
import sys
import time
from pathlib import Path

from lupa.lua51 import LuaRuntime

from nsp_helpers import REC_PRELUDE

ROOT = Path(__file__).resolve().parents[1]
N = int(sys.argv[1]) if len(sys.argv) > 1 else 55768


def migration_source() -> str:
    src = (ROOT / "NearbySpy.lua").read_text(encoding="utf-8")
    start = src.index("function NspMigrateRecords(db)")
    end = src.index("-- shared record/upsert", start)
    return src[start:end]


lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(REC_PRELUDE)
lua.execute(migration_source())
lua.execute("function time() return 1000 end")

# v2-запись: 23 слота, как в живом файле
lua.execute(f"""
DB = {{ players = {{}}, recSchema = 2 }}
for i = 1, {N} do
    DB.players["P" .. i .. "-Realm"] = {{
        "P" .. i, "MAGE", "Маг", 30, "CAMWOW EU5 Realm 1 PvE", "Штормград", 1453,
        1795437970, 1795437970, 3, 0.5, 0.5, "unit", "Human", "Alliance",
        "Player-1-00000" .. i, false, false, false, false, false,
        "P" .. i .. "-Realm", false,
    }}
end
""")

migrate = lua.globals()["NspMigrateRecords"]

t0 = time.perf_counter()
conv, attached = migrate(lua.globals()["DB"])
dt = time.perf_counter() - t0

print(f"записей:    {N}")
print(f"переложено: {int(conv)}, метатаблиц: {int(attached)}")
print(f"время:      {dt * 1000:.0f} мс")

# контроль: поля на месте после миграции
check = lua.eval('''(function(d)
  local r = d.players["P1-Realm"]
  return tostring(r.level) .. "|" .. tostring(r.realm) .. "|" .. tostring(r.zoneId)
       .. "|" .. tostring(r.class) .. "|" .. tostring(#r)
end)''')
ok = check(lua.globals()["DB"])
print(f"контроль:   {ok}  (ждём 30|CAMWOW EU5 Realm 1 PvE|1453|MAGE|16)")

# второй прогон не должен ничего перекладывать
t0 = time.perf_counter()
conv2, _ = migrate(lua.globals()["DB"])
dt2 = time.perf_counter() - t0
print(f"повторный:  {int(conv2)} переложено, {dt2 * 1000:.0f} мс (ждём 0)")

if ok != "30|CAMWOW EU5 Realm 1 PvE|1453|MAGE|16":
    sys.exit(1)
if int(conv2) != 0:
    sys.exit(1)
