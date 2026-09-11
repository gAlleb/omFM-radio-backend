# Отложенные кандидаты: кто зазвучит следующим у каждого источника.
#
# Нужна тем станциям, которые объявляют следующий трек. Liquidsoap выбирает
# кандидата заранее, но держит его внутри плейлиста — вытащить можно только
# из check_next, поэтому источник кладёт принятого сюда, а расписание потом
# спрашивает по имени.

# Отложенные кандидаты — очередь на каждую категорию.
#
# Одной ячейки мало: когда до категории доходит очередь, она отдаёт в эфир
# припасённый трек и тут же выбирает следующий. В этот момент у неё в воздухе
# сразу два кандидата, и «последний принятый» — это уже трек через один.
# Поэтому держим очередь и снимаем с неё трек, когда он вышел в эфир: головой
# очереди тогда всегда оказывается настоящий следующий.
pending = ref([])

def queue_of(name) =
  list.assoc(default=[], name, pending())
end

def set_queue(name, q) =
  pending := list.add((name, q), list.assoc.remove(name, pending()))
end

def remember_next(name, m)
  set_queue(name, list.append(queue_of(name), [m]))
end

# Хвост очереди после трека, который только что отзвучал.
def rec after_aired(q, aired) =
  if q == [] then
    []
  else
    head = list.hd(default=[], q)
    rest = list.tl(q)
    name = head["filename"]
    if name == aired then rest else after_aired(rest, aired) end
  end
end

# Трек вышел в эфир — выбрасываем его и всё, что стояло перед ним.
def drop_aired(m) =
  name = m["playlist"]
  if name != "" then
    set_queue(name, after_aired(queue_of(name), m["filename"]))
  end
end

def reservation(name) =
  list.hd(default=[], queue_of(name))
end
