# Защита от повторов: журнал сыгранного и проверка кандидата на эфир.
# Логика не менялась при выносе в библиотеку, параметрами стали только
# окно неповтора и необязательный колбэк на принятый трек.

stopwords = [
  "a",
  "with",
  ",",
  "&",
  "the",
  "feat",
  "vs",
  "manose",
  "miten",
  "and"
]

def tokenize(a)
  b = string.case(a, lower=true)
  c = r/[^\w'-]+/.split(b)
  # TODO: normalize
  d = list.filter(fun(i) -> not list.mem(i, stopwords), c)
  list.sort.natural(d)
end

def my_hash(m)
  artist = metadata.artist(m)
  string.concat(tokenize(artist), separator=" ")
end

l = playlog(
  persistency="#{log_dir}/songs_check_#{station}.log",
  duration=7200.,
  hash=my_hash
)

# Отметка в журнале в момент выхода в эфир.
#
# Нужна станциям с расписанием. Категория, молчавшая с утра, успевает
# разрезолвить несколько треков про запас, и при записи на приёме все они
# получают утреннее время. К вечеру оно устаревает, и повтор проходит
# проверку, хотя в эфире между треками было два-три трека.
#
# only_playlist ограничивает отметку одним источником: у станции могут быть
# сутры, мантра и аудиокниги, которым в журнале артистов делать нечего.
def note_aired(~only_playlist="", m) =
  if only_playlist == "" or m["playlist"] == only_playlist then
    try
      l.add(m)
    catch err do
      log.severe("журнал повторов недоступен (#{err.message}), играю без правил")
    end
  end
end

# window     — сколько секунд артист не должен повторяться
# on_accept  — вызывается на принятом треке; станция может запомнить
#              его метаданные, чтобы отдать наружу как "следующий трек"
# defer_log  — не писать в журнал на приёме: станция отметит трек сама, когда
#              он выйдет в эфир (см. note_aired). Значение по умолчанию
#              сохраняет прежнее поведение для станций без расписания.
# reserved   — кандидат уже занят: пока трек ждёт эфира, журнал про него
#              молчит, и без этой проверки второй трек того же артиста мог бы
#              встать в очередь следом. Предикат задаёт станция, чтобы самой
#              решить, чьи очереди учитывать.
# give_up    — предохранитель: столько подряд отвергнутых кандидатов, после
#              которых очередной идёт в эфир. 0 отключает. Без него плейлист,
#              где правила не пропускают никого, перебирал бы файлы без конца.
def make_check(~on_accept=fun(_) -> (), ~defer_log=false,
               ~reserved=fun(_) -> false, ~give_up=0, window)
  rejected = ref(0)

  fun (r) ->
    if request.resolve(r) then
      m = request.metadata(r)
      fresh = l.last(m) >= window and not reserved(m)

      if not fresh and (give_up <= 0 or rejected() < give_up) then
        log(level=3, "Rejecting #{m['artist']} (played #{l.last(m)}s ago).")
        rejected := rejected() + 1
        false
      else
        if not fresh then
          log.important("правила никого не пропустили, ставлю #{m['artist']}")
        end
        if not defer_log then l.add(m) end
        on_accept(m)
        rejected := 0
        true
      end
    else
      false
    end
end
