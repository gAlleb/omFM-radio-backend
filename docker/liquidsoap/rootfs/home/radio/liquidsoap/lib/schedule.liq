# Блочное расписание: станция описывает часы одной функцией, остальное здесь.
#
# Станция пишет только это:
#
#   %include "../lib/schedule.liq"
#
#   def category_at(d) =
#     if d.hour == 4 then "Organ" elsif d.hour >= 7 and d.hour < 22 then "Day"
#     else "Night" end
#   end
#
#   radio = schedule(category_at, [("Organ", organ), ("Day", day), ("Night", night)])
#
# Зачем функция, а не предикаты внутри switch. Предикат отвечает только про
# «сейчас», а чтобы назвать следующий трек, нужно знать категорию на момент
# окончания текущего. Одна функция обслуживает оба вопроса, и разъехаться им
# негде.
#
# Ветки получаются взаимоисключающими — истинна ровно одна. Это важно: ветка,
# чей источник не готов, у switch молча пропускается, и раньше управление
# проваливалось в следующую истинную, вплоть до заглушки { true }. Так среди
# дневного эфира на секунду мог оказаться ночной трек. Здесь провалиться
# некуда: если запланированная категория не готова, весь switch недоступен, и
# подхватывает то, что станция поставила ниже — обычно аварийный источник.
#
# d — запись даты из time.local(): d.hour, d.week_day (1 — понедельник).

def schedule(chooser, pairs) =
  def branch(pair) =
    let (name, src) = pair
    ({ chooser(time.local()) == name }, src)
  end

  switch(id="schedule", list.map(branch, pairs))
end

# Категория на момент, когда кончится текущий трек. Пустая строка — момент
# неизвестен: в эфире нет нормального трека, обещать нечего.
#
# Станция берёт по ней отложенного кандидата:
#   nm = reservation(schedule_next(category_at, src))
def schedule_next(chooser, src) =
  remaining = source.remaining(src)
  if remaining == infinity then
    ""
  else
    chooser(time.local(time() + remaining))
  end
end
