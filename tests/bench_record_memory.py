#!/usr/bin/env python3
"""Сколько ПАМЯТИ клиента реально экономит смена числа слотов записи.

Зачем: в Lua 5.1 array-часть таблицы выделяется под ближайшую степень двойки
(luaH_resize перебирает 1, 2, 4, 8, 16, 32…). Значит удаление одного-двух
слотов из 21 может не дать НИЧЕГО: и 21, и 23 лежат в блоке на 32 ячейки.
Обещать «−X МБ памяти» без замера нельзя — проверяем collectgarbage("count")
на реальном числе записей.

⚠️ Каждый замер — в СВЕЖЕМ LuaRuntime: при переиспользовании предыдущие таблицы
живут в том же heap, и разница before/after выходит нулевой или отрицательной.

Запуск: python3 tests/bench_record_memory.py
"""
from lupa.lua51 import LuaRuntime

N = 53570  # записей в живом SV на 24.11.2026


def measure(n_slots: int, repeats: int = 3) -> float:
    """Медиана прироста heap в МБ при создании N таблиц по n_slots слотов."""
    import statistics
    runs = []
    for _ in range(repeats):
        lua = LuaRuntime()
        lua.execute(f"""
        collectgarbage("collect")
        collectgarbage("collect")
        local before = collectgarbage("count")
        local recs = {{}}
        for i = 1, {N} do
            local r = {{}}
            for s = 1, {n_slots} do r[s] = "x" end
            recs[i] = r
        end
        collectgarbage("collect")
        local after = collectgarbage("count")
        RESULT = after - before
        """)
        runs.append(float(lua.globals()["RESULT"]) / 1024)
    return statistics.median(runs)


print(f"записей: {N}, медиана из 3 замеров collectgarbage('count')\n")
print(f"{'слотов':>7} {'память':>10} {'байт/запись':>12}   блок")
print("─" * 56)

res = {}
for slots in (14, 15, 16, 17, 21, 23, 24, 32, 33):
    mb = measure(slots)
    res[slots] = mb
    block = 16 if slots <= 16 else (32 if slots <= 32 else 64)
    print(f"{slots:>7} {mb:>9.2f} МБ {mb * 1024 * 1024 / N:>11.1f}   {block} ячеек")

print()
print(f"v2 (23 слота) = {res[23]:.2f} МБ, v3 (21 слот) = {res[21]:.2f} МБ → разница {res[21] - res[23]:+.2f} МБ")
print(f"16 слотов = {res[16]:.2f} МБ (блок 16 ячеек) → от 21 слота разница {res[16] - res[21]:+.2f} МБ")
